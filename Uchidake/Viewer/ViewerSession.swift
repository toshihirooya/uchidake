import AVFoundation
import Network
import Observation
import UIKit

/// 近くにあるカメラを探す（Bonjour の `_uchidake._udp`）。
@MainActor
@Observable
final class CameraFinder {
    struct FoundCamera: Identifiable, Equatable {
        let name: String
        let endpoint: NWEndpoint
        var id: String { name }
    }

    private(set) var cameras: [FoundCamera] = []
    /// 探せないときの理由
    private(set) var problem: Problem?

    @ObservationIgnored private var browser: NWBrowser?

    func start() {
        guard browser == nil else { return }
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: MediaSecurity.serviceType, domain: nil), using: parameters)
        browser.stateUpdateHandler = { [weak self] newState in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch newState {
                case .ready:
                    self.problem = nil
                case .failed(let error):
                    self.problem = .browserFailed(error.localizedDescription)
                case .waiting(let error):
                    // ローカルネットワークの許可が無いときなどはここに来る
                    self.problem = .browserWaiting(error.localizedDescription)
                default:
                    break
                }
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            MainActor.assumeIsolated {
                self?.cameras = results.compactMap { result in
                    guard case .service(let name, let type, let domain, _) = result.endpoint else { return nil }
                    // 見つかったときの経路（インターフェース）には縛らず、名前だけで指す。
                    // 経路を固定すると、つなぐ時点でその経路が使えずに進まないことがある。
                    return FoundCamera(
                        name: name,
                        endpoint: .service(name: name, type: type, domain: domain, interface: nil))
                }
                .sorted { $0.name < $1.name }
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func stop() {
        browser?.cancel()
        browser = nil
        cameras = []
    }
}

/// カメラ 1 台を見ているあいだの、画面から見た姿。`ViewerEngine` を動かし、その状態を画面に伝える。
@MainActor
@Observable
final class ViewerSession: Identifiable {
    let cameraName: String
    private(set) var isLive = false
    /// つなごうとして時間切れになった回数。鍵が違うと増え続ける。
    private(set) var failedAttempts = 0
    private(set) var status: CameraStatus?
    private(set) var videoFrames = 0
    private(set) var audioPackets = 0
    private(set) var isTalking = false
    /// 話しかけようとしたが、マイクが許可されていなかった
    private(set) var microphoneDenied = false
    private(set) var isRecording = false
    private(set) var recordingStartedAt: Date?
    private(set) var canTakePhoto = false
    /// 写真を撮った瞬間に増える（画面を光らせるきっかけ）。
    private(set) var photoFlashes = 0
    var isSpeakerMuted = false {
        didSet { engine.setSpeakerMuted(isSpeakerMuted) }
    }

    /// 映像の表示先
    @ObservationIgnored let layer = AVSampleBufferDisplayLayer()
    @ObservationIgnored private let engine: ViewerEngine
    @ObservationIgnored private var isStarted = false
    @ObservationIgnored private var isClosed = false
    @ObservationIgnored private let saver: MediaSaver
    /// 録画を始める途中（許可を待っている）。2 度押しで 2 つ始めないための印
    @ObservationIgnored private var isStartingRecording = false

    init(camera: CameraFinder.FoundCamera, key: Data, saver: MediaSaver) {
        self.saver = saver
        cameraName = camera.name
        layer.videoGravity = .resizeAspect
        engine = ViewerEngine(endpoint: camera.endpoint, key: key, layer: layer)
        engine.onChange = { [weak self] snapshot in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    #if DEBUG
                    // 検証用: 画面を見なくても、つながったことと受信の進み具合が分かるようにする
                    let live = snapshot.phase == .live
                    if live != self.isLive || snapshot.videoFrames / 60 != self.videoFrames / 60 || snapshot.status != self.status {
                        NSLog("[Uchidake] viewer live=%d frames=%d audio=%d failed=%d viewers=%d front=%d",
                              live ? 1 : 0, snapshot.videoFrames, snapshot.audioPackets, snapshot.failedAttempts,
                              snapshot.status?.viewers ?? -1, snapshot.status?.usesFrontCamera == true ? 1 : 0)
                    }
                    #endif
                    self.isLive = snapshot.phase == .live
                    self.failedAttempts = snapshot.failedAttempts
                    self.status = snapshot.status
                    self.videoFrames = snapshot.videoFrames
                    self.audioPackets = snapshot.audioPackets
                    self.canTakePhoto = snapshot.canTakePhoto
                }
            }
        }
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        engine.start()
    }

    func stop() {
        stopRecording()
        isClosed = true
        engine.stop()
        layer.sampleBufferRenderer.flush(removingDisplayedImage: true)
    }

    /// 話しかけ始める。初回はマイクの許可を求める。
    func beginTalking() async {
        guard !isTalking else { return }
        #if !targetEnvironment(simulator)
        guard await AVAudioApplication.requestRecordPermission() else {
            microphoneDenied = true
            return
        }
        #endif
        isTalking = true
        engine.setTalking(true)
    }

    func endTalking() {
        guard isTalking else { return }
        isTalking = false
        engine.setTalking(false)
    }

    func switchCamera() {
        engine.switchCamera()
    }

    // MARK: - 写真と録画

    /// 今見えている 1 枚を「写真」に入れる。
    func takePhoto() async {
        guard isLive, canTakePhoto else { return }
        guard await saver.ensurePermission() else { return }
        let jpeg = await withCheckedContinuation { continuation in
            engine.capturePhoto { continuation.resume(returning: $0) }
        }
        guard let jpeg else {
            saver.report(.photoFailed)
            return
        }
        photoFlashes += 1
        await saver.savePhoto(jpeg)
    }

    /// 録画中なら止める。そうでなければ、許可と空き容量を確かめてから始める。
    func toggleRecording() async {
        if isRecording {
            stopRecording()
            return
        }
        guard isLive, !isStartingRecording else { return }
        isStartingRecording = true
        defer { isStartingRecording = false }
        // 録り終わってから断られて消える、を避けるため、許可が取れてから始める
        guard await saver.ensurePermission(), saver.ensureStorage() else { return }
        // 許可を待っているあいだに、画面が閉じられた・つながりが切れたことがある
        guard !isClosed, isLive else { return }

        let saver = saver
        engine.startRecording(directory: saver.directory, onFile: { url in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { Self.saveInBackground(url, saver: saver) }
            }
        }, onStop: { [weak self] lowStorage in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if lowStorage { saver.report(.lowStorage) }
                    self?.isRecording = false
                    self?.recordingStartedAt = nil
                }
            }
        })
        isRecording = true
        recordingStartedAt = Date()
    }

    /// 録画中なら止める。画面を閉じるとき、バックグラウンドに回るときに呼ぶ。
    func stopRecording() {
        guard isRecording else { return }
        engine.stopRecording()
    }

    /// 書き終えた動画を「写真」に入れる。`saver` を強く持つので、セッションが消えても続く。
    /// バックグラウンドに回っても終えられるよう、時間を確保する。
    private static func saveInBackground(_ url: URL, saver: MediaSaver) {
        let task = BackgroundTask()
        Task {
            await saver.saveVideo(at: url)
            task.end()
        }
    }

    /// 画面が見えていないあいだは、映像の表示を止める（音は聞き続ける）。
    func setVideoPaused(_ paused: Bool) {
        engine.setVideoPaused(paused)
    }
}

/// `UIApplication.beginBackgroundTask` で確保した時間。`end()` か時間切れで 1 回だけ返す。
@MainActor
private final class BackgroundTask {
    private var identifier = UIBackgroundTaskIdentifier.invalid

    init() {
        identifier = UIApplication.shared.beginBackgroundTask(withName: "SaveVideo") { [weak self] in
            MainActor.assumeIsolated { self?.end() }
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
