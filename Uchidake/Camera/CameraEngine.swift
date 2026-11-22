import AVFoundation
import Foundation
import Network

/// 見る側ごとの「録画中」を数える。`CameraEngine` の `queue` の上で使う。
struct RecorderTally {
    private var recording: Set<ObjectIdentifier> = []

    var count: Int { recording.count }

    /// 生存通知を受けたとき。数が変わったら true。
    mutating func update(viewer: ObjectIdentifier, isRecording: Bool) -> Bool {
        if isRecording {
            return recording.insert(viewer).inserted
        }
        return recording.remove(viewer) != nil
    }

    /// 見る側が切れたとき。数が変わったら true。
    mutating func remove(viewer: ObjectIdentifier) -> Bool {
        recording.remove(viewer) != nil
    }
}

/// カメラ側の本体。映像と音を撮り、つないできた見る側すべてに送る。
///
/// 待ち受けは UDP（DTLS）で、Bonjour にカメラの名前で広告する。
/// 見る側 1 台につき 1 本の接続を持ち、同じ映像・音声を全員に送る。
///
/// 通信まわりの状態は `queue` の上だけで触る。画面への通知は `onChange` で行う。
final class CameraEngine {
    struct Snapshot: Equatable {
        var viewerCount = 0
        /// 録画している見る側の数
        var recorderCount = 0
        var usesFrontCamera = false
        /// 待ち受けできないときの理由
        var problem: Problem?
    }

    /// 上限に達しているとき、つないできた相手の最初の生存通知をこれだけ待つ
    private static let admissionWait: TimeInterval = 2
    /// これだけ何も届かない見る側は、いなくなったものとして切る
    private static let viewerTimeout: TimeInterval = 6

    /// 状態が変わるたびに呼ばれる（`queue` の上）
    var onChange: ((Snapshot) -> Void)?

    private final class Viewer {
        let connection: NWConnection
        var isReady = false
        /// 見る側として受け入れたか。映像・音・状態を送るのは、受け入れた相手だけ。
        var isAdmitted = false
        /// 断ることにした（理由を送り終えたら切る）
        var isRefused = false
        /// 生存通知に付いてきた、見る側の端末の ID。古い版は付けない。
        var id: UInt64?
        var readySince = Date()
        var lastHeard = Date()
        /// 実行済みの操作の通し番号（同じ操作が複数回届くため）
        var handledCommands: Set<UInt32> = []

        init(connection: NWConnection) {
            self.connection = connection
        }
    }

    private let name: String
    private let key: Data
    private let previewLayer: AVSampleBufferDisplayLayer
    private let queue = DispatchQueue(label: "uchidake.camera")
    private let capture: CameraCapture
    private let encoder = H264Encoder()
    private let audio = AudioPipe()

    /// 見ている人がいるか。撮影用のキューから読むので鍵をかける。
    private let lock = NSLock()
    private var hasViewersFlag = false

    // 以下は queue の上だけで触る
    private var listener: NWListener?
    private var viewers: [Viewer] = []
    private var timer: DispatchSourceTimer?
    private var snapshot = Snapshot()
    private var recorders = RecorderTally()
    private var nextFrameID: UInt32 = 0
    private var nextAudioSequence: UInt32 = 0
    private var battery: Int?
    private var isCharging = false
    private var isAudioRunning = false
    private var ticks = 0
    private var isStopped = false
    private var hasFamilyPlan: Bool

    init(name: String, key: Data, previewLayer: AVSampleBufferDisplayLayer, hasFamilyPlan: Bool) {
        self.name = name
        self.hasFamilyPlan = hasFamilyPlan
        self.key = key
        self.previewLayer = previewLayer
        capture = CameraCapture(label: name)
    }

    // MARK: - 開始と終了

    func start() {
        encoder.onFrame = { [weak self] frame in
            self?.queue.async { self?.sendVideo(frame) }
        }
        audio.onPacket = { [weak self] pcm in
            self?.queue.async { self?.sendAudio(pcm) }
        }
        capture.onFrame = { [weak self] pixelBuffer, time in
            guard let self else { return }
            // 置き場所を決めやすいよう、この端末の画面にも出す
            if let preview = VideoFrames.rawSampleBuffer(from: pixelBuffer, at: time) {
                self.previewLayer.sampleBufferRenderer.enqueue(preview)
            }
            // 誰も見ていないあいだは圧縮しない
            if self.hasViewers {
                self.encoder.encode(pixelBuffer, at: time)
            }
        }
        capture.onCameraChanged = { [weak self] usesFrontCamera in
            self?.queue.async {
                guard let self else { return }
                self.snapshot.usesFrontCamera = usesFrontCamera
                self.encoder.requestKeyframe()
                self.publish()
                self.sendStatus()
            }
        }
        capture.start()
        queue.async {
            self.startListener()
            self.startTimer()
        }
    }

