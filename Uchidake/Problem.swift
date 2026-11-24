import Foundation

/// カメラや見る側が動けないときの理由。
///
/// 通信の層では「何が起きたか」だけを持ち、利用者に見せる文言は `message` で
/// 画面に出す直前に作る（端末の言語に合わせるため）。
enum Problem: Equatable {
    /// カメラの使用が許可されていない
    case cameraDenied
    /// 待ち受けが始まるのを待っている（ローカルネットワークの許可が無いときなど）
    case listenerWaiting(String)
    case listenerFailed(String)
    case listenerUnavailable(String)
    /// カメラ探しが始まるのを待っている（ローカルネットワークの許可が無いときなど）
    case browserWaiting(String)
    case browserFailed(String)

    var message: LocalizedStringResource {
        switch self {
        case .cameraDenied:
            "カメラの使用が許可されていません。設定アプリで「\(AppInfo.displayName)」のカメラを許可してください。"
        case .listenerWaiting(let detail):
            "待ち受けを待機中: \(detail)"
        case .listenerFailed(let detail):
            "待ち受けに失敗: \(detail)"
        case .listenerUnavailable(let detail):
            "待ち受けを開始できません: \(detail)"
        case .browserWaiting(let detail):
            "探索を待機中: \(detail)"
        case .browserFailed(let detail):
            "探索に失敗: \(detail)"
        }
    }
}

enum AppInfo {
    /// ホーム画面に出るアプリ名（端末の言語に合わせたもの）。
    /// 名前は InfoPlist.xcstrings の CFBundleDisplayName だけで決める。
    static var displayName: String {
        let key = "CFBundleDisplayName"
        return Bundle.main.localizedInfoDictionary?[key] as? String
            ?? Bundle.main.object(forInfoDictionaryKey: key) as? String
            ?? "Uchidake"
    }
}
