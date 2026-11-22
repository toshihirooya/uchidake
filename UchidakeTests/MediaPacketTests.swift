import CoreImage
import XCTest
@testable import Uchidake

final class MediaPacketTests: XCTestCase {
    func testEachKindSurvivesEncodingAndDecoding() {
        let status = CameraStatus(name: "リビング", battery: 80, isCharging: true, viewers: 2, usesFrontCamera: false)
        let packets: [MediaPacket] = [
            .video(frameID: 0x0102_0304, index: 3, count: 7, payload: Data([9, 8, 7])),
            .audio(sequence: 42, pcm: Data([1, 2, 3, 4])),
            .keyframeRequest,
            .keepAlive(isRecording: true, viewerID: nil),
            .status(status),
            .command(.switchCamera, sequence: 0xDEAD_BEEF),
        ]
        for packet in packets {
            XCTAssertEqual(MediaPacket(packet.encoded()), packet)
        }
    }

    func testKeepAliveCarriesRecordingFlag() {
        XCTAssertEqual(MediaPacket.keepAlive(isRecording: true, viewerID: nil).encoded(), Data([4, 1]))
        XCTAssertEqual(MediaPacket.keepAlive(isRecording: false, viewerID: nil).encoded(), Data([4, 0]))
        XCTAssertEqual(MediaPacket(Data([4, 1])), .keepAlive(isRecording: true, viewerID: nil))
        XCTAssertEqual(MediaPacket(Data([4, 0xFE])), .keepAlive(isRecording: false, viewerID: nil))  // ほかのビットは無視
    }

    func testKeepAliveCarriesViewerID() {
        let packet = MediaPacket.keepAlive(isRecording: true, viewerID: 0x0102_0304_0506_0708)
        XCTAssertEqual(packet.encoded(), Data([4, 1, 1, 2, 3, 4, 5, 6, 7, 8]))
        XCTAssertEqual(MediaPacket(packet.encoded()), packet)
    }

    func testKeepAliveWithoutIDIsReadAsNoID() {
        XCTAssertEqual(MediaPacket(Data([4, 1])), .keepAlive(isRecording: true, viewerID: nil))
        XCTAssertEqual(MediaPacket(Data([4, 0, 9, 9])), .keepAlive(isRecording: false, viewerID: nil))  // 半端な長さ
    }

    func testRefusalRoundTrips() {
        XCTAssertEqual(MediaPacket.refusal(.freeLimit).encoded(), Data([7, 1]))
        XCTAssertEqual(MediaPacket(Data([7, 2])), .refusal(.familyLimit))
        XCTAssertNil(MediaPacket(Data([7])))
        XCTAssertNil(MediaPacket(Data([7, 99])))
    }

    func testOldKeepAliveWithoutFlagMeansNotRecording() {
        XCTAssertEqual(MediaPacket(Data([4])), .keepAlive(isRecording: false, viewerID: nil))
    }

    func testStatusWithoutRecordersDecodesAsZero() throws {
        let old = #"{"name":"リビング","battery":80,"isCharging":true,"viewers":2,"usesFrontCamera":false}"#
        var data = Data([5]); data.append(Data(old.utf8))
        guard case .status(let status) = MediaPacket(data) else { return XCTFail() }
        XCTAssertEqual(status.recorders, 0)
        XCTAssertEqual(status.viewers, 2)
    }

    func testStatusRecordersSurvivesEncodingAndDecoding() {
        let status = CameraStatus(name: "a", battery: nil, isCharging: false, viewers: 3, usesFrontCamera: true, recorders: 2)
        XCTAssertEqual(MediaPacket(MediaPacket.status(status).encoded()), .status(status))
    }

    func testVideoHeaderLayoutIsBigEndian() {
        let data = MediaPacket.video(frameID: 0x0102_0304, index: 0x0506, count: 0x0708, payload: Data([0xAA])).encoded()
        XCTAssertEqual([UInt8](data), [1, 1, 2, 3, 4, 5, 6, 7, 8, 0xAA])
    }

    func testMalformedPacketsAreRejected() {
        XCTAssertNil(MediaPacket(Data()))
        XCTAssertNil(MediaPacket(Data([99])), "知らない種類")
        XCTAssertNil(MediaPacket(Data([1, 0, 0, 0, 1, 0, 0, 0, 1])), "映像なのに中身が無い")
        XCTAssertNil(MediaPacket(Data([2, 0, 0, 0, 1])), "音声なのに中身が無い")
        XCTAssertNil(MediaPacket(Data([5, 0x7B])), "状態の JSON が壊れている")
        XCTAssertNil(MediaPacket(Data([6, 0, 0, 0, 1, 200])), "知らない操作")
    }

