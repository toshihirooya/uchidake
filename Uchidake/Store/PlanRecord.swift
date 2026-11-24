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

    /// RevenueCat から読んだ、家族プランの権利のようす。
    struct Reading: Equatable {
        /// 権利が有効なら、そのもとになった商品の ID。有効でなければ nil。
        var productID: String?
        /// 月額・年額の期限。買い切りは nil。
        var expires: Date?
        /// この情報を RevenueCat のサーバーから受け取った時刻（端末の控えを読んだときは、控えた時刻）
        var fetchedAt: Date
    }

    /// 覚えていた記録と、いま読めた権利のようすから、次に覚える記録を決める。
    /// - Parameter reading: まだ 1 度も読めていなければ nil
    static func next(remembered: PlanRecord?, reading: Reading?, now: Date) -> PlanRecord? {
        if let reading, let productID = reading.productID {
            // 権利が有効。商品が家族プランの 3 つ以外でも（管理画面から付けた権利など）、有効として扱う。
            let product = PlanProduct(rawValue: productID) ?? (reading.expires == nil ? .lifetime : .monthly)
            return PlanRecord(product: product, expires: product == .lifetime ? nil : reading.expires)
        }
        guard let remembered else { return nil }
        if let reading {
            // 権利が無い、と読めた。買い切りなら返金。月額・年額は、期限のあとにサーバーへ聞いた結果なら
            // 解約や返金なので、ここで終わりにする。
            guard let expires = remembered.expires, reading.fetchedAt < expires else { return nil }
        }
        // 読めていないか、期限より前の古い控えしか無い（インターネットに出られない端末）。
        // 更新を知れないだけかもしれないので、猶予のあいだは残す。
        return isActive(remembered, now: now) ? remembered : nil
    }
}
