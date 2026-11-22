import XCTest
@testable import Uchidake

/// カメラを始めるまでの段階（許可、ほかのカメラの確認、家族プラン）。
@MainActor
final class CameraStationTests: XCTestCase {
    private let key = Data(repeating: 7, count: 32)
    private var plan: FamilyPlanStore!
    private var station: CameraStation?

    override func setUp() async throws {
        plan = FamilyPlanStore(defaults: UserDefaults(suiteName: "CameraStationTests-\(UUID().uuidString)")!)
        plan.debugOverride = false
    }

    override func tearDown() async throws {
        station?.stop()
        station = nil
    }

    /// 同じ組で動いている、家族プランの無いカメラ
    private var rival: [(name: String, advert: CameraAdvert?)] {
        [("リビング", CameraAdvert(familyTag: CameraAdvert.familyTag(key: key), hasPlan: false, isRunning: true, since: 1, deviceID: "rival"))]
    }

    private func makeStation(access: Bool = true, others: [(name: String, advert: CameraAdvert?)] = [],
                             reachable: Bool = true) -> CameraStation {
        let station = CameraStation(
            name: "寝室", key: key, plan: plan,
            access: { access }, survey: { others }, probe: { _, _ in reachable })
        self.station = station
        return station
    }

    private func wait(for station: CameraStation, toBe phase: CameraStation.Phase) async {
        for _ in 0..<50 where station.phase != phase {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// カメラの許可が無いときは、確認中の表示のままにせず、理由を出せる段階にする
    func testDeniedCameraIsUnavailableNotChecking() async {
        let station = makeStation(access: false)
        await station.start()
        XCTAssertEqual(station.phase, .unavailable)
        XCTAssertEqual(station.problem, .cameraDenied)
    }

    func testAloneFreeCameraRuns() async {
        let station = makeStation()
        await station.start()
        XCTAssertEqual(station.phase, .running)
    }

    func testLiveFreeRivalBlocks() async {
        let station = makeStation(others: rival, reachable: true)
        await station.start()
        XCTAssertEqual(station.phase, .blocked(by: "リビング"))
    }

    /// 電池切れなどで消えたカメラの広告が残っていても、それで止めない
    func testStaleRivalThatCannotBeReachedDoesNotBlock() async {
        let station = makeStation(others: rival, reachable: false)
        await station.start()
        XCTAssertEqual(station.phase, .running)
    }

    /// 始められずにいる画面を開いたまま家族プランが有効になったら、そのまま始める
    func testBlockedCameraStartsWhenPlanBecomesActive() async {
        let station = makeStation(others: rival, reachable: true)
        await station.start()
        XCTAssertEqual(station.phase, .blocked(by: "リビング"))
        plan.debugOverride = true
        await wait(for: station, toBe: .running)
        XCTAssertEqual(station.phase, .running)
    }

    func testCameraWithPlanSkipsTheSurvey() async {
        plan.debugOverride = true
        let station = makeStation(others: rival, reachable: true)
        await station.start()
        XCTAssertEqual(station.phase, .running)
    }
}