    func testDecodingWorksOnASliceOfLargerData() {
        // Data の一部（先頭が 0 番目でないもの）を渡しても正しく読める
        let whole = Data([0xFF, 0xFF]) + MediaPacket.audio(sequence: 7, pcm: Data([5, 6])).encoded()
        XCTAssertEqual(MediaPacket(whole.dropFirst(2)), .audio(sequence: 7, pcm: Data([5, 6])))
    }

    func testFrameIsSplitIntoFragmentsThatRebuildIt() {
        let frame = Data((0..<2500).map { UInt8($0 % 251) })
        let packets = MediaPacket.videoPackets(frame: frame, frameID: 5)
        XCTAssertEqual(packets.count, 3)
        var rebuilt = Data()
        for (position, data) in packets.enumerated() {
            guard case .video(let frameID, let index, let count, let payload) = MediaPacket(data) else {
                return XCTFail("映像のパケットではない")
            }
            XCTAssertEqual(frameID, 5)
            XCTAssertEqual(index, position)
            XCTAssertEqual(count, 3)
            XCTAssertLessThanOrEqual(payload.count, MediaPacket.maxFragmentSize)
            rebuilt.append(payload)
        }
        XCTAssertEqual(rebuilt, frame)
    }

    func testEmptyFrameProducesNoPackets() {
        XCTAssertTrue(MediaPacket.videoPackets(frame: Data(), frameID: 0).isEmpty)
    }

    func testNeedsChargingOnlyWhenLowAndUnplugged() {
        var status = CameraStatus(name: "x", battery: 20, isCharging: false, viewers: 0, usesFrontCamera: false)
        XCTAssertTrue(status.needsCharging)
        status.isCharging = true
        XCTAssertFalse(status.needsCharging)
        status.isCharging = false
        status.battery = 21
        XCTAssertFalse(status.needsCharging)
        status.battery = nil
        XCTAssertFalse(status.needsCharging)
    }
}

final class VideoAssemblerTests: XCTestCase {
    private let keyframe = Data([1, 10, 11, 12])
    private let delta = Data([0, 20, 21, 22])

    /// 1 フレームを 2 つの断片に分けて渡す
    private func feed(_ assembler: inout VideoAssembler, id: UInt32, frame: Data, skipping skipped: Int? = nil) -> VideoAssembler.Result {
        let parts = [frame.prefix(2), frame.dropFirst(2)]
        var result = VideoAssembler.Result.incomplete
        for (index, part) in parts.enumerated() where index != skipped {
            result = assembler.receive(frameID: id, index: index, count: parts.count, payload: Data(part))
        }
        return result
    }

    func testKeyframeThenDeltasAreShown() {
        var assembler = VideoAssembler()
        XCTAssertEqual(feed(&assembler, id: 0, frame: keyframe), .show(keyframe))
        XCTAssertEqual(feed(&assembler, id: 1, frame: delta), .show(delta))
        XCTAssertEqual(feed(&assembler, id: 2, frame: delta), .show(delta))
    }

    func testFragmentsArrivingOutOfOrderStillRebuildTheFrame() {
        var assembler = VideoAssembler()
        XCTAssertEqual(assembler.receive(frameID: 0, index: 1, count: 2, payload: keyframe.dropFirst(2)), .incomplete)
        XCTAssertEqual(assembler.receive(frameID: 0, index: 0, count: 2, payload: keyframe.prefix(2)), .show(keyframe))
    }

    func testDeltaBeforeAnyKeyframeWaits() {
        var assembler = VideoAssembler()
        XCTAssertEqual(feed(&assembler, id: 7, frame: delta), .waitForKeyframe)
        XCTAssertEqual(feed(&assembler, id: 8, frame: keyframe), .show(keyframe))
    }

    func testLosingAFragmentHidesFollowingDeltasUntilNextKeyframe() {
        var assembler = VideoAssembler()
        XCTAssertEqual(feed(&assembler, id: 0, frame: keyframe), .show(keyframe))
        // 1 番のフレームは断片が 1 つ届かなかった
        XCTAssertEqual(feed(&assembler, id: 1, frame: delta, skipping: 1), .incomplete)
        // 2 番は全部届いたが、1 番が抜けているので表示できない
        XCTAssertEqual(feed(&assembler, id: 2, frame: delta), .waitForKeyframe)
        XCTAssertEqual(feed(&assembler, id: 3, frame: delta), .waitForKeyframe)
        XCTAssertEqual(feed(&assembler, id: 4, frame: keyframe), .show(keyframe))
        XCTAssertEqual(feed(&assembler, id: 5, frame: delta), .show(delta))
    }

    func testLateFragmentsOfFinishedFramesAreIgnored() {
        var assembler = VideoAssembler()
        XCTAssertEqual(feed(&assembler, id: 5, frame: keyframe), .show(keyframe))
        XCTAssertEqual(feed(&assembler, id: 6, frame: delta), .show(delta))
        // 遅れて届いた 5 番の断片
        XCTAssertEqual(assembler.receive(frameID: 5, index: 0, count: 2, payload: keyframe.prefix(2)), .incomplete)
        // そのあとも続きは普通に表示できる
        XCTAssertEqual(feed(&assembler, id: 7, frame: delta), .show(delta))
    }

