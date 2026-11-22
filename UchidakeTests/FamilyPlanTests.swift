import XCTest
@testable import Uchidake

final class FamilyPlanTests: XCTestCase {
    private let day: TimeInterval = 86_400
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let lifetime = PlanRecord(product: .lifetime, expires: nil)

    private func sub(_ product: PlanProduct = .monthly, expiresIn days: Double) -> PlanRecord {
        PlanRecord(product: product, expires: t0 + days * day)
    }

    func testNoRecordIsFree() {
        XCTAssertFalse(PlanJudge.isActive(nil, now: t0))
    }

    func testLifetimeIsAlwaysActive() {
        XCTAssertTrue(PlanJudge.isActive(lifetime, now: t0 + 9999 * day))
    }

    func testSubscriptionIsActiveUntilThirtyDaysAfterExpiry() {
        XCTAssertTrue(PlanJudge.isActive(sub(expiresIn: 1), now: t0))
        XCTAssertTrue(PlanJudge.isActive(sub(expiresIn: -29.9), now: t0))
        XCTAssertFalse(PlanJudge.isActive(sub(expiresIn: -30.1), now: t0))
    }

    /// 置きっぱなしの端末の時計が、ずっと前に戻っていても落ちない
    func testClockFarInThePastStillCountsAsActive() {
        XCTAssertTrue(PlanJudge.isActive(sub(expiresIn: 1), now: t0 - 4000 * day))
    }

    func testStoreKitResultWins() {
        XCTAssertEqual(
            PlanJudge.next(remembered: nil, current: [sub(expiresIn: 5), sub(.yearly, expiresIn: 300)], now: t0),
            sub(.yearly, expiresIn: 300))
        XCTAssertEqual(
            PlanJudge.next(remembered: sub(expiresIn: 5), current: [sub(expiresIn: 5), lifetime], now: t0),
            lifetime)
    }

    func testEmptyResultBeforeExpiryMeansRevoked() {
        XCTAssertNil(PlanJudge.next(remembered: sub(expiresIn: 5), current: [], now: t0))
        XCTAssertNil(PlanJudge.next(remembered: lifetime, current: [], now: t0))
    }

    func testEmptyResultAfterExpiryKeepsRecordDuringGrace() {
        XCTAssertEqual(PlanJudge.next(remembered: sub(expiresIn: -10), current: [], now: t0), sub(expiresIn: -10))
        XCTAssertNil(PlanJudge.next(remembered: sub(expiresIn: -31), current: [], now: t0))
    }

    /// 購入画面に並べる商品。買い切りの人には何も出さず、月額・年額の人には買い切りだけ出す
    func testOfferedProducts() {
        XCTAssertEqual(FamilyPlanView.offered(for: nil, isActive: false), [.monthly, .yearly, .lifetime])
        XCTAssertEqual(FamilyPlanView.offered(for: sub(expiresIn: -40), isActive: false), [.monthly, .yearly, .lifetime])
        XCTAssertEqual(FamilyPlanView.offered(for: sub(expiresIn: 5), isActive: true), [.lifetime])
        XCTAssertEqual(FamilyPlanView.offered(for: lifetime, isActive: true), [])
    }

    func testRecordSurvivesJSON() throws {
        for record in [lifetime, sub(.yearly, expiresIn: 12.5)] {
            let data = try JSONEncoder().encode(record)
            XCTAssertEqual(try JSONDecoder().decode(PlanRecord.self, from: data), record)
        }
    }
}
