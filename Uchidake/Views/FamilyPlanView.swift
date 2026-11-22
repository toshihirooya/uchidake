import SwiftUI

/// カメラを始められないときの画面。同じ組で、家族プランの無いカメラがすでに動いている。
struct CameraBlockedView: View {
    /// すでに動いているカメラの名前
    let otherName: String
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "video.slash.fill")
                .font(.system(size: 40))
                .foregroundStyle(Theme.warning)
            Text("この家では、すでに「\(otherName)」がカメラとして動いています。カメラを 2 台以上使うには、家族プランが必要です。")
                .font(.callout)
                .multilineTextAlignment(.center)
            Button("戻る") {
                model.backHome()
            }
            .buttonStyle(.bordered)
            .tint(.white)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: 440)
        .padding(24)
    }
}
