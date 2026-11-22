import Foundation
import Observation
import StoreKit

/// 家族プランの購入と、この端末で有効かどうか。StoreKit 2 とやり取りする。
///
/// 判定はこの端末の Apple Account のものだけ。ほかの端末の家族プランは借りない。
@MainActor
@Observable
final class FamilyPlanStore {
    enum Catalog: Equatable {
        case loading, ready, unavailable
    }

    enum PurchaseOutcome {
        case purchased, cancelled, pending, failed
    }

    private static let recordKey = "familyPlanRecord"

    /// 最後にわかった権利。StoreKit から読めないときも、これで判断する。
    private(set) var record: PlanRecord?
    private(set) var catalog: Catalog = .loading
    /// 月額・年額・買い切りの順
    private(set) var products: [Product] = []
    /// 月額の「最初の 7 日間は無料」を使える人か
    private(set) var monthlyTrialAvailable = false
    /// 検証用（デバッグビルドの `-autoPlan`）: StoreKit を通さずに、家族プランの有無を決める
    var debugOverride: Bool?

    @ObservationIgnored private var updates: Task<Void, Never>?
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

    /// 権利を読み直し、以後の変化（購入・更新・返金・家族の購入）を追う。
    func start() {
        guard updates == nil else { return }
        updates = Task { [weak self] in
            await self?.refresh()
            for await update in Transaction.updates {
                if case .verified(let transaction) = update {
                    await transaction.finish()
                }
                await self?.refresh()
            }
        }
    }

    func refresh() async {
        var current: [PlanRecord] = []
        for await entitlement in Transaction.currentEntitlements {
            guard case .verified(let transaction) = entitlement, transaction.revocationDate == nil,
                  let product = PlanProduct(rawValue: transaction.productID) else { continue }
            current.append(PlanRecord(product: product, expires: transaction.expirationDate))
        }
        remember(PlanJudge.next(remembered: record, current: current, now: Date()))
    }

    func loadProducts() async {
        catalog = .loading
        let ids = PlanProduct.allCases.map(\.rawValue)
        guard let loaded = try? await Product.products(for: ids) else {
            catalog = .unavailable
            return
        }
        let ordered = ids.compactMap { id in loaded.first { $0.id == id } }
        guard ordered.count == ids.count else {
            catalog = .unavailable
            return
        }
        products = ordered
        monthlyTrialAvailable = await ordered[0].subscription?.isEligibleForIntroOffer ?? false
        catalog = .ready
    }

    func purchase(_ product: Product) async -> PurchaseOutcome {
        do {
            switch try await product.purchase() {
            case .success(.verified(let transaction)):
                await transaction.finish()
                await refresh()
                return .purchased
            case .success(.unverified):
                return .failed
            case .userCancelled:
                return .cancelled
            case .pending:
                return .pending
            @unknown default:
                return .failed
            }
        } catch {
            return .failed
        }
    }

    /// 「購入を復元」。有効になれば true。
    func restore() async -> Bool {
        try? await AppStore.sync()
        await refresh()
        return isActive
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
