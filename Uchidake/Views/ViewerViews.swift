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
                // 画面を閉じたあとに終わった保存の結果も、ここで見えるようにする
                SaveNoticeView(saver: model.saver)
                    .frame(maxWidth: .infinity)
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
            .environment(model)
        }
    }

    private func open(_ camera: CameraFinder.FoundCamera) {
        guard let key = model.key else { return }
        session = ViewerSession(camera: camera, key: key, saver: model.saver)
    }
}

/// カメラ 1 台の映像を見る画面。
struct LiveView: View {
    let session: ViewerSession
    let onClose: () -> Void
    @Environment(\.scenePhase) private var scenePhase
    @Environment(AppModel.self) private var model

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
                SaveNoticeView(saver: model.saver)
                captureControls
                controls
            }
            .padding()

            // 写真を撮ったら、画面を白くしてから 0.15 秒で消す。
            // 同じ更新の中で 1 にして 0 に戻すと変化が無かったことになるので、キーフレームで動かす
            Color.white
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .keyframeAnimator(initialValue: 0.0, trigger: session.photoFlashes) { view, opacity in
                    view.opacity(opacity)
                } keyframes: { _ in
                    MoveKeyframe(1.0)
                    LinearKeyframe(0.0, duration: 0.15, timingCurve: .easeOut)
                }
        }
        .task {
            #if DEBUG
            await runDebugCaptureOptions()
            #endif
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
            // バックグラウンドでは録画を続けない。そこまでを保存する
            if phase == .background {
                session.stopRecording()
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
                        // 自分の録画は除いて数える
                        if status.recorders - (session.isRecording ? 1 : 0) > 0 {
                            Label("ほかの端末が録画中", systemImage: "record.circle")
                                .foregroundStyle(Theme.recording)
                        }
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
            if session.isRecording, let startedAt = session.recordingStartedAt {
                recordingBadge(since: startedAt)
            }
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

    /// 録画中の赤い丸と経過時間
    private func recordingBadge(since startedAt: Date) -> some View {
        TimelineView(.periodic(from: startedAt, by: 1)) { context in
            let seconds = max(0, Int(context.date.timeIntervalSince(startedAt)))
            HStack(spacing: 6) {
                Circle()
                    .fill(Theme.recording)
                    .frame(width: 10, height: 10)
                Text(verbatim: String(format: "%d:%02d", seconds / 60, seconds % 60))
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.black.opacity(0.55), in: Capsule())
        }
        .padding(.leading, 8)
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

    /// 写真と録画のボタン。録画を止めるボタンは、つなぎ直し中でも押せる（`controls` の `.disabled` の外に置く）。
    private var captureControls: some View {
        let canPhoto = session.isLive && session.canTakePhoto
        let canRecord = session.isRecording || session.isLive
        return HStack(spacing: 56) {
            Button {
                Task { await session.takePhoto() }
            } label: {
                roundIcon("camera.fill", filled: false)
            }
            .accessibilityLabel("写真を撮る")
            .disabled(!canPhoto)
            .opacity(canPhoto ? 1 : 0.4)

            Button {
                Task { await session.toggleRecording() }
            } label: {
                roundIcon(session.isRecording ? "stop.fill" : "record.circle",
                          filled: false, background: session.isRecording ? Theme.recording : nil)
            }
            .accessibilityLabel(session.isRecording ? "録画を止める" as LocalizedStringKey : "録画を始める")
            .disabled(!canRecord)
            .opacity(canRecord ? 1 : 0.4)
        }
        .foregroundStyle(.white)
        .padding(.bottom, 4)
    }

    private func roundIcon(_ systemImage: String, filled: Bool, background: Color? = nil) -> some View {
        Image(systemName: systemImage)
            .font(.title2)
            .frame(width: 60, height: 60)
            .foregroundStyle(filled ? .black : .white)
            .background(background ?? (filled ? Color.white : Color.white.opacity(0.25)), in: Circle())
    }

    #if DEBUG
    /// 検証用（docs/spec.md の9章）: `-autoPhoto` と `-autoRecord` を、最初に開いたカメラで 1 回だけ実行する。
    private func runDebugCaptureOptions() async {
        let options = model.takeDebugCaptureOptions()
        if options.photo {
            guard await waitUntil({ session.isLive && session.canTakePhoto }) else { return }
            await session.takePhoto()
        }
        if let seconds = options.recordSeconds {
            guard await waitUntil({ session.isLive }) else { return }
            await session.toggleRecording()
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            // 画面が閉じられたときは session.stop() が止めている
            guard !Task.isCancelled else { return }
            session.stopRecording()
        }
    }

    /// 条件が満たされるまで待つ。画面が閉じられたら false。
    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        while !condition() {
            try? await Task.sleep(nanoseconds: 200_000_000)
            if Task.isCancelled { return false }
        }
        return true
    }
    #endif
}

/// 保存の結果と、動画の保存中であることを短く出す。
struct SaveNoticeView: View {
    let saver: MediaSaver

    var body: some View {
        if let text {
            Text(text)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(saver.notice.map(Self.isProblem) == true ? Theme.warning : .white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.black.opacity(0.7), in: Capsule())
                .transition(.opacity)
        }
    }

    private var text: LocalizedStringKey? {
        if let notice = saver.notice {
            return Self.message(for: notice)
        }
        return saver.pendingVideos > 0 ? "動画を保存しています…" : nil
    }

    private static func message(for notice: MediaSaver.Notice) -> LocalizedStringKey {
        switch notice {
        case .photoSaved: "写真を保存しました"
        case .videoSaved: "動画を保存しました"
        case .photoFailed: "写真を保存できませんでした。"
        case .videoFailed: "保存できませんでした。次にアプリを開いたとき、もう一度試します。"
        case .permissionDenied: "「写真」への追加が許可されていません。設定アプリで許可してください。"
        case .lowStorage: "空き容量が少ないので、録画できません。"
        }
    }

    private static func isProblem(_ notice: MediaSaver.Notice) -> Bool {
        switch notice {
        case .photoSaved, .videoSaved: false
        case .photoFailed, .videoFailed, .permissionDenied, .lowStorage: true
        }
    }
}
