import AVFoundation
import SwiftUI

/// 最初の設定。鍵が無いあいだは必ずここを通る。
/// 1 台目は鍵を作り、2 台目からは設定済みの端末の QR コードを読み取る。
struct SetupView: View {
    @Environment(AppModel.self) private var model
    @State private var scanning = false
    @State private var failed = false

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Image(systemName: "key.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(Theme.accent)
                    Text("端末をつなぐ準備")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                    Text("カメラにする端末と、映像を見る端末で、同じ鍵を持ちます。鍵が同じ端末どうしだけがつながり、通信は暗号化されます。")
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 12) {
                        Text("使い始めるまで")
                            .font(.headline)
                        GuideStep(number: 1, text: "1 台目の端末で「新しく始める」を押す")
                        GuideStep(number: 2, text: "1 台目に表示される QR コードを、2 台目の端末で読み取る")
                        GuideStep(number: 3, text: "片方をカメラにして置き、もう片方で映像を見る")
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.panel.opacity(0.6), in: RoundedRectangle(cornerRadius: 20))

                    Text("この端末は、どちらですか?")
                        .font(.headline)
                        .padding(.top, 4)

                    firstDeviceCard
                    otherDeviceCard

                    if failed {
                        Text("鍵を保存できませんでした。もう一度試してください。")
                            .font(.footnote)
                            .foregroundStyle(Theme.warning)
                    }
                }
                .frame(maxWidth: 440)
                .padding(24)
                .frame(maxWidth: .infinity)
            }
        }
        .sheet(isPresented: $scanning) {
            PairingScanView()
        }
    }

    private var otherDeviceCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("2 台目からの端末", systemImage: "qrcode.viewfinder")
                .font(.title3.bold())
            Text("すでに始めている端末で「端末を追加」を押し、表示された QR コードをこの端末で読み取ります。")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button {
                scanning = true
            } label: {
                Text("QR コードを読み取る")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            .foregroundStyle(.black)
        }
        .padding(20)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 20))
    }

    private var firstDeviceCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("1 台目の端末", systemImage: "sparkles")
                .font(.title3.bold())
            Text("この端末で新しい鍵を作ります。続けて、2 台目に読み取らせる QR コードを表示します。")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text("ほかの端末ですでに始めているときは、ここは押さずに「QR コードを読み取る」を使ってください。別の鍵になり、つながりません。")
                .font(.footnote)
                .foregroundStyle(Theme.warning)
            Button {
                failed = !model.createKey()
            } label: {
                Text("新しく始める")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            .foregroundStyle(.black)
        }
        .padding(20)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 20))
    }
}

/// 番号つきの手順 1 行。
struct GuideStep: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(.footnote.bold().monospacedDigit())
                .foregroundStyle(.black)
                .frame(width: 22, height: 22)
                .background(Theme.accent, in: Circle())
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

/// 端末を追加するための QR コードの表示。鍵そのものなので、開いているあいだだけ見せる。
struct PairingCodeView: View {
    /// 1 台目で鍵を作った直後に、続けて開いているか
    var isFirstDevice = false
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 16) {
                    Text(isFirstDevice ? "2 台目を追加" : "端末を追加")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                    if isFirstDevice {
                        Text("鍵を作りました。続けて、もう 1 台の端末をつなぎます。")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        GuideStep(number: 1, text: "追加する端末で、うちだけカメラを開く")
                        GuideStep(number: 2, text: "「QR コードを読み取る」を押す")
                        GuideStep(number: 3, text: "下の QR コードを写す")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Group {
                        if let image {
                            Image(uiImage: image)
                                .interpolation(.none)
                                .resizable()
                                .scaledToFit()
                                .accessibilityLabel("端末を追加するための QR コード")
                        } else {
                            ProgressView()
                        }
                    }
                    .frame(width: 260, height: 260)
                    .padding(16)
                    .background(.white, in: RoundedRectangle(cornerRadius: 16))

                    Label("この QR コードは家の鍵と同じです。写真に撮ったり、人に送ったりしないでください。写した人は映像を見られます。", systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(Theme.warning)

                    Button {
                        dismiss()
                    } label: {
                        Text(isFirstDevice ? "読み取りが済んだら、次へ" : "閉じる")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .foregroundStyle(.black)
                }
                .frame(maxWidth: 440)
                .padding(24)
                .frame(maxWidth: .infinity)
            }
        }
        .preferredColorScheme(.dark)
        .task {
            guard let key = model.key else { return }
            // 描画に少し時間がかかるので、メインスレッドの外で作る
            image = await Task.detached { PairingKey.qrImage(for: key) }.value
        }
    }
}

