import AVFoundation
import Foundation
import Network

/// 見る側の本体。カメラ 1 台につないで、映像と音を受ける。話しかける声を送る。
///
/// 通信まわりの状態は `queue` の上だけで触る。画面への通知は `onChange` で行う。
final class ViewerEngine {
    enum Phase: Equatable {
        case connecting
        case live
    }

    struct Snapshot: Equatable {
        var phase: Phase = .connecting
        /// つなごうとして、時間切れになった回数。鍵が違うと増え続ける。
        var failedAttempts = 0
        var status: CameraStatus?
        var videoFrames = 0
        var audioPackets = 0
        var isRecording = false
        /// 写真にできるコマを覚えているか
        var canTakePhoto = false
        /// カメラに上限で断られているあいだの理由。映像や状態が届いたら nil に戻る。
        var refusal: RefusalReason?
    }

    /// この端末の ID。つなぎ直したとき、カメラが同じ端末だと分かるように生存通知に付ける。
    /// アプリを起動するたびに作り直す。
    static let viewerID = UInt64.random(in: 1...UInt64.max)

    /// これだけ待ってもつながらなければ、やり直す
    private static let connectTimeout: TimeInterval = 8
    /// つながったあと、これだけ何も届かなければ、つなぎ直す
    private static let silenceTimeout: TimeInterval = 5

    /// 状態が変わるたびに呼ばれる（`queue` の上）
    var onChange: ((Snapshot) -> Void)?

    private let endpoint: NWEndpoint
    private let key: Data
    private let layer: AVSampleBufferDisplayLayer
    private let queue = DispatchQueue(label: "uchidake.viewer")
    private let audio = AudioPipe()
    /// 写真の復元は時間がかかるので、`queue` を止めないよう別のキューで行う
    private let stillQueue = DispatchQueue(label: "uchidake.viewer.still")
    /// 空きを調べる（テストでは差し替える）
    private let freeBytes: (URL) -> Int64?

    // 以下は queue の上だけで触る
    private var connection: NWConnection?
    private var isConnectionReady = false
    private var attemptStarted = Date()
    private var lastHeard = Date()
    private var timer: DispatchSourceTimer?
    private var snapshot = Snapshot()
    private var assembler = VideoAssembler()
    private var format: CMFormatDescription?
    private var lastKeyframeRequest = Date.distantPast
    private var nextAudioSequence: UInt32 = 0
    private var nextCommandSequence = UInt32.random(in: 0...UInt32.max / 2)
    private var isTalking = false
    private var isVideoPaused = false
    private var isStopped = false
    /// 表示に回せた、最後のキーフレームからのコマ（写真用）
    private var gop = GopBuffer()
    /// 録画中の書き手と、その知らせ先。録画していなければ nil
    private var recording: Recording?

    private struct Recording {
        let recorder: StreamRecorder
        let directory: URL
        let onStop: (Bool) -> Void
    }

    #if DEBUG
    /// テスト用: 送ろうとしたパケットを覗く（つながっていなくても呼ばれる）
    var sentForTesting: ((Data) -> Void)?
    #endif

    init(endpoint: NWEndpoint, key: Data, layer: AVSampleBufferDisplayLayer,
         freeBytes: @escaping (URL) -> Int64? = MediaSaver.freeBytes(at:)) {
        self.endpoint = endpoint
        self.key = key
        self.layer = layer
        self.freeBytes = freeBytes
    }

    // MARK: - 開始と終了

