import SwiftUI

/// 最初の画面。この端末をカメラにするか、映像を見る側にするかを選ぶ。
struct HomeView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(AppModel.cameraNameKey) private var cameraName = AppModel.defaultCameraName
    @State private var changingPassphrase = false

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 20) {
                    VStack(spacing: 6) {
                        Image(systemName: "house.fill")
                            .font(.system(size: 40))
                            .foregroundStyle(Theme.accent)
                        Text("うちだけカメラ")
                            .font(.system(size: 32, weight: .bold, design: .rounded))
                        Text("映像は、家の中の端末どうしでだけやり取りします")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, 32)

                    viewerCard
                    cameraCard

                    Button("合言葉を変更") {
                        changingPassphrase = true
                    }
                    .font(.footnote)
                    .tint(.secondary)
                    .padding(.top, 4)
                }
                .frame(maxWidth: 440)
                .padding()
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .sheet(isPresented: $changingPassphrase) {
            PassphraseView(isChange: true)
        }
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

/// 合言葉の設定。初回は必ずここを通る。
struct PassphraseView: View {
    /// すでに設定済みで、変更のために開いているか
    let isChange: Bool
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var passphrase = ""
    @State private var isSaving = false
    @State private var failed = false

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Image(systemName: "key.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(Theme.accent)
                    Text(isChange ? "合言葉を変更" : "合言葉を決める")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                    Text("カメラにする端末と、映像を見る端末のすべてに、同じ合言葉を入れてください。合言葉が同じ端末どうしだけがつながり、通信は暗号化されます。")
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    TextField("合言葉（\(PassphraseKey.minimumLength)文字以上）", text: $passphrase)
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.title3.monospaced())

                    Button("自動で作る") {
                        passphrase = PassphraseKey.suggestion()
                    }
                    .font(.callout)
                    .tint(Theme.accent)

                    if isChange {
                        Text("変更すると、ほかの端末にも同じ合言葉を入れ直すまでつながらなくなります。")
                            .font(.footnote)
                            .foregroundStyle(Theme.warning)
                    }
                    if failed {
                        Text("合言葉を保存できませんでした。もう一度試してください。")
                            .font(.footnote)
                            .foregroundStyle(Theme.warning)
                    }

                    Button {
                        isSaving = true
                        failed = false
                        Task {
                            let saved = await model.setPassphrase(passphrase)
                            isSaving = false
                            if saved {
                                if isChange { dismiss() }
                            } else {
                                failed = true
                            }
                        }
                    } label: {
                        Group {
                            if isSaving {
                                ProgressView()
                            } else {
                                Text("この合言葉にする")
                                    .font(.headline)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .foregroundStyle(.black)
                    .disabled(!PassphraseKey.isValid(passphrase) || isSaving)

                    if isChange {
                        Button("やめる") { dismiss() }
                            .frame(maxWidth: .infinity)
                            .tint(.secondary)
                    }
                }
                .frame(maxWidth: 440)
                .padding(24)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .preferredColorScheme(.dark)
    }
}
