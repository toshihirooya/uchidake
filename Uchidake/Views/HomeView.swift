import SwiftUI

/// 最初の画面。この端末をカメラにするか、映像を見る側にするかを選ぶ。
struct HomeView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(AppModel.cameraNameKey) private var cameraName = AppModel.defaultCameraName
    @State private var showingCode = false
    @State private var showingPlan = false
    @State private var confirmingReset = false

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 20) {
                    VStack(spacing: 6) {
                        Image(systemName: "house.fill")
                            .font(.system(size: 40))
                            .foregroundStyle(Theme.accent)
                        Text(verbatim: AppInfo.displayName)
                            .font(.system(size: 32, weight: .bold, design: .rounded))
                        Text("映像は、家の中の端末どうしでだけやり取りします")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, 32)

                    if model.setupNotice != nil {
                        nextStepCard
                    }

                    viewerCard
                    cameraCard
                    addDeviceCard
                    familyPlanCard

                    Button("設定をやり直す") {
                        confirmingReset = true
                    }
                    .font(.footnote)
                    .tint(.secondary)
                }
                .frame(maxWidth: 440)
                .padding()
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .sheet(isPresented: $showingCode, onDismiss: {
            // 2 台目の追加の案内は 1 回だけ。閉じたあとは、次にすることの案内だけ残す
            if model.setupNotice == .created {
                model.setupNotice = .joined
            }
        }) {
            PairingCodeView(isFirstDevice: model.setupNotice == .created)
        }
        .sheet(isPresented: $showingPlan) {
            FamilyPlanView()
        }
        .onAppear {
            // 1 台目で鍵を作った直後は、続けて 2 台目を追加できるように QR コードを出す
            if model.setupNotice == .created {
                showingCode = true
            }
        }
        .confirmationDialog(
            "この端末の鍵を消して、最初の設定からやり直します。",
            isPresented: $confirmingReset, titleVisibility: .visible
        ) {
            Button("鍵を消してやり直す", role: .destructive) {
                model.resetKey()
            }
            Button("やめる", role: .cancel) {}
        } message: {
            Text("ほかの端末とは、同じ QR コードで設定し直すまでつながらなくなります。")
        }
    }

    /// 設定が済んだ直後にだけ出す、次にすることの案内。
    private var nextStepCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("準備ができました", systemImage: "checkmark.circle.fill")
                    .font(.headline)
                    .foregroundStyle(Theme.accent)
                Spacer()
                Button {
                    model.setupNotice = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.footnote.bold())
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)
                }
                .accessibilityLabel("案内を閉じる")
            }
            Text("見守りたい場所に置く端末で「カメラを始める」を、手元の端末で「カメラを探す」を押してください。")
                .font(.footnote)
            Text("ほかの端末をつなぐときは、下の「端末を追加」から QR コードを表示します。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(Theme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Theme.accent.opacity(0.5)))
    }

    private var familyPlanCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("家族プラン", systemImage: "person.3.fill")
                .font(.title3.bold())
            Text(model.plan.isActive
                 ? "家族プランが有効です" as LocalizedStringKey
                 : "1 台のカメラを同時に 4 台まで見られ、カメラを 2 台以上使えます。")
                .font(.footnote)
                .foregroundStyle(model.plan.isActive ? Theme.accent : .secondary)
            Button {
                showingPlan = true
            } label: {
                Text(model.plan.isActive ? "内容を見る" as LocalizedStringKey : "家族プランを見る")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.bordered)
            .tint(Theme.accent)
        }
        .padding(20)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 20))
    }

    private var addDeviceCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("端末を追加", systemImage: "qrcode")
                .font(.title3.bold())
            Text("もう 1 台の iPhone / iPad をつなぐときは、この端末に QR コードを表示して、追加する端末で読み取ります。")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button {
                showingCode = true
            } label: {
                Text("QR コードを表示")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.bordered)
            .tint(Theme.accent)
        }
        .padding(20)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 20))
    }

    private var viewerCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("映像を見る", systemImage: "eye.fill")
                .font(.title3.bold())
            Text("家の中で動いているカメラを探して、映像と音を確認します。")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button {
                model.startViewer()
            } label: {
                Text("カメラを探す")
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

    private var cameraCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("この iPhone をカメラにする", systemImage: "video.fill")
                .font(.title3.bold())
            Text("使っていない iPhone を、見守りたい場所に置きます。充電しながら、アプリを開いたままにしてください。")
                .font(.footnote)
                .foregroundStyle(.secondary)
            TextField("カメラの名前（例: リビング）", text: $cameraName)
                .textFieldStyle(.roundedBorder)
                .submitLabel(.done)
            Button {
                model.startCamera(name: cameraName)
            } label: {
                Text("カメラを始める")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.bordered)
            .tint(Theme.accent)
        }
        .padding(20)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 20))
    }
}
