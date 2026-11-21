import XCTest
@testable import Uchidake

final class RecorderTallyTests: XCTestCase {
    private final class Token {}

    func testCountsEachRecordingViewerOnce() {
        var tally = RecorderTally()
        let a = Token(), b = Token()
        XCTAssertTrue(tally.update(viewer: ObjectIdentifier(a), isRecording: true))
        XCTAssertFalse(tally.update(viewer: ObjectIdentifier(a), isRecording: true))  // 毎秒届く
        XCTAssertTrue(tally.update(viewer: ObjectIdentifier(b), isRecording: true))
        XCTAssertEqual(tally.count, 2)
        XCTAssertTrue(tally.update(viewer: ObjectIdentifier(a), isRecording: false))
        XCTAssertEqual(tally.count, 1)
    }

    // 止めずに消えた見る側は、切れた時点で数から外れる
    func testRemovingAViewerClearsItsRecording() {
        var tally = RecorderTally()
        let a = Token()
        _ = tally.update(viewer: ObjectIdentifier(a), isRecording: true)
        XCTAssertTrue(tally.remove(viewer: ObjectIdentifier(a)))
        XCTAssertEqual(tally.count, 0)
        XCTAssertFalse(tally.remove(viewer: ObjectIdentifier(a)))
    }
}
