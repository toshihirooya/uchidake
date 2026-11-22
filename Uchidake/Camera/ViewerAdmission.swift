import Foundation

/// 見る側を断るときの理由（docs/spec.md の5章、種類 7）。
enum RefusalReason: UInt8 {
    /// 上限 1 台（このカメラの端末に家族プランが無い）
    case freeLimit = 1
    /// 上限 4 台（家族プランがあっても、これ以上は入れない）
    case familyLimit = 2
}

/// 新しくつないできた見る側を、入れるか・入れ替えるか・断るかの判断。
enum ViewerAdmission {
    enum Decision: Equatable {
        case admit
        /// 同じ端末がつなぎ直してきた。`admitted` のその位置の古い接続と入れ替える。
        case replace(index: Int)
        case refuse(RefusalReason)
    }

    /// 1 台のカメラを同時に見られる台数。
    static func limit(hasFamilyPlan: Bool) -> Int {
        hasFamilyPlan ? 4 : 1
    }

    /// - Parameter admitted: いま入っている見る側の ID（古い版で分からなければ nil）を、入った順に
    static func decide(newID: UInt64?, admitted: [UInt64?], hasFamilyPlan: Bool) -> Decision {
        // つなぎ直した同じ端末は、上限に関係なく自分の古い枠と入れ替える。
        // 見る側は 5 秒でつなぎ直すが、カメラが古い枠を空けるのは 6 秒後なので、
        // これが無いと上限 1 台のカメラでは自分自身に断られる。
        if let newID, let index = admitted.firstIndex(of: newID) {
            return .replace(index: index)
        }
        if admitted.count < limit(hasFamilyPlan: hasFamilyPlan) {
            return .admit
        }
        return .refuse(hasFamilyPlan ? .familyLimit : .freeLimit)
    }
}
