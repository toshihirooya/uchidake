import SwiftUI

/// 見る側の最初の画面。近くにあるカメラの一覧。
struct ViewerListView: View {
    let finder: CameraFinder
    @Environment(AppModel.self) private var model
    @State private var session: ViewerSession?

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Button {
                        model.backHome()
                    } label: {
                        Label("戻る", systemImage: "chevron.left")
                    }
                    .tint(Theme.accent)
                    Spacer()
                }

                Text("カメラを選ぶ")
                    .font(.system(size: 28, weight: .bold, design: .rounded))

                if let problem = finder.problem {
                    Text(problem.message)
                        .font(.footnote)
                        .foregroundStyle(Theme.warning)
                }

                if finder.cameras.isEmpty {
                    VStack(spacing: 14) {
                        ProgressView()
                        Text("カメラを探しています…")
                            .font(.headline)
                        Text("カメラにする iPhone でアプリを開き、「カメラを始める」を押してください。同じ Wi-Fi にいるか、近くにあれば見つかります。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 48)
                } else {
                    ScrollView {
                        VStack(spacing: 10) {
                            ForEach(finder.cameras) { camera in
                                Button {
                                    open(camera)
                                } label: {
                                    HStack {
                                        Image(systemName: "video.fill")
                                            .foregroundStyle(Theme.accent)
                                        Text(camera.name)
                                            .font(.title3.bold())
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .foregroundStyle(.secondary)
                                    }
                                    .padding(18)
                                    .background(Theme.panel, in: RoundedRectangle(cornerRadius: 16))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: 520)
            .padding()
        }
        .onAppear {
            finder.start()
        }
        .onChange(of: finder.cameras) { _, cameras in
            // 検証用: 最初に見つかったカメラを自動で開く
            if model.opensFirstCamera, session == nil, let first = cameras.first {
                open(first)
            }
        }
        .fullScreenCover(item: $session) { session in
            LiveView(session: session) {
                session.stop()
                self.session = nil
            }
        }
    }

    private func open(_ camera: CameraFinder.FoundCamera) {
        guard let key = model.key else { return }
        session = ViewerSession(camera: camera, key: key)
    }
}

/// カメラ 1 台の映像を見る画面。
struct LiveView: View {
    let session: ViewerSession
    let onClose: () -> Void
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var session = session
        ZStack {
            Color.black.ignoresSafeArea()

            VideoLayerView(layer: session.layer)
                .ignoresSafeArea()
                .opacity(session.isLive ? 1 : 0.25)

            if !session.isLive {
                connecting
            }

            VStack {
                header
                Spacer()
                if session.microphoneDenied {
                    Text("マイクが許可されていないので、話しかけられません。設定アプリで許可してください。")
                        .font(.footnote)
                        .foregroundStyle(Theme.warning)
                        .multilineTextAlignment(.center)
                        .padding(10)
                        .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
                }
                controls
            }
            .padding()
        }
        .onAppear {
            session.start()
            // 見ているあいだは画面を消さない
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .onChange(of: scenePhase) { _, phase in
            // アプリを閉じているあいだは音だけ聞き、映像は戻ったときに再開する
            session.setVideoPaused(phase == .background)
            if phase != .active {
                session.endTalking()
            }
        }
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(session.cameraName)
                    .font(.headline)
                if session.isLive, let status = session.status {
                    HStack(spacing: 10) {
                        if let battery = status.battery {
                            Label {
                                Text(verbatim: "\(battery)%")
                            } icon: {
                                Image(systemName: status.isCharging ? "battery.100.bolt" : "battery.50")
                            }
                        }
                        Label("\(status.viewers)台が視聴中", systemImage: "eye")
                    }
                    .font(.caption)
                    if status.needsCharging {
                        Label("カメラの電池が少なくなっています", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption.bold())
                            .foregroundStyle(Theme.warning)
                    }
                }
                #if DEBUG
                Text(verbatim: "受信: 映像 \(session.videoFrames) コマ / 音声 \(session.audioPackets) パケット")
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.7))
                #endif
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 14))
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.headline)
                    .frame(width: 40, height: 40)
                    .background(.black.opacity(0.55), in: Circle())
            }
            .accessibilityLabel("閉じる")
        }
        .foregroundStyle(.white)
    }

    private var connecting: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
                .tint(.white)
            Text("カメラにつないでいます…")
                .font(.headline)
            if session.failedAttempts > 0 {
                Text("つながりません。この端末をカメラと同じ QR コードで設定したか、カメラの端末でアプリが開いているかを確かめてください。")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Theme.warning)
            }
        }
        .foregroundStyle(.white)
        .padding(32)
    }

    private var controls: some View {
        @Bindable var session = session
        return HStack(spacing: 28) {
            Button {
                session.isSpeakerMuted.toggle()
            } label: {
                roundIcon(
                    session.isSpeakerMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                    filled: session.isSpeakerMuted)
            }
            .accessibilityLabel(session.isSpeakerMuted ? "音を出す" as LocalizedStringKey : "音を消す")

            // 押しているあいだだけ話しかける
            VStack(spacing: 6) {
                Image(systemName: "mic.fill")
                    .font(.title)
                    .frame(width: 84, height: 84)
                    .foregroundStyle(session.isTalking ? .black : .white)
                    .background(session.isTalking ? Theme.accent : Color.white.opacity(0.25), in: Circle())
                    .scaleEffect(session.isTalking ? 1.1 : 1)
                    .animation(.easeOut(duration: 0.15), value: session.isTalking)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { _ in
                                guard !session.isTalking else { return }
                                Task { await session.beginTalking() }
                            }
                            .onEnded { _ in
                                session.endTalking()
                            }
                    )
                    .accessibilityLabel("押しているあいだ話しかける")
                    .accessibilityAddTraits(.isButton)
                Text(session.isTalking ? "話しています" as LocalizedStringKey : "押して話す")
                    .font(.caption)
            }

            Button {
                session.switchCamera()
            } label: {
                roundIcon("arrow.triangle.2.circlepath.camera.fill", filled: false)
            }
            .accessibilityLabel(session.status?.usesFrontCamera == true ? "背面カメラに切り替える" as LocalizedStringKey : "前面カメラに切り替える")
        }
        .foregroundStyle(.white)
        .padding(.bottom, 12)
        .disabled(!session.isLive)
        .opacity(session.isLive ? 1 : 0.4)
    }

    private func roundIcon(_ systemImage: String, filled: Bool) -> some View {
        Image(systemName: systemImage)
            .font(.title2)
            .frame(width: 60, height: 60)
            .foregroundStyle(filled ? .black : .white)
            .background(filled ? Color.white : Color.white.opacity(0.25), in: Circle())
    }
}
