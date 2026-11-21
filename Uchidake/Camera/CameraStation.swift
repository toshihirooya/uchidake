import AVFoundation
import Observation
import UIKit

/// カメラ役の端末の、画面から見た姿。`CameraEngine` を動かし、その状態を画面に伝える。
@MainActor
@Observable
final class CameraStation {
    let name: String
    private(set) var viewerCount = 0
    private(set) var usesFrontCamera = false
    /// カメラを使えない・待ち受けできないときの理由
    private(set) var problem: Problem?

    /// この端末で撮っている映像の表示先（置き場所を決めるための確認用）
    @ObservationIgnored let previewLayer = AVSampleBufferDisplayLayer()

    @ObservationIgnored private let key: Data
    @ObservationIgnored private var engine: CameraEngine?
    @ObservationIgnored private var batteryTask: Task<Void, Never>?

    init(name: String, key: Data) {
        self.name = name
        self.key = key
        previewLayer.videoGravity = .resizeAspect
    }

    func start() async {
        guard engine == nil else { return }
        guard await Self.requestAccess() else {
            problem = .cameraDenied
            return
        }
        guard engine == nil else { return }

        let engine = CameraEngine(name: name, key: key, previewLayer: previewLayer)
        engine.onChange = { [weak self] snapshot in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.engine === engine else { return }
                    #if DEBUG
                    if snapshot.viewerCount != self.viewerCount || snapshot.problem != self.problem {
                        NSLog("[Uchidake] camera viewers=%d problem=%@", snapshot.viewerCount, snapshot.problem.map { String(describing: $0) } ?? "-")
                    }
                    #endif
                    self.viewerCount = snapshot.viewerCount
                    self.usesFrontCamera = snapshot.usesFrontCamera
                    self.problem = snapshot.problem
                }
            }
        }
        self.engine = engine
        engine.start()

        // 電池の状態を、見る側に知らせるために渡し続ける
        UIDevice.current.isBatteryMonitoringEnabled = true
        batteryTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.reportBattery()
                try? await Task.sleep(for: .seconds(20))
            }
        }
    }

    func stop() {
        batteryTask?.cancel()
        batteryTask = nil
        engine?.stop()
        engine = nil
        viewerCount = 0
        previewLayer.sampleBufferRenderer.flush(removingDisplayedImage: true)
    }

    func switchCamera() {
        engine?.switchCamera()
    }

    private func reportBattery() {
        let device = UIDevice.current
        let level = device.batteryLevel >= 0 ? Int((device.batteryLevel * 100).rounded()) : nil
        let isCharging = device.batteryState == .charging || device.batteryState == .full
        engine?.setBattery(level: level, isCharging: isCharging)
    }

    /// カメラとマイクの許可を求める。カメラが許可されれば true（マイクは無くても映像は送れる）。
    private static func requestAccess() async -> Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        let video = await AVCaptureDevice.requestAccess(for: .video)
        _ = await AVAudioApplication.requestRecordPermission()
        return video
        #endif
    }
}
