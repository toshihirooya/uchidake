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
        /// つなごうとして、時間切れになった回数。合言葉が違うと増え続ける。
        var failedAttempts = 0
        var status: CameraStatus?
        var videoFrames = 0
        var audioPackets = 0
    }

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

    init(endpoint: NWEndpoint, key: Data, layer: AVSampleBufferDisplayLayer) {
        self.endpoint = endpoint
        self.key = key
        self.layer = layer
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
                self.layer.sampleBufferRenderer.flush()
                self.requestKeyframe(force: true)
            }
        }
    }

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
                self.send(MediaPacket.keepAlive.encoded())
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
    }

    private func reconnectSoon() {
        dropConnection()
        if snapshot.phase != .connecting {
            snapshot.phase = .connecting
            publish()
        }
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.connection == nil else { return }
            self.connect()
        }
    }

    private func tick() {
        guard !isStopped else { return }
        let now = Date()
        if isConnectionReady {
            send(MediaPacket.keepAlive.encoded())
            if now.timeIntervalSince(lastHeard) > Self.silenceTimeout {
                // カメラが止まった、または離れた
                reconnectSoon()
            }
        } else if connection != nil, now.timeIntervalSince(attemptStarted) > Self.connectTimeout {
            // 合言葉（鍵）が違うと、ハンドシェイクが失敗にならず待ち続ける。時間で見切ってやり直す。
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
        if snapshot.phase != .live {
            snapshot.phase = .live
            snapshot.failedAttempts = 0
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
            audio.play(pcm)
        case .status(let status):
            snapshot.status = status
            publish()
        case .keyframeRequest, .keepAlive, .command:
            break  // 見る側が送るパケット
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
        snapshot.videoFrames += 1
        // コマ数は検証用の表示にしか使わないので、ときどきだけ知らせる
        if snapshot.videoFrames == 1 || snapshot.videoFrames % 15 == 0 {
            publish()
        }
    }
}
