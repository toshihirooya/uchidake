import AVFoundation
import CoreMedia
import UIKit

/// 送る映像の出どころ。実機ではカメラ、シミュレータ（カメラが無い）では動くテスト画像。
final class CameraCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    /// 1コマごとに呼ばれる（撮影用のキュー上）
    var onFrame: ((CVPixelBuffer, CMTime) -> Void)?
    /// 前後のカメラが切り替わったときに呼ばれる（撮影用のキュー上）
    var onCameraChanged: ((_ usesFrontCamera: Bool) -> Void)?

    private let queue = DispatchQueue(label: "uchidake.capture")
    private let label: String

    // 以下は queue の上だけで触る
    private var usesFrontCamera = false
    private var captureSession: AVCaptureSession?
    private let output = AVCaptureVideoDataOutput()
    private var rotation: AVCaptureDevice.RotationCoordinator?
    private var frameCount = 0
    private var timer: DispatchSourceTimer?

    /// - Parameter label: テスト画像に描く名前（どの端末の映像か見分けるため）
    init(label: String) {
        self.label = label
    }

    func start() {
        queue.async {
            #if targetEnvironment(simulator)
            self.startTestPattern()
            #else
            self.startCamera()
            #endif
        }
    }

    /// 止める。`completion` は、最後のコマの処理が終わったあとに撮影用のキュー上で呼ばれる。
    func stop(completion: (() -> Void)? = nil) {
        queue.async {
            self.captureSession?.stopRunning()
            self.captureSession = nil
            self.rotation = nil
            self.timer?.cancel()
            self.timer = nil
            completion?()
        }
    }

    /// 前面と背面を切り替える。
    func switchCamera() {
        queue.async {
            self.usesFrontCamera.toggle()
            #if !targetEnvironment(simulator)
            if let session = self.captureSession {
                self.selectCamera(in: session)
            }
            #endif
            self.onCameraChanged?(self.usesFrontCamera)
        }
    }

    // MARK: - カメラ

    private func startCamera() {
        guard captureSession == nil else { return }
        let session = AVCaptureSession()
        session.beginConfiguration()
        session.sessionPreset = .vga640x480
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]
        // 処理が追いつかないときは古いコマを捨てる（ためると遅延になる）
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(output) {
            session.addOutput(output)
        }
        session.commitConfiguration()

        selectCamera(in: session)
        session.startRunning()
        captureSession = session
    }

    /// `usesFrontCamera` に合うカメラを入力にする。
    private func selectCamera(in session: AVCaptureSession) {
        let position: AVCaptureDevice.Position = usesFrontCamera ? .front : .back
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
              let input = try? AVCaptureDeviceInput(device: camera) else { return }

        session.beginConfiguration()
        session.inputs.forEach { session.removeInput($0) }
        if session.canAddInput(input) {
            session.addInput(input)
        }
        session.commitConfiguration()

        // 暗い部屋でも少しでも映るよう、対応している端末では低照度の補正を使う
        if camera.isLowLightBoostSupported, (try? camera.lockForConfiguration()) != nil {
            camera.automaticallyEnablesLowLightBoostWhenAvailable = true
            camera.unlockForConfiguration()
        }

        rotation = AVCaptureDevice.RotationCoordinator(device: camera, previewLayer: nil)
        applyRotation()
    }

    /// 端末をどの向きに置いても、水平が合う向きの映像にする。
    private func applyRotation() {
        guard let rotation, let connection = output.connection(with: .video) else { return }
        let angle = rotation.videoRotationAngleForHorizonLevelCapture
        if connection.videoRotationAngle != angle, connection.isVideoRotationAngleSupported(angle) {
            connection.videoRotationAngle = angle
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        frameCount += 1
        // 置き直されたときのために、ときどき向きを確かめる
        if frameCount % 30 == 0 {
            applyRotation()
        }
        guard let pixelBuffer = sampleBuffer.imageBuffer else { return }
        onFrame?(pixelBuffer, sampleBuffer.presentationTimeStamp)
    }

    // MARK: - テスト画像

    private func startTestPattern() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(66))  // 約15コマ/秒
        timer.setEventHandler { [weak self] in
            guard let self, let pixelBuffer = self.makeTestFrame() else { return }
            self.onFrame?(pixelBuffer, CMClockGetTime(CMClockGetHostTimeClock()))
        }
        timer.resume()
        self.timer = timer
    }

    #if DEBUG
    private static let screenshotImage: UIImage? = UserDefaults.standard.string(forKey: "screenshotImage")
        .flatMap { UIImage(contentsOfFile: $0) }
        .flatMap { image in
            // 向きの情報を反映した画像にしてから描く
            UIGraphicsImageRenderer(size: image.size).image { _ in image.draw(at: .zero) }
        }
    #endif

    private func makeTestFrame() -> CVPixelBuffer? {
        let width = 480
        let height = 640
        var created: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &created)
        guard let pixelBuffer = created else { return nil }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(pixelBuffer), width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        frameCount += 1
        #if DEBUG
        // `-screenshotImage <パス>`: テスト画像の代わりに、その写真を送る（App Store 用のスクリーンショット）
        if let image = Self.screenshotImage {
            let scale = max(CGFloat(width) / image.size.width, CGFloat(height) / image.size.height)
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            let rect = CGRect(x: (CGFloat(width) - size.width) / 2, y: (CGFloat(height) - size.height) / 2,
                              width: size.width, height: size.height)
            context.interpolationQuality = .high
            context.draw(image.cgImage!, in: rect)
            return pixelBuffer
        }
        #endif
        // 背景の色がゆっくり変わり、白い帯が上下に動く。止まっていないことが一目で分かる。
        let hue = CGFloat(frameCount % 300) / 300
        context.setFillColor(UIColor(hue: hue, saturation: 0.6, brightness: 0.7, alpha: 1).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(UIColor.white.cgColor)
        context.fill(CGRect(x: 0, y: (frameCount * 6) % height, width: width, height: 24))

        // 文字は上下が逆にならないよう座標を反転してから描く
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        UIGraphicsPushContext(context)
        let text = "\(label)\n\(usesFrontCamera ? "前面" : "背面")\n\(frameCount)" as NSString
        text.draw(
            in: CGRect(x: 20, y: 220, width: width - 40, height: 260),
            withAttributes: [.font: UIFont.boldSystemFont(ofSize: 40), .foregroundColor: UIColor.white])
        UIGraphicsPopContext()
        return pixelBuffer
    }
}
