import AVFoundation
import Foundation
import Network

/// カメラ側の本体。映像と音を撮り、つないできた見る側すべてに送る。
///
/// 待ち受けは UDP（DTLS）で、Bonjour にカメラの名前で広告する。
/// 見る側 1 台につき 1 本の接続を持ち、同じ映像・音声を全員に送る。
///
/// 通信まわりの状態は `queue` の上だけで触る。画面への通知は `onChange` で行う。
final class CameraEngine {
    struct Snapshot: Equatable {
        var viewerCount = 0
        var usesFrontCamera = false
        /// 待ち受けできないときの理由
        var problem: Problem?
    }

    static let maxViewers = 4
    /// これだけ何も届かない見る側は、いなくなったものとして切る
    private static let viewerTimeout: TimeInterval = 6

    /// 状態が変わるたびに呼ばれる（`queue` の上）
    var onChange: ((Snapshot) -> Void)?

    private final class Viewer {
        let connection: NWConnection
        var isReady = false
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
    private var nextFrameID: UInt32 = 0
    private var nextAudioSequence: UInt32 = 0
    private var battery: Int?
    private var isCharging = false
    private var isAudioRunning = false
    private var ticks = 0
    private var isStopped = false

    init(name: String, key: Data, previewLayer: AVSampleBufferDisplayLayer) {
        self.name = name
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
        guard viewers.count < Self.maxViewers else {
            connection.cancel()
            return
        }
        let viewer = Viewer(connection: connection)
        viewers.append(viewer)
        connection.stateUpdateHandler = { [weak self, weak viewer] newState in
            guard let self, let viewer else { return }
            switch newState {
            case .ready:
                // DTLS のハンドシェイクが通った。合言葉が同じ端末。
                viewer.isReady = true
                viewer.lastHeard = Date()
                self.receive(from: viewer)
                self.viewersChanged()
                // 途中から見始めた人がすぐ映像を出せるよう、キーフレームを送る
                self.encoder.requestKeyframe()
                self.sendStatus()
            case .failed, .cancelled:
                self.remove(viewer)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func remove(_ viewer: Viewer) {
        guard let index = viewers.firstIndex(where: { $0 === viewer }) else { return }
        viewers.remove(at: index)
        viewer.connection.stateUpdateHandler = nil
        viewer.connection.cancel()
        viewersChanged()
        sendStatus()
    }

    /// 見ている人の数が変わった。マイクは、誰かが見ているあいだだけ使う。
    private func viewersChanged() {
        let count = viewers.filter(\.isReady).count
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
        // 準備中のまま進まない接続（合言葉が違う相手など）も、ここで片付ける
        for viewer in viewers where now.timeIntervalSince(viewer.lastHeard) > Self.viewerTimeout {
            remove(viewer)
        }
        ticks += 1
        if ticks % 2 == 0 {
            sendStatus()
        }
    }

    // MARK: - 送信

    private func sendToAll(_ packet: Data) {
        for viewer in viewers where viewer.isReady {
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
            viewers: snapshot.viewerCount, usesFrontCamera: snapshot.usesFrontCamera)
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
        switch packet {
        case .keepAlive:
            break
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
        case .video, .status:
            break  // カメラが送る側のパケット
        }
    }
}