    func stop() {
        capture.onFrame = nil
        capture.onCameraChanged = nil
        let encoder = encoder
        // 圧縮器は撮影用のキューで使っているので、同じキューの上で片付ける
        capture.stop {
            encoder.onFrame = nil
            encoder.stop()
        }
        queue.async {
            self.isStopped = true
            self.timer?.cancel()
            self.timer = nil
            self.listener?.cancel()
            self.listener = nil
            self.viewers.forEach { $0.connection.cancel() }
            self.viewers.removeAll()
            self.setHasViewers(false)
            self.audio.onPacket = nil
            self.audio.stop()
            self.isAudioRunning = false
        }
    }

    func switchCamera() {
        capture.switchCamera()
    }

    /// この端末の家族プランが変わった。新しくつなぐ相手から、新しい上限を使う。
    /// いま見ている相手は切らない。
    func setFamilyPlan(_ active: Bool) {
        queue.async {
            self.hasFamilyPlan = active
        }
    }

    /// 電池の状態を伝える（見る側への状態の通知に載せる）。
    func setBattery(level: Int?, isCharging: Bool) {
        queue.async {
            self.battery = level
            self.isCharging = isCharging
        }
    }

    // MARK: - 待ち受け

    private func startListener() {
        guard !isStopped else { return }
        do {
            let listener = try NWListener(using: MediaSecurity.parameters(key: key))
            listener.service = NWListener.Service(name: name, type: MediaSecurity.serviceType)
            listener.stateUpdateHandler = { [weak self] newState in
                guard let self, !self.isStopped else { return }
                switch newState {
                case .ready:
                    self.snapshot.problem = nil
                case .waiting(let error):
                    // ローカルネットワークの許可が無いときなどはここに来る
                    self.snapshot.problem = .listenerWaiting(error.localizedDescription)
                case .failed(let error):
                    self.snapshot.problem = .listenerFailed(error.localizedDescription)
                    self.listener?.cancel()
                    self.listener = nil
                    // 少し待ってやり直す
                    self.queue.asyncAfter(deadline: .now() + 3) { [weak self] in
                        guard let self, self.listener == nil else { return }
                        self.startListener()
                    }
                default:
                    break
                }
                self.publish()
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self, !self.isStopped else {
                    connection.cancel()
                    return
                }
                self.accept(connection)
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            snapshot.problem = .listenerUnavailable(error.localizedDescription)
            publish()
        }
    }

    private func accept(_ connection: NWConnection) {
        // 保留中の相手も含めた、接続の数そのものの上限
        guard viewers.count < ViewerAdmission.limit(hasFamilyPlan: true) + 4 else {
            connection.cancel()
            return
        }
        let viewer = Viewer(connection: connection)
        viewers.append(viewer)
        connection.stateUpdateHandler = { [weak self, weak viewer] newState in
            guard let self, let viewer else { return }
            switch newState {
            case .ready:
                // DTLS のハンドシェイクが通った。鍵が同じ端末。
                viewer.isReady = true
                viewer.lastHeard = Date()
                viewer.readySince = Date()
                self.receive(from: viewer)
                // 空きがあればすぐ入れる。上限のときは、最初の生存通知（端末の ID）を待って決める。
                if self.admitted.count < ViewerAdmission.limit(hasFamilyPlan: self.hasFamilyPlan) {
                    self.admit(viewer)
                }
            case .failed, .cancelled:
                self.remove(viewer)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private var admitted: [Viewer] {
        viewers.filter(\.isAdmitted)
    }

    private func admit(_ viewer: Viewer) {
        viewer.isAdmitted = true
        viewersChanged()
        // 途中から見始めた人がすぐ映像を出せるよう、キーフレームを送る
        encoder.requestKeyframe()
        sendStatus()
    }

    /// 保留中の相手を、入れるか・入れ替えるか・断るか決める。
    private func settle(_ viewer: Viewer) {
        guard !viewer.isAdmitted, !viewer.isRefused else { return }
        let current = admitted
        switch ViewerAdmission.decide(newID: viewer.id, admitted: current.map(\.id), hasFamilyPlan: hasFamilyPlan) {
        case .admit:
            admit(viewer)
        case .replace(let index):
            remove(current[index])
            admit(viewer)
        case .refuse(let reason):
            viewer.isRefused = true
            let packet = MediaPacket.refusal(reason).encoded()
            // 届かないことがあるので 3 回送り、送り終えるのを少し待ってから切る
            for _ in 0..<3 {
                viewer.connection.send(content: packet, completion: .idempotent)
            }
            queue.asyncAfter(deadline: .now() + 0.5) { [weak self, weak viewer] in
                guard let self, let viewer else { return }
                self.remove(viewer)
            }
        }
    }

    private func remove(_ viewer: Viewer) {
        guard let index = viewers.firstIndex(where: { $0 === viewer }) else { return }
        viewers.remove(at: index)
        viewer.connection.stateUpdateHandler = nil
        viewer.connection.cancel()
        // 録画を止めずに消えた見る側は、ここで数から外す
        if recorders.remove(viewer: ObjectIdentifier(viewer)) {
            snapshot.recorderCount = recorders.count
        }
        viewersChanged()
        sendStatus()
    }

    /// 見ている人の数が変わった。マイクは、誰かが見ているあいだだけ使う。
    private func viewersChanged() {
        let count = admitted.count
        setHasViewers(count > 0)
        if count > 0, !isAudioRunning {
            audio.start(useMicrophone: true)
            isAudioRunning = true
        } else if count == 0, isAudioRunning {
            audio.stop()
            isAudioRunning = false
        }
        snapshot.viewerCount = count
        publish()
    }

    private func publish() {
        onChange?(snapshot)
    }

    private var hasViewers: Bool {
        lock.lock()
        defer { lock.unlock() }
        return hasViewersFlag
    }

    private func setHasViewers(_ value: Bool) {
        lock.lock()
        hasViewersFlag = value
        lock.unlock()
    }

    // MARK: - 定期処理

    private func startTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            self?.tick()
        }
        timer.resume()
        self.timer = timer
    }

    private func tick() {
        let now = Date()
        // 準備中のまま進まない接続（鍵が違う相手など）も、ここで片付ける
        for viewer in viewers where now.timeIntervalSince(viewer.lastHeard) > Self.viewerTimeout {
            remove(viewer)
        }
        // 生存通知を送ってこない保留中の相手（古い版など）も、待ちすぎずに決める
        for viewer in viewers where viewer.isReady && !viewer.isAdmitted
            && now.timeIntervalSince(viewer.readySince) > Self.admissionWait {
            settle(viewer)
        }
        ticks += 1
        if ticks % 2 == 0 {
            sendStatus()
        }
    }

    // MARK: - 送信

    private func sendToAll(_ packet: Data) {
        for viewer in viewers where viewer.isAdmitted {
            viewer.connection.send(content: packet, completion: .idempotent)
        }
    }

    private func sendVideo(_ frame: Data) {
        guard !isStopped, !viewers.isEmpty else { return }
        let packets = MediaPacket.videoPackets(frame: frame, frameID: nextFrameID)
        nextFrameID &+= 1
        packets.forEach(sendToAll)
    }

    private func sendAudio(_ pcm: Data) {
        guard !isStopped, !viewers.isEmpty else { return }
        sendToAll(MediaPacket.audio(sequence: nextAudioSequence, pcm: pcm).encoded())
        nextAudioSequence &+= 1
    }

    private func sendStatus() {
        let status = CameraStatus(
            name: name, battery: battery, isCharging: isCharging,
            viewers: snapshot.viewerCount, usesFrontCamera: snapshot.usesFrontCamera,
            recorders: snapshot.recorderCount)
        sendToAll(MediaPacket.status(status).encoded())
    }

    // MARK: - 受信

    private func receive(from viewer: Viewer) {
        viewer.connection.receiveMessage { [weak self, weak viewer] data, _, _, error in
            guard let self, let viewer, !self.isStopped else { return }
            if let data, let packet = MediaPacket(data) {
                viewer.lastHeard = Date()
                self.handle(packet, from: viewer)
            }
            if error == nil {
                self.receive(from: viewer)
            }
        }
    }

    private func handle(_ packet: MediaPacket, from viewer: Viewer) {
        if case .keepAlive(_, let id) = packet {
            if viewer.id == nil {
                viewer.id = id
            }
            if !viewer.isAdmitted {
                settle(viewer)
            } else if let id {
                // 空きがあってすぐ入れた相手が、つなぎ直した同じ端末だった。古いほうを片付ける。
                for old in admitted where old !== viewer && old.id == id {
                    remove(old)
                }
            }
        }
        // 受け入れていない相手の操作や声は通さない
        guard viewer.isAdmitted else { return }
        switch packet {
        case .keepAlive(let isRecording, _):
            if recorders.update(viewer: ObjectIdentifier(viewer), isRecording: isRecording) {
                snapshot.recorderCount = recorders.count
                publish()
                sendStatus()  // 2 秒待たせず知らせる
            }
        case .keyframeRequest:
            encoder.requestKeyframe()
        case .audio(_, let pcm):
            // 見る側が話しかけている。この端末のスピーカーから出す。
            audio.play(pcm)
        case .command(let command, let sequence):
            guard viewer.handledCommands.insert(sequence).inserted else { return }
            switch command {
            case .switchCamera:
                capture.switchCamera()
            }
        case .video, .status, .refusal:
            break  // カメラが送る側のパケット
        }
    }
}
