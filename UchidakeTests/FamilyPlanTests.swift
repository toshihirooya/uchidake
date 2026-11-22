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

    /// 購入画面に並べる商品。買い切りの人には何も出さず、月額・年額の人には買い切りだけ出す
    func testOfferedProducts() {
        XCTAssertEqual(FamilyPlanView.offered(for: nil, isActive: false), [.monthly, .yearly, .lifetime])
        XCTAssertEqual(FamilyPlanView.offered(for: sub(expiresIn: -40), isActive: false), [.monthly, .yearly, .lifetime])
        XCTAssertEqual(FamilyPlanView.offered(for: sub(expiresIn: 5), isActive: true), [.lifetime])
        XCTAssertEqual(FamilyPlanView.offered(for: lifetime, isActive: true), [])
    }

    // MARK: - RevenueCat の購入情報の読み方

    private func reading(_ product: PlanProduct?, expiresIn days: Double? = nil, fetchedIn fetched: Double = 0) -> PlanJudge.Reading {
        PlanJudge.Reading(productID: product?.rawValue, expires: days.map { t0 + $0 * day }, fetchedAt: t0 + fetched * day)
    }

    func testActiveEntitlementBecomesTheRecord() {
        XCTAssertEqual(PlanJudge.next(remembered: nil, reading: reading(.yearly, expiresIn: 300), now: t0), sub(.yearly, expiresIn: 300))
        XCTAssertEqual(PlanJudge.next(remembered: sub(expiresIn: 5), reading: reading(.lifetime), now: t0), lifetime)
    }

    /// 権利が有効なら、知らない商品（RevenueCat の管理画面から付けた権利など）でも家族プランにする
    func testEntitlementFromAnUnknownProductStillCounts() {
        let granted = PlanJudge.Reading(productID: "rc_promo_family_lifetime", expires: nil, fetchedAt: t0)
        XCTAssertEqual(PlanJudge.next(remembered: nil, reading: granted, now: t0), lifetime)
        let timed = PlanJudge.Reading(productID: "rc_promo_family_monthly", expires: t0 + 30 * day, fetchedAt: t0)
        XCTAssertEqual(PlanJudge.next(remembered: nil, reading: timed, now: t0), sub(.monthly, expiresIn: 30))
    }

    /// 期限のあとにサーバーへ聞いて「権利なし」なら、解約や返金なので、猶予を置かずに無料へ戻す
    func testNoEntitlementFetchedAfterExpiryEndsThePlan() {
        XCTAssertNil(PlanJudge.next(remembered: sub(expiresIn: -1), reading: reading(nil, fetchedIn: -0.5), now: t0))
        XCTAssertNil(PlanJudge.next(remembered: lifetime, reading: reading(nil), now: t0))
    }

    /// 期限より前に聞いた古い控えしか無い（インターネットに出られない端末）なら、猶予のあいだは残す
    func testStaleReadingKeepsTheRecordDuringGrace() {
        XCTAssertEqual(PlanJudge.next(remembered: sub(expiresIn: -10), reading: reading(nil, fetchedIn: -12), now: t0), sub(expiresIn: -10))
        XCTAssertNil(PlanJudge.next(remembered: sub(expiresIn: -31), reading: reading(nil, fetchedIn: -40), now: t0))
    }

    /// 購入情報をまだ 1 度も読めていないときは、覚えている記録で判断する
    func testNoReadingKeepsTheRecord() {
        XCTAssertEqual(PlanJudge.next(remembered: lifetime, reading: nil, now: t0), lifetime)
        XCTAssertEqual(PlanJudge.next(remembered: sub(expiresIn: -10), reading: nil, now: t0), sub(expiresIn: -10))
    }

    func testRecordSurvivesJSON() throws {
        for record in [lifetime, sub(.yearly, expiresIn: 12.5)] {
            let data = try JSONEncoder().encode(record)
            XCTAssertEqual(try JSONDecoder().decode(PlanRecord.self, from: data), record)
        }
    }
}
