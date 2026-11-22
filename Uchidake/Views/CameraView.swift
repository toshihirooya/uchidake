import SwiftUI

/// カメラ役の画面。撮っている映像と、カメラが動いていること・何台が見ているかを見せる。
///
/// しばらくさわらないと画面を暗くするが、「カメラ動作中」の表示は消さない。
/// この端末が撮影中であることを、その場にいる人がいつでも分かるようにするため。
struct CameraView: View {
    let station: CameraStation
    @Environment(AppModel.self) private var model
    @State private var isDimmed = false
    @State private var lastTouch = Date()
    @State private var savedBrightness: CGFloat?
    @State private var confirmStop = false
    @State private var showingPlan = false

    /// これだけさわらなければ、画面を暗くする
    private static let dimAfter: TimeInterval = 30

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch station.phase {
            case .checking:
                VStack(spacing: 14) {
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)
                    Text("ほかのカメラを確かめています…")
                        .font(.headline)
                        .foregroundStyle(.white)
                }
            case .blocked(let otherName):
                CameraBlockedView(otherName: otherName)
            case .unavailable:
                VStack(spacing: 16) {
                    if let problem = station.problem {
                        Text(problem.message)
                            .font(.callout)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(Theme.warning)
                    }
                    Button("戻る") {
                        model.backHome()
                    }
                    .buttonStyle(.bordered)
                    .tint(.white)
                }
                .frame(maxWidth: 440)
                .padding(24)
            case .running:
                VideoLayerView(layer: station.previewLayer)
                    .ignoresSafeArea()
                    .opacity(isDimmed ? 0 : 1)

                if isDimmed {
                    dimmedContent
                } else {
                    controls
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            wake()
        }
        .task {
            await station.start()
        }
        .task {
            // さわらない時間を見張って、画面を暗くする
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                if !isDimmed, station.phase == .running, station.problem == nil, Date().timeIntervalSince(lastTouch) > Self.dimAfter {
                    dim()
                }
            }
        }
        .onDisappear {
            restoreBrightness()
        }
        .confirmationDialog("カメラを止めますか？", isPresented: $confirmStop, titleVisibility: .visible) {
            Button("カメラを止める", role: .destructive) {
                restoreBrightness()
                model.backHome()
            }
        } message: {
            Text("見ている端末には映像が届かなくなります。")
        }
        .sheet(isPresented: $showingPlan) {
            FamilyPlanView()
        }
        .animation(.easeInOut(duration: 0.3), value: isDimmed)
    }

    /// 動作中であることの表示。暗くしたときも出し続ける。
    private var indicator: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Circle()
                    .fill(Theme.recording)
                    .frame(width: 12, height: 12)
                Text("カメラ動作中")
                    .font(.headline)
            }
            Group {
                if station.viewerCount > 0 {
                    Text("\(station.viewerCount)台が見ています（音も送っています）")
                } else {
                    Text("いまは誰も見ていません")
                }
            }
            .font(.subheadline)
            if station.recorderCount > 0 {
                Text("見ている端末が録画しています")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.recording)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var controls: some View {
        VStack {
            VStack(spacing: 6) {
                indicator
                Text(station.name)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 16))
            .padding(.top, 12)

            if let problem = station.problem {
                Text(problem.message)
                    .font(.callout)
                    .foregroundStyle(Theme.warning)
                    .multilineTextAlignment(.center)
                    .padding()
                    .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
                    .padding()
            }

            Spacer()

            Text("充電しながら、この画面を開いたままにしてください。\nしばらくすると画面が暗くなります。")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.8))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))

            HStack(spacing: 36) {
                Button {
                    lastTouch = Date()
                    station.switchCamera()
                } label: {
                    roundButton(systemImage: "arrow.triangle.2.circlepath.camera.fill", color: .white.opacity(0.25))
                }
                .accessibilityLabel(station.usesFrontCamera ? "背面カメラに切り替える" as LocalizedStringKey : "前面カメラに切り替える")

                Button {
                    lastTouch = Date()
                    confirmStop = true
                } label: {
                    roundButton(systemImage: "stop.fill", color: Theme.recording)
                }
                .accessibilityLabel("カメラを止める")

                if !model.plan.isActive {
                    Button {
                        lastTouch = Date()
                        showingPlan = true
                    } label: {
                        roundButton(systemImage: "person.3.fill", color: .white.opacity(0.25))
                    }
                    .accessibilityLabel("家族プランを見る")
                }
            }
            .padding(.vertical, 20)
        }
        .foregroundStyle(.white)
    }

    private var dimmedContent: some View {
        VStack(spacing: 14) {
            indicator
            Text("画面をタップすると戻ります")
                .font(.footnote)
        }
        .foregroundStyle(.white.opacity(0.55))
    }

    private func roundButton(systemImage: String, color: Color) -> some View {
        Image(systemName: systemImage)
            .font(.title2)
            .frame(width: 64, height: 64)
            .foregroundStyle(.white)
            .background(color, in: Circle())
    }

    // MARK: - 画面を暗くする

    private var screen: UIScreen? {
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen }.first
    }

    private func dim() {
        isDimmed = true
        if let screen {
            savedBrightness = screen.brightness
            screen.brightness = 0.05
        }
    }

    private func wake() {
        lastTouch = Date()
        guard isDimmed else { return }
        isDimmed = false
        restoreBrightness()
    }

    private func restoreBrightness() {
        if let savedBrightness, let screen {
            screen.brightness = savedBrightness
        }
        savedBrightness = nil
    }
}
