import AVFoundation
import XCTest
@testable import Uchidake

final class ViewerAdmissionTests: XCTestCase {
    func testLimits() {
        XCTAssertEqual(ViewerAdmission.limit(hasFamilyPlan: false), 1)
        XCTAssertEqual(ViewerAdmission.limit(hasFamilyPlan: true), 4)
    }

    func testFreeCameraAdmitsFirstAndRefusesSecond() {
        XCTAssertEqual(ViewerAdmission.decide(newID: 1, admitted: [], hasFamilyPlan: false), .admit)
        XCTAssertEqual(ViewerAdmission.decide(newID: 2, admitted: [1], hasFamilyPlan: false), .refuse(.freeLimit))
    }

    /// Wi-Fi が一瞬切れてつなぎ直した端末は、自分の古い枠に断られない
    func testSameViewerReplacesItsOldSlot() {
        XCTAssertEqual(ViewerAdmission.decide(newID: 1, admitted: [1], hasFamilyPlan: false), .replace(index: 0))
        XCTAssertEqual(ViewerAdmission.decide(newID: 3, admitted: [1, 2, 3, 4], hasFamilyPlan: true), .replace(index: 2))
    }

    func testOldViewerWithoutIDIsNeverTreatedAsTheSame() {
        XCTAssertEqual(ViewerAdmission.decide(newID: nil, admitted: [nil], hasFamilyPlan: false), .refuse(.freeLimit))
    }

    func testFamilyCameraRefusesFifth() {
        XCTAssertEqual(ViewerAdmission.decide(newID: 5, admitted: [1, 2, 3, 4], hasFamilyPlan: true), .refuse(.familyLimit))
    }

    /// 4 台が見ている最中に家族プランが切れても、入っている相手は入れ替われる。新しい相手は 1 台に減るまで入れない
    func testAfterPlanEndsNobodyNewGetsInUntilOneIsLeft() {
        XCTAssertEqual(ViewerAdmission.decide(newID: 5, admitted: [1, 2, 3, 4], hasFamilyPlan: false), .refuse(.freeLimit))
        XCTAssertEqual(ViewerAdmission.decide(newID: 5, admitted: [1], hasFamilyPlan: false), .refuse(.freeLimit))
        XCTAssertEqual(ViewerAdmission.decide(newID: 2, admitted: [1, 2, 3, 4], hasFamilyPlan: false), .replace(index: 1))
        XCTAssertEqual(ViewerAdmission.decide(newID: 5, admitted: [], hasFamilyPlan: false), .admit)
    }
}

final class ViewerRefusalTests: XCTestCase {
    /// 断られたら理由を出す。「つながらない」の回数には数えず、次に映像や状態が届いたら消す
    func testRefusalIsShownAndClearedByNextStatus() {
        let engine = ViewerEngine(endpoint: .hostPort(host: "127.0.0.1", port: 9), key: Data(count: 32), layer: AVSampleBufferDisplayLayer())
        var snapshots: [ViewerEngine.Snapshot] = []
        let refused = expectation(description: "断られた")
        let cleared = expectation(description: "消えた")
        engine.onChange = { snapshot in
            snapshots.append(snapshot)
            if snapshot.refusal == .freeLimit, snapshots.count == 1 { refused.fulfill() }
            if snapshot.refusal == nil, snapshot.status != nil { cleared.fulfill() }
        }
        engine.receiveForTesting(.refusal(.freeLimit))
        wait(for: [refused], timeout: 2)
        XCTAssertEqual(snapshots.last?.failedAttempts, 0)
        XCTAssertEqual(snapshots.last?.phase, .connecting)
        engine.receiveForTesting(.status(CameraStatus(name: "リビング", battery: nil, isCharging: false, viewers: 1, usesFrontCamera: false)))
        wait(for: [cleared], timeout: 2)
        engine.stop()
    }
}
