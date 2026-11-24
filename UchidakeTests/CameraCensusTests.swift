import XCTest
@testable import Uchidake

final class CameraCensusTests: XCTestCase {
    private let key = Data(repeating: 7, count: 32)

    private func ad(_ id: String, plan: Bool = false, running: Bool = true, since: Int = 100, tag: String? = nil) -> CameraAdvert {
        CameraAdvert(familyTag: tag ?? CameraAdvert.familyTag(key: key), hasPlan: plan, isRunning: running, since: since, deviceID: id)
    }

    /// 始めようとしている、家族プランの無いカメラ
    private var me: CameraAdvert { ad("me", running: false, since: 200) }

    func testFamilyTagIsStableSixteenHexAndDependsOnKey() {
        let tag = CameraAdvert.familyTag(key: key)
        XCTAssertEqual(tag.count, 16)
        XCTAssertTrue(tag.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        XCTAssertEqual(tag, CameraAdvert.familyTag(key: key))
        XCTAssertNotEqual(tag, CameraAdvert.familyTag(key: Data(repeating: 8, count: 32)))
    }

    func testAdvertSurvivesTXT() {
        XCTAssertEqual(CameraAdvert(txt: me.txt), me)
        XCTAssertEqual(me.txt, ["f": me.familyTag, "p": "0", "r": "0", "s": "200", "i": "me"])
    }

    /// ほかのアプリや古い版の広告は、読めないものとして扱う
    func testBrokenTXTIsNotAnAdvert() {
        XCTAssertNil(CameraAdvert(txt: [:]))
        XCTAssertNil(CameraAdvert(txt: ["f": "x", "p": "0", "r": "1", "s": "abc", "i": "a"]))
        XCTAssertNil(CameraAdvert(txt: ["f": "x", "p": "0", "r": "1", "s": "1"]))
    }

    func testAloneStarts() {
        XCTAssertEqual(CameraCensus.decide(me: me, others: []), .start)
    }

    /// 探索では自分の広告も見つかる。それで止まってはいけない
    func testOwnAdvertIsNotAnotherCamera() {
        XCTAssertEqual(CameraCensus.decide(me: me, others: [("カメラ", ad("me", running: true))]), .start)
    }

    func testRunningFreeCameraOfSameFamilyBlocks() {
        XCTAssertEqual(CameraCensus.decide(me: me, others: [("リビング", ad("a"))]), .blocked(by: "リビング"))
    }

    func testCameraWithPlanDoesNotBlock() {
        XCTAssertEqual(CameraCensus.decide(me: me, others: [("リビング", ad("a", plan: true))]), .start)
    }

    func testOtherFamilyAndUnreadableAdvertsDoNotBlock() {
        XCTAssertEqual(CameraCensus.decide(me: me, others: [("隣", ad("a", tag: "0000000000000000")), ("古い版", nil)]), .start)
    }

    func testIHaveThePlanSoIAlwaysStart() {
        var planned = me
        planned.hasPlan = true
        XCTAssertEqual(CameraCensus.decide(me: planned, others: [("リビング", ad("a"))]), .start)
    }

    /// 停電のあとなど、同時に始めようとしたら、先にカメラになったほうが残る
    func testWhenBothAreStartingTheOlderOneWins() {
        XCTAssertEqual(CameraCensus.decide(me: me, others: [("寝室", ad("a", running: false, since: 100))]), .blocked(by: "寝室"))
        XCTAssertEqual(CameraCensus.decide(me: me, others: [("寝室", ad("a", running: false, since: 300))]), .start)
    }

    func testSameAgeIsSettledByDeviceID() {
        XCTAssertEqual(CameraCensus.decide(me: me, others: [("寝室", ad("aa", running: false, since: 200))]), .blocked(by: "寝室"))
        XCTAssertEqual(CameraCensus.decide(me: me, others: [("寝室", ad("zz", running: false, since: 200))]), .start)
    }
}
