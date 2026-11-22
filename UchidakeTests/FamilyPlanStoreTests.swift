import StoreKit
import StoreKitTest
import XCTest
@testable import Uchidake

/// 商品定義（FamilyPlan.storekit）と、購入から「有効」になるまでの流れ。
@MainActor
final class FamilyPlanStoreTests: XCTestCase {
    private var session: SKTestSession!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        session = try SKTestSession(configurationFileNamed: "FamilyPlan")
        session.disableDialogs = true
        session.resetToDefaultState()
        session.clearTransactions()
        defaults = UserDefaults(suiteName: "FamilyPlanStoreTests-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        session.clearTransactions()
        session = nil
    }

    /// StoreKit への反映は少し遅れることがあるので、条件が成り立つまで読み直す
    private func refresh(_ store: FamilyPlanStore, until condition: (FamilyPlanStore) -> Bool) async {
        for _ in 0..<50 {
            await store.refresh()
            if condition(store) { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    func testCatalogHasThreeProductsAndOnlyMonthlyHasTheTrial() async {
        let store = FamilyPlanStore(defaults: defaults)
        await store.loadProducts()
        XCTAssertEqual(store.catalog, .ready)
        XCTAssertEqual(store.products.map(\.id), PlanProduct.allCases.map(\.rawValue))
        XCTAssertEqual(store.products.map(\.price), [300, 1500, 3000])
        XCTAssertTrue(store.products.allSatisfy(\.isFamilyShareable))
        let monthly = store.products[0].subscription
        XCTAssertEqual(monthly?.introductoryOffer?.paymentMode, .freeTrial)
        XCTAssertEqual(monthly?.introductoryOffer?.period.unit, .week)
        XCTAssertEqual(monthly?.introductoryOffer?.period.value, 1)
        XCTAssertNil(store.products[1].subscription?.introductoryOffer)
        XCTAssertTrue(store.monthlyTrialAvailable)
    }

    func testBuyingMonthlyActivatesAndIsRemembered() async throws {
        let store = FamilyPlanStore(defaults: defaults)
        await store.refresh()
        XCTAssertFalse(store.isActive)
        try await session.buyProduct(identifier: PlanProduct.monthly.rawValue)
        await refresh(store) { $0.isActive }
        XCTAssertTrue(store.isActive)
        XCTAssertEqual(store.record?.product, .monthly)
        XCTAssertNotNil(store.record?.expires)
        // 次に起動したときも、StoreKit に聞く前から有効
        XCTAssertTrue(FamilyPlanStore(defaults: defaults).isActive)
    }

    /// 買ったばかりの権利は、StoreKit への反映が遅れていても、その場で有効にする
    func testJustPurchasedCountsBeforeStoreKitCatchesUp() async {
        let store = FamilyPlanStore(defaults: defaults)
        let bought = PlanRecord(product: .monthly, expires: Date().addingTimeInterval(7 * 86_400))
        await store.refresh(justPurchased: bought)
        XCTAssertTrue(store.isActive)
        XCTAssertEqual(store.record, bought)
    }

    func testLifetimeWinsOverSubscription() async throws {
        let store = FamilyPlanStore(defaults: defaults)
        try await session.buyProduct(identifier: PlanProduct.yearly.rawValue)
        try await session.buyProduct(identifier: PlanProduct.lifetime.rawValue)
        await store.refresh()
        XCTAssertEqual(store.record, PlanRecord(product: .lifetime, expires: nil))
    }

    func testRefundTurnsItOff() async throws {
        let store = FamilyPlanStore(defaults: defaults)
        try await session.buyProduct(identifier: PlanProduct.lifetime.rawValue)
        await store.refresh()
        XCTAssertTrue(store.isActive)
        let transaction = try XCTUnwrap(session.allTransactions().first)
        try session.refundTransaction(identifier: transaction.identifier)
        await refresh(store) { !$0.isActive }
        XCTAssertFalse(store.isActive)
        XCTAssertNil(store.record)
    }
}