    func start() {
        audio.onPacket = { [weak self] pcm in
            self?.queue.async { self?.sendTalk(pcm) }
        }
        queue.async { [weak self] in
            guard let self else { return }
            self.audio.start(useMicrophone: false)
            self.connect()
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + 1, repeating: 1)
            timer.setEventHandler { [weak self] in
                self?.tick()
            }
            timer.resume()
            self.timer = timer
        }
    }

    func stop() {
        queue.async {
            // 録画は先に止める。閉じ終えた知らせは、接続が無くても届く
            self.endRecording(lowStorage: false)
            self.isStopped = true
            self.timer?.cancel()
            self.timer = nil
            self.dropConnection()
            self.audio.onPacket = nil
            self.audio.stop()
        }
    }

    // MARK: - 利用者の操作

    func setSpeakerMuted(_ muted: Bool) {
        queue.async { self.audio.isSpeakerMuted = muted }
    }

    /// 話しかける・やめる。マイクは話しているあいだだけ使う。
    func setTalking(_ talking: Bool) {
        queue.async {
            guard !self.isStopped, self.isTalking != talking else { return }
            self.isTalking = talking
            self.audio.start(useMicrophone: talking)
        }
    }

    /// カメラの前面と背面を切り替えてもらう。
    func switchCamera() {
        queue.async { [weak self] in
            guard let self, !self.isStopped else { return }
            let packet = MediaPacket.command(.switchCamera, sequence: self.nextCommandSequence).encoded()
            self.nextCommandSequence &+= 1
            // 届かないことがあるので、同じ番号で 3 回送る。カメラは 1 回だけ実行する。
            for delay in [0.0, 0.1, 0.25] {
                self.queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.send(packet)
                }
            }
        }
    }

    /// 画面が見えていないあいだは、映像を表示に回さない。戻ったらキーフレームから再開する。
    func setVideoPaused(_ paused: Bool) {
        queue.async {
            guard self.isVideoPaused != paused else { return }
            self.isVideoPaused = paused
            if !paused {
                self.assembler = VideoAssembler()
                self.resetGop()
                self.layer.sampleBufferRenderer.flush()
                self.requestKeyframe(force: true)
            }
        }
    }

    // MARK: - 写真と録画

    /// 覚えているコマから 1 枚を JPEG にする。`queue` の外（復元用のキュー）で復元し、結果を `completion` に渡す。
    func capturePhoto(completion: @escaping (Data?) -> Void) {
        queue.async { [stillQueue] in
            let frames = self.gop.frames
            stillQueue.async {
                // 表示の層が映像を受けているとき、その処理で最初に作る復元器はキーフレームを
                // 「壊れている」（-8969）と返すことがある（シミュレータで確かめた）。すぐやり直せば通るので、1 回だけやり直す
                let image = StillDecoder.lastImage(from: frames) ?? StillDecoder.lastImage(from: frames)
                let jpeg = image.flatMap(StillDecoder.jpegData(from:))
                completion(jpeg)
            }
        }
    }

    /// 録画を始める。カメラにキーフレームを頼む。すでに録画中なら何もしない。
    /// `onFile` は書き終えたファイルごとに、`onStop` は録画が止まったときに 1 回（自分で止めた・失敗した・容量が減った、のどれでも）呼ばれる。
    func startRecording(directory: URL, onFile: @escaping (URL) -> Void, onStop: @escaping (_ lowStorage: Bool) -> Void) {
        queue.async { [weak self, queue] in
            guard let self, self.recording == nil else { return }
            guard !self.isStopped else {
                // もう閉じた。始めずに、止まったことだけ知らせる
                onStop(false)
                return
            }
            let recorder = StreamRecorder(directory: directory)
            // 書き手の知らせは書き手のキューから来るので、queue に戻してから扱う
            recorder.onFileFinished = { url in
                queue.async { onFile(url) }
            }
            recorder.onFailure = { [weak self, weak recorder] in
                queue.async {
                    // 最初の失敗で止める。2 回目以降や、前の録画の失敗は無視する
                    guard let self, let recorder, self.recording?.recorder === recorder else { return }
                    self.endRecording(lowStorage: false)
                }
            }
            self.recording = Recording(recorder: recorder, directory: directory, onStop: onStop)
            self.snapshot.isRecording = true
            self.publish()
            self.send(MediaPacket.keepAlive(isRecording: true, viewerID: Self.viewerID).encoded())
            self.requestKeyframe(force: true)
        }
    }

    /// 録画を止める。録画中でなければ何もしない。
    func stopRecording() {
        queue.async {
            self.endRecording(lowStorage: false)
        }
    }

    /// 録画を止めて、ファイルを閉じ始める。閉じ終えたら（`onFile` をすべて呼んだあと）`onStop` を呼ぶ。
    private func endRecording(lowStorage: Bool) {
        guard let recording else { return }
        self.recording = nil
        snapshot.isRecording = false
        publish()
        send(MediaPacket.keepAlive(isRecording: false, viewerID: Self.viewerID).encoded())
        let onStop = recording.onStop
        recording.recorder.finish { [queue] in
            queue.async { onStop(lowStorage) }
        }
    }

    private func resetGop() {
        gop.reset()
        if snapshot.canTakePhoto {
            snapshot.canTakePhoto = false
            publish()
        }
    }

    #if DEBUG
    /// テスト用: 受信したことにして `handle` に流す。
    func receiveForTesting(_ packet: MediaPacket) {
        queue.async { self.handle(packet) }
    }

    /// テスト用: 1 秒ごとの見回りを 1 回だけ行う。
    func tickForTesting() {
        queue.async { self.tick() }
    }
    #endif

    // MARK: - 接続

    private func connect() {
        guard !isStopped else { return }
        dropConnection()
        attemptStarted = Date()
        let connection = NWConnection(to: endpoint, using: MediaSecurity.parameters(key: key))
        self.connection = connection
        connection.stateUpdateHandler = { [weak self, weak connection] newState in
            guard let self, let connection, self.connection === connection else { return }
            switch newState {
            case .ready:
                // DTLS のハンドシェイクが通った。カメラに「見ている」と知らせて受信を始める。
                self.isConnectionReady = true
                self.lastHeard = Date()
                self.send(MediaPacket.keepAlive(isRecording: self.snapshot.isRecording, viewerID: Self.viewerID).encoded())
                self.receive(on: connection)
            case .failed:
                self.reconnectSoon()
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func dropConnection() {
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        isConnectionReady = false
        assembler = VideoAssembler()
        format = nil
        resetGop()
    }

    private func reconnectSoon(after delay: TimeInterval = 1) {
        dropConnection()
        if snapshot.phase != .connecting {
            snapshot.phase = .connecting
            publish()
        }
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.connection == nil else { return }
            self.connect()
        }
    }

    private func tick() {
        guard !isStopped else { return }
        let now = Date()
        // 空きが少なくなったら、書き込みに失敗する前に止める（失敗するとそこまでの録画が再生できない）
        if let recording, let free = freeBytes(recording.directory), free < MediaSaver.minimumFreeBytes {
            endRecording(lowStorage: true)
        }
        if isConnectionReady {
            send(MediaPacket.keepAlive(isRecording: snapshot.isRecording, viewerID: Self.viewerID).encoded())
            if now.timeIntervalSince(lastHeard) > Self.silenceTimeout {
                // カメラが止まった、または離れた
                reconnectSoon()
            }
        } else if connection != nil, now.timeIntervalSince(attemptStarted) > Self.connectTimeout {
            // 鍵が違うと、ハンドシェイクが失敗にならず待ち続ける。時間で見切ってやり直す。
            snapshot.failedAttempts += 1
            publish()
            connect()
        }
    }

    private func publish() {
        onChange?(snapshot)
    }

    // MARK: - 送信

    private func send(_ packet: Data) {
        #if DEBUG
        sentForTesting?(packet)
        #endif
        guard isConnectionReady else { return }
        connection?.send(content: packet, completion: .idempotent)
    }

    private func sendTalk(_ pcm: Data) {
        guard isTalking, !isStopped else { return }
        send(MediaPacket.audio(sequence: nextAudioSequence, pcm: pcm).encoded())
        nextAudioSequence &+= 1
    }

    /// カメラに「次はキーフレームを送って」と頼む。頼みすぎないよう間隔をあける。
    private func requestKeyframe(force: Bool = false) {
        guard force || Date().timeIntervalSince(lastKeyframeRequest) > 0.5 else { return }
        lastKeyframeRequest = Date()
        send(MediaPacket.keyframeRequest.encoded())
    }

    // MARK: - 受信

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self, weak connection] data, _, _, error in
            guard let self, let connection, self.connection === connection, !self.isStopped else { return }
            if let data, let packet = MediaPacket(data) {
                self.handle(packet)
            }
            if error == nil {
                self.receive(on: connection)
            }
        }
    }

    private func handle(_ packet: MediaPacket) {
        lastHeard = Date()
        if case .refusal(let reason) = packet {
            // 上限で断られた。理由を出して、枠が空くのを待ちながらつなぎ直す。
            guard snapshot.refusal != reason || snapshot.phase != .connecting else { return }
            snapshot.refusal = reason
            snapshot.phase = .connecting
            publish()
            reconnectSoon(after: 3)
            return
        }
        if snapshot.phase != .live || snapshot.refusal != nil {
            snapshot.phase = .live
            snapshot.failedAttempts = 0
            snapshot.refusal = nil
            publish()
        }
        switch packet {
        case .video(let frameID, let index, let count, let payload):
            guard !isVideoPaused else { return }
            switch assembler.receive(frameID: frameID, index: index, count: count, payload: payload) {
            case .incomplete:
                break
            case .waitForKeyframe:
                requestKeyframe()
            case .show(let frame):
                show(frame)
            }
        case .audio(_, let pcm):
            snapshot.audioPackets += 1
            // スピーカーを消していても、録画には入れる
            recording?.recorder.appendAudio(pcm, at: CMClockGetTime(CMClockGetHostTimeClock()))
            audio.play(pcm)
        case .status(let status):
            snapshot.status = status
            publish()
        case .keyframeRequest, .keepAlive, .command, .refusal:
            break  // 見る側が送るパケット（断りは上で受けた）
        }
    }

    private func show(_ frame: Data) {
        let renderer = layer.sampleBufferRenderer
        if renderer.status == .failed {
            renderer.flush()
            assembler.decodeFailed()
            requestKeyframe()
            return
        }
        guard let sampleBuffer = VideoFrames.compressedSampleBuffer(from: frame, format: &format) else {
            assembler.decodeFailed()
            requestKeyframe()
            return
        }
        renderer.enqueue(sampleBuffer)
        // 表示に回せたコマだけを、写真と録画に使う（見えているものと同じになる）
        gop.append(frame)
        recording?.recorder.appendVideo(frame, at: CMClockGetTime(CMClockGetHostTimeClock()))
        if snapshot.canTakePhoto == gop.isEmpty {
            snapshot.canTakePhoto = !gop.isEmpty
            publish()
        }
        snapshot.videoFrames += 1
        // コマ数は検証用の表示にしか使わないので、ときどきだけ知らせる
        if snapshot.videoFrames == 1 || snapshot.videoFrames % 15 == 0 {
            publish()
        }
    }
}