/// QR コードを読み取って、鍵を受け取る画面。
struct PairingScanView: View {
    private enum Access {
        case asking, allowed, denied, noCamera
    }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var access: Access = .asking
    @State private var message: String?

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: 16) {
                Text("QR コードを読み取る")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                Text("設定済みの端末で「端末を追加」を押し、表示された QR コードを枠に入れてください。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                ZStack {
                    RoundedRectangle(cornerRadius: 20).fill(.black)
                    switch access {
                    case .asking:
                        ProgressView()
                    case .allowed:
                        QRScannerView { code in
                            handle(code)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                    case .denied:
                        VStack(spacing: 12) {
                            Text("カメラを使う許可がありません。設定アプリで、うちだけカメラにカメラの使用を許可してください。")
                                .font(.footnote)
                                .multilineTextAlignment(.center)
                            Button("設定を開く") {
                                if let url = URL(string: UIApplication.openSettingsURLString) {
                                    openURL(url)
                                }
                            }
                            .tint(Theme.accent)
                        }
                        .padding()
                    case .noCamera:
                        Text("この端末ではカメラを使えません。")
                            .font(.footnote)
                            .padding()
                    }
                }
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: 360)

                if let message {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(Theme.warning)
                        .multilineTextAlignment(.center)
                }

                Button("やめる") { dismiss() }
                    .tint(.secondary)
            }
            .frame(maxWidth: 440)
            .padding(24)
        }
        .preferredColorScheme(.dark)
        .task {
            await requestAccess()
        }
    }

    private func requestAccess() async {
        guard AVCaptureDevice.default(for: .video) != nil else {
            access = .noCamera
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            access = .allowed
        case .notDetermined:
            access = await AVCaptureDevice.requestAccess(for: .video) ? .allowed : .denied
        default:
            access = .denied
        }
    }

    private func handle(_ code: String) {
        guard PairingKey.key(fromCode: code) != nil else {
            message = "うちだけカメラの QR コードではありません。"
            return
        }
        if model.adoptKey(fromCode: code) {
            // 鍵が入ると最初の画面に切り替わる。念のためこの画面も閉じる。
            dismiss()
        } else {
            message = "鍵を保存できませんでした。もう一度試してください。"
        }
    }
}

/// カメラで QR コードを探す。見つけるたびに、その中身を `onRead` に渡す（メインスレッド上）。
struct QRScannerView: UIViewRepresentable {
    let onRead: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onRead: onRead)
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.videoGravity = .resizeAspectFill
        context.coordinator.start(showingIn: view)
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {
        context.coordinator.onRead = onRead
    }

    static func dismantleUIView(_ view: PreviewView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

        override func layoutSubviews() {
            super.layoutSubviews()
            // 端末の向きに合わせて、映像が正しい向きで見えるようにする
            guard let connection = previewLayer.connection,
                  let orientation = window?.windowScene?.interfaceOrientation else { return }
            let angle: CGFloat
            switch orientation {
            case .landscapeRight: angle = 0
            case .landscapeLeft: angle = 180
            case .portraitUpsideDown: angle = 270
            default: angle = 90
            }
            if connection.isVideoRotationAngleSupported(angle) {
                connection.videoRotationAngle = angle
            }
        }
    }

    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        var onRead: (String) -> Void
        private let session = AVCaptureSession()
        private let queue = DispatchQueue(label: "uchidake.qrscan")
        /// 同じコードを続けて何度も渡さないための控え（メインスレッド上だけで触る）
        private var lastCode: String?

        init(onRead: @escaping (String) -> Void) {
            self.onRead = onRead
        }

        func start(showingIn view: PreviewView) {
            view.previewLayer.session = session
            queue.async { [session] in
                guard let device = AVCaptureDevice.default(for: .video),
                      let input = try? AVCaptureDeviceInput(device: device),
                      session.canAddInput(input) else { return }
                session.beginConfiguration()
                session.addInput(input)
                let output = AVCaptureMetadataOutput()
                if session.canAddOutput(output) {
                    session.addOutput(output)
                    output.setMetadataObjectsDelegate(self, queue: .main)
                    if output.availableMetadataObjectTypes.contains(.qr) {
                        output.metadataObjectTypes = [.qr]
                    }
                }
                session.commitConfiguration()
                session.startRunning()
                DispatchQueue.main.async {
                    view.setNeedsLayout()
                }
            }
        }

        func stop() {
            queue.async { [session] in
                session.stopRunning()
            }
        }

        func metadataOutput(
            _ output: AVCaptureMetadataOutput,
            didOutput metadataObjects: [AVMetadataObject],
            from connection: AVCaptureConnection
        ) {
            guard let code = metadataObjects
                .compactMap({ ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue })
                .first, code != lastCode else { return }
            lastCode = code
            onRead(code)
        }
    }
}