    func testDecodeFailureWaitsForNextKeyframe() {
        var assembler = VideoAssembler()
        XCTAssertEqual(feed(&assembler, id: 0, frame: keyframe), .show(keyframe))
        assembler.decodeFailed()
        XCTAssertEqual(feed(&assembler, id: 1, frame: delta), .waitForKeyframe)
        XCTAssertEqual(feed(&assembler, id: 2, frame: keyframe), .show(keyframe))
    }

    func testNonsenseFragmentNumbersAreIgnored() {
        var assembler = VideoAssembler()
        XCTAssertEqual(assembler.receive(frameID: 0, index: 0, count: 0, payload: keyframe), .incomplete)
        XCTAssertEqual(assembler.receive(frameID: 0, index: 5, count: 2, payload: keyframe), .incomplete)
        XCTAssertEqual(assembler.receive(frameID: 0, index: -1, count: 2, payload: keyframe), .incomplete)
        // 同じフレームなのに総数が食い違う断片は無視する
        XCTAssertEqual(assembler.receive(frameID: 1, index: 0, count: 2, payload: keyframe.prefix(2)), .incomplete)
        XCTAssertEqual(assembler.receive(frameID: 1, index: 1, count: 3, payload: keyframe.dropFirst(2)), .incomplete)
        XCTAssertEqual(assembler.receive(frameID: 1, index: 1, count: 2, payload: keyframe.dropFirst(2)), .show(keyframe))
    }

    func testFrameNumberWrapsAround() {
        var assembler = VideoAssembler()
        XCTAssertEqual(feed(&assembler, id: UInt32.max, frame: keyframe), .show(keyframe))
        XCTAssertEqual(feed(&assembler, id: 0, frame: delta), .show(delta))
    }
}

final class PairingKeyTests: XCTestCase {
    func testGeneratedKeysAreRandomAndFullLength() {
        let first = PairingKey.generate()
        XCTAssertEqual(first?.count, 32)
        XCTAssertNotEqual(first, PairingKey.generate())
    }

    func testCodeRoundTrip() throws {
        let key = try XCTUnwrap(PairingKey.generate())
        let code = PairingKey.code(for: key)
        XCTAssertTrue(code.hasPrefix("UCHIDAKE1:"))
        XCTAssertEqual(code.count, 10 + 43)
        XCTAssertEqual(PairingKey.key(fromCode: code), key)
        XCTAssertEqual(PairingKey.key(fromCode: "  \(code)\n"), key)
    }

    func testCodeUsesURLSafeAlphabetWithoutPadding() {
        // 0xFB 0xFF … は、ふつうの base64 だと + と / が出る
        let key = Data([0xFB, 0xFF] + [UInt8](repeating: 0xFE, count: 30))
        let text = PairingKey.base64URL(key)
        XCTAssertFalse(text.contains("+") || text.contains("/") || text.contains("="))
        XCTAssertEqual(PairingKey.key(base64URL: text), key)
    }

    func testRejectsOtherCodes() {
        let valid = PairingKey.base64URL(Data(repeating: 7, count: 32))
        XCTAssertNil(PairingKey.key(fromCode: "https://example.com/"))
        XCTAssertNil(PairingKey.key(fromCode: valid))  // 先頭の目印が無い
        XCTAssertNil(PairingKey.key(fromCode: "UCHIDAKE2:" + valid))
        XCTAssertNil(PairingKey.key(fromCode: "UCHIDAKE1:"))
        XCTAssertNil(PairingKey.key(fromCode: "UCHIDAKE1:" + PairingKey.base64URL(Data(repeating: 7, count: 31))))
        XCTAssertNil(PairingKey.key(fromCode: "UCHIDAKE1:" + PairingKey.base64URL(Data(repeating: 7, count: 33))))
        XCTAssertNil(PairingKey.key(fromCode: "UCHIDAKE1:" + String(valid.dropLast()) + "!"))
    }

    func testQRImageDecodesBackToTheKey() throws {
        let key = try XCTUnwrap(PairingKey.generate())
        let image = try XCTUnwrap(PairingKey.qrImage(for: key))
        let cgImage = try XCTUnwrap(image.cgImage)
        let context = CIContext(options: [.useSoftwareRenderer: true])
        let detector = try XCTUnwrap(CIDetector(ofType: CIDetectorTypeQRCode, context: context, options: nil))
        let features = detector.features(in: CIImage(cgImage: cgImage))
        let message = try XCTUnwrap((features.first as? CIQRCodeFeature)?.messageString)
        XCTAssertEqual(PairingKey.key(fromCode: message), key)
    }
}
