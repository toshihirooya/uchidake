import Foundation
import Observation
import RevenueCat

/// RevenueCat の設定。値の実体は RevenueCat の管理画面にある。
enum RevenueCatConfig {
    /// iOS の Public SDK キー（`appl_` で始まる。アプリに入れてよい公開用のキー）。
    /// 空のあいだは RevenueCat を使わず、購入画面は「商品を読み込めませんでした」になる。
    static let publicSDKKey = ""
    /// 家族プランの権利（Entitlement）の ID。月額・年額・買い切りの 3 商品をこれに結び付ける。
    static let entitlementID = "family"
    /// 購入画面に並べる商品の組（Offering）の ID。月額・年額・買い切りのパッケージを入れる。
    static let offeringID = "default"
}

/// 家族プランの購入と、この端末で有効かどうか。RevenueCat の SDK とやり取りする。
///
/// 利用者の ID は RevenueCat の匿名 ID（このアプリにログインは無い）。
/// 判定はこの端末のものだけ。ほかの端末の家族プランは借りない。
@MainActor
@Observable
final class FamilyPlanStore {
    enum Catalog: Equatable {
        case loading, ready, unavailable
    }

    enum PurchaseOutcome {
        case purchased, cancelled, pending, failed
    }

    /// 購入画面に並べる 1 商品。金額は App Store の表示そのまま。
    struct Offer: Equatable {
        let kind: PlanProduct
        let price: String
    }

    private static let recordKey = "familyPlanRecord"

    /// 最後にわかった権利。RevenueCat から読めないときも、これで判断する。
    private(set) var record: PlanRecord?
    private(set) var catalog: Catalog = .loading
    /// 月額・年額・買い切りの順
    private(set) var offers: [Offer] = []
    /// 月額の「最初の 7 日間は無料」を使える人か
    private(set) var monthlyTrialAvailable = false
    /// 検証用（デバッグビルドの `-autoPlan`）: 購入を通さずに、家族プランの有無を決める
    var debugOverride: Bool?

    @ObservationIgnored private var updates: Task<Void, Never>?
    @ObservationIgnored private var packages: [PlanProduct: Package] = [:]
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.recordKey) {
            record = try? JSONDecoder().decode(PlanRecord.self, from: data)
        }
    }

    var isActive: Bool {
        debugOverride ?? PlanJudge.isActive(record, now: Date())
    }

    /// RevenueCat を始め、以後の購入情報の変化（購入・更新・返金・家族の購入）を追う。
    func start() {
        guard updates == nil, !RevenueCatConfig.publicSDKKey.isEmpty else { return }
        if !Purchases.isConfigured {
            Purchases.configure(withAPIKey: RevenueCatConfig.publicSDKKey)
        }
        updates = Task { [weak self] in
            for await info in Purchases.shared.customerInfoStream {
                self?.apply(info)
            }
        }
    }

    func loadProducts() async {
        catalog = .loading
        guard Purchases.isConfigured,
              let offering = try? await Purchases.shared.offerings().offering(identifier: RevenueCatConfig.offeringID)
        else {
            catalog = .unavailable
            return
        }
        var found: [PlanProduct: Package] = [:]
        for package in offering.availablePackages {
            if let kind = Self.kind(of: package) {
                found[kind] = package
            }
        }
        guard found.count == PlanProduct.allCases.count else {
            catalog = .unavailable
            return
        }
        packages = found
        offers = PlanProduct.allCases.compactMap { kind in
            found[kind].map { Offer(kind: kind, price: $0.storeProduct.localizedPriceString) }
        }
        if let monthly = found[.monthly]?.storeProduct {
            monthlyTrialAvailable =
                await Purchases.shared.checkTrialOrIntroDiscountEligibility(product: monthly) == .eligible
        }
        catalog = .ready
    }

    func purchase(_ kind: PlanProduct) async -> PurchaseOutcome {
        guard Purchases.isConfigured, let package = packages[kind] else { return .failed }
        do {
            let result = try await Purchases.shared.purchase(package: package)
            if result.userCancelled {
                return .cancelled
            }
            apply(result.customerInfo)
            return .purchased
        } catch let error as ErrorCode where error == .purchaseCancelledError {
            return .cancelled
        } catch let error as ErrorCode where error == .paymentPendingError {
            return .pending
        } catch {
            return .failed
        }
    }

    /// 「購入を復元」。有効になれば true。
    func restore() async -> Bool {
        guard Purchases.isConfigured, let info = try? await Purchases.shared.restorePurchases() else { return isActive }
        apply(info)
        return isActive
    }

    /// パッケージが、家族プランのどの買い方か。種類で見分け、だめなら商品 ID で見分ける。
    private static func kind(of package: Package) -> PlanProduct? {
        switch package.packageType {
        case .monthly: .monthly
        case .annual: .yearly
        case .lifetime: .lifetime
        default: PlanProduct(rawValue: package.storeProduct.productIdentifier)
        }
    }

    private func apply(_ info: CustomerInfo) {
        let entitlement = info.entitlements[RevenueCatConfig.entitlementID]
        let active = entitlement?.isActive == true ? entitlement : nil
        let reading = PlanJudge.Reading(
            productID: active?.productIdentifier, expires: active?.expirationDate, fetchedAt: info.requestDate)
        remember(PlanJudge.next(remembered: record, reading: reading, now: Date()))
    }

    private func remember(_ next: PlanRecord?) {
        guard next != record else { return }
        record = next
        if let next, let data = try? JSONEncoder().encode(next) {
            defaults.set(data, forKey: Self.recordKey)
        } else {
            defaults.removeObject(forKey: Self.recordKey)
        }
    }
}
