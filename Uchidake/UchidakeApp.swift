import Observation
import SwiftUI

@main
struct UchidakeApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .preferredColorScheme(.dark)
                .onAppear {
                    #if DEBUG
                    model.applyDebugLaunchOptions()
                    #endif
                    model.resumeLastRole()
                }
        }
    }
}

/// いまどの画面にいるか（最初の画面・カメラ・見る側）と、合言葉の鍵。
@MainActor
@Observable
final class AppModel {
    enum Mode {
        case home
        case camera(CameraStation)
        case viewer(CameraFinder)
    }

    private static let lastRoleKey = "lastRole"
    static let cameraNameKey = "cameraName"
    static let defaultCameraName = "カメラ"

    private(set) var mode: Mode = .home
    /// 合言葉から作った鍵。未設定なら nil。
    private(set) var key: Data? = PassphraseKey.load()
    /// 検証用: 見る側で、最初に見つかったカメラを自動で開く
    private(set) var opensFirstCamera = false

    @ObservationIgnored private var didResume = false

    var hasPassphrase: Bool { key != nil }

    /// 合言葉を設定（または変更）する。
    func setPassphrase(_ passphrase: String) async -> Bool {
        guard PassphraseKey.isValid(passphrase) else { return false }
        // 鍵の導出は重いのでメインスレッドの外で行う
        let derived = await Task.detached { PassphraseKey.derive(from: passphrase) }.value
        guard let derived else { return false }
        PassphraseKey.save(derived)
        key = derived
        return true
    }

    /// この端末をカメラにする。
    func startCamera(name: String) {
        guard let key else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let station = CameraStation(name: trimmed.isEmpty ? Self.defaultCameraName : String(trimmed.prefix(20)), key: key)
        mode = .camera(station)
        UserDefaults.standard.set("camera", forKey: Self.lastRoleKey)
        // カメラは開いたままで使うので、画面の自動ロックを止める
        UIApplication.shared.isIdleTimerDisabled = true
    }

    /// カメラの映像を見る側になる。
    func startViewer() {
        guard key != nil else { return }
        mode = .viewer(CameraFinder())
    }

    func backHome() {
        switch mode {
        case .camera(let station): station.stop()
        case .viewer(let finder): finder.stop()
        case .home: break
        }
        mode = .home
        UserDefaults.standard.removeObject(forKey: Self.lastRoleKey)
        UIApplication.shared.isIdleTimerDisabled = false
    }

    /// 前回カメラとして使っていた端末は、開いたらそのままカメラとして動かす。
    /// 再起動やアプリの終了のあと、開くだけで見守りに戻れるようにするため。
    func resumeLastRole() {
        guard !didResume else { return }
        didResume = true
        guard case .home = mode, hasPassphrase,
              UserDefaults.standard.string(forKey: Self.lastRoleKey) == "camera" else { return }
        startCamera(name: UserDefaults.standard.string(forKey: Self.cameraNameKey) ?? Self.defaultCameraName)
    }

    // MARK: - 検証用（docs/spec.md の9章）

    #if DEBUG
    func applyDebugLaunchOptions() {
        guard !didResume else { return }
        let defaults = UserDefaults.standard
        let passphrase = defaults.string(forKey: "autoPassphrase")
        let role = defaults.string(forKey: "autoRole")
        guard passphrase != nil || role != nil else { return }
        didResume = true
        Task {
            if let passphrase {
                _ = await setPassphrase(passphrase)
            }
            switch role {
            case "camera":
                startCamera(name: defaults.string(forKey: "autoName") ?? Self.defaultCameraName)
            case "viewer":
                opensFirstCamera = true
                startViewer()
            default:
                break
            }
        }
    }
    #endif
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if !model.hasPassphrase {
            PassphraseView(isChange: false)
        } else {
            switch model.mode {
            case .home:
                HomeView()
            case .camera(let station):
                CameraView(station: station)
            case .viewer(let finder):
                ViewerListView(finder: finder)
            }
        }
    }
}

/// 画面共通の見た目。暗い部屋で使うことが多いので、暗い配色にする。
enum Theme {
    static let background = Color(red: 0.07, green: 0.08, blue: 0.11)
    static let panel = Color(red: 0.13, green: 0.15, blue: 0.20)
    static let accent = Color(red: 0.42, green: 0.80, blue: 0.68)
    static let warning = Color(red: 1.0, green: 0.72, blue: 0.30)
    static let recording = Color(red: 0.95, green: 0.30, blue: 0.30)
}
