import Foundation

/// 家族プランの買い方。中身は同じで、払い方だけが違う。
enum PlanProduct: String, Codable, CaseIterable {
    case monthly = "com.toshihirooya.uchidake.family.monthly"
    case yearly = "com.toshihirooya.uchidake.family.yearly"
    case lifetime = "com.toshihirooya.uchidake.family.lifetime"
}

/// この端末で最後にわかった、家族プランの権利。端末に覚えておく。
struct PlanRecord: Codable, Equatable {
    var product: PlanProduct
    /// 月額・年額の期限。買い切りは nil。
    var expires: Date?
}

/// 家族プランが有効かどうかの判断。StoreKit を知らない（単体テストで押さえるため）。
enum PlanJudge {
    /// 月額・年額の期限を過ぎてから、これだけは家族プランとして扱う。
    /// インターネットに出られない端末は更新を知れず、解約した人と見分けられないため。
    static let grace: TimeInterval = 30 * 24 * 60 * 60

    /// 記録が、その時刻に家族プランとして有効か。
    static func isActive(_ record: PlanRecord?, now: Date) -> Bool {
        guard let record else { return false }
        guard let expires = record.expires else { return true }
        return now < expires.addingTimeInterval(grace)
    }

    /// StoreKit がいま返した権利（`current`）と、覚えていた記録から、次に覚える記録を決める。
    /// - Parameter revoked: 覚えていた記録の購入が、返金などで取り消されたと StoreKit が言っている
    static func next(remembered: PlanRecord?, current: [PlanRecord], revoked: Bool, now: Date) -> PlanRecord? {
        if let lifetime = current.first(where: { $0.expires == nil }) {
            return lifetime
        }
        if let latest = current.max(by: { ($0.expires ?? .distantPast) < ($1.expires ?? .distantPast) }) {
            return latest
        }
        // StoreKit は何も返さなかった。取り消されたとはっきり分かるときだけ消す。
        // 読み出しが一時的に空になることがあり、それだけで払った人の記録を消してはいけない。
        guard let remembered, !revoked else { return nil }
        // 月額・年額は、期限を過ぎても更新を知れないだけかもしれないので、猶予のあいだは残す。
        return isActive(remembered, now: now) ? remembered : nil
    }
}
