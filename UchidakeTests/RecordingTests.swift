import AVFoundation
import CoreMedia
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

// MARK: - テスト用の道具

/// 単色の画像を `H264Encoder` に 1/30 秒刻みで通し、出てきたコマを順に返す。最後のコマだけ `lastColor` にできる。
func makeFrames(count: Int, width: Int = 640, height: Int = 480, lastColor: (r: UInt8, g: UInt8, b: UInt8)? = nil) -> [Data] {
    let encoder = H264Encoder()
    let lock = NSLock()
    var frames: [Data] = []
    let encoded = XCTestExpectation(description: "全部のコマが圧縮された")
    encoded.expectedFulfillmentCount = count
    encoder.onFrame = { frame in
        lock.lock()
        frames.append(frame)
        lock.unlock()
        encoded.fulfill()
    }
    let gray: (r: UInt8, g: UInt8, b: UInt8) = (128, 128, 128)
    for i in 0..<count {
        let color = i == count - 1 ? (lastColor ?? gray) : gray
        encoder.encode(solidPixelBuffer(width: width, height: height, color: color), at: CMTime(value: Int64(i), timescale: 30))
    }
    // 圧縮器は数コマためてから出すことがあるので、出し切らせてから待つ
    encoder.finish()
    if XCTWaiter().wait(for: [encoded], timeout: 10) != .completed {
        XCTFail("圧縮が \(count) コマぶん終わらなかった")
    }
    encoder.stop()
    lock.lock()
    defer { lock.unlock() }
    return frames
}

/// テストで使う時刻（端末の時計の秒数のつもり）
func hostTime(_ seconds: Double) -> CMTime {
    CMTime(seconds: seconds, preferredTimescale: 1_000_000_000)
}

private func solidPixelBuffer(width: Int, height: Int, color: (r: UInt8, g: UInt8, b: UInt8)) -> CVPixelBuffer {
    var created: CVPixelBuffer?
    let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
    CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attributes, &created)
    let buffer = created!
    CVPixelBufferLockBaseAddress(buffer, [])
    let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
    let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
    for y in 0..<height {
        let row = base + y * bytesPerRow
        for x in 0..<width {
            row[x * 4] = color.b
            row[x * 4 + 1] = color.g
            row[x * 4 + 2] = color.r
            row[x * 4 + 3] = 255
        }
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])
    return buffer
}

/// 画像の中央の画素の色
private func centerPixel(of image: CGImage) -> (r: Int, g: Int, b: Int) {
    var pixel = [UInt8](repeating: 0, count: 4)
    pixel.withUnsafeMutableBytes { raw in
        let context = CGContext(
            data: raw.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // 中央の画素が (0, 0) に来るようにずらして描く
        context.draw(image, in: CGRect(
            x: -CGFloat(image.width / 2), y: -CGFloat(image.height / 2),
            width: CGFloat(image.width), height: CGFloat(image.height)))
    }
    return (Int(pixel[0]), Int(pixel[1]), Int(pixel[2]))
}

// MARK: - 写真

final class GopBufferTests: XCTestCase {
    func testKeepsFramesSinceLastKeyframe() {
        var buffer = GopBuffer()
        buffer.append(Data([0, 9]))            // キーフレームの前の差分は覚えない
        XCTAssertTrue(buffer.isEmpty)
        buffer.append(Data([1, 1])); buffer.append(Data([0, 2])); buffer.append(Data([0, 3]))
        XCTAssertEqual(buffer.frames.count, 3)
        buffer.append(Data([1, 4]))
        XCTAssertEqual(buffer.frames, [Data([1, 4])])
        buffer.reset()
        XCTAssertTrue(buffer.isEmpty)
    }
}

final class StillDecoderTests: XCTestCase {
    func testDecodesTheLastFrameOfAGop() throws {
        let frames = makeFrames(count: 10, lastColor: (r: 255, g: 0, b: 0))
        let image = try XCTUnwrap(StillDecoder.lastImage(from: frames))
        XCTAssertEqual(image.width, 640); XCTAssertEqual(image.height, 480)
        // 中央の画素が赤に近い（圧縮の誤差を見込む）
        let (r, g, b) = centerPixel(of: image)
        XCTAssertGreaterThan(r, 180); XCTAssertLessThan(g, 80); XCTAssertLessThan(b, 80)
        let jpeg = try XCTUnwrap(StillDecoder.jpegData(from: image))
        XCTAssertEqual(jpeg.prefix(2), Data([0xFF, 0xD8]))
    }

    func testReturnsNilWithoutALeadingKeyframeOrOnGarbage() {
        XCTAssertNil(StillDecoder.lastImage(from: []))
        XCTAssertNil(StillDecoder.lastImage(from: [Data([0, 1, 2, 3])]))
        XCTAssertNil(StillDecoder.lastImage(from: [Data([1, 0, 4, 1, 2])]))  // 壊れたキーフレーム
    }
}

// MARK: - 録画

final class AudioTimelineTests: XCTestCase {
    func testPacketsArrivingOnTimeAreContiguous() {
        var timeline = AudioTimeline()
        XCTAssertEqual(timeline.timestamp(sampleCount: 480, arrival: hostTime(10.000)).seconds, 10.000, accuracy: 0.0001)
        // 少し遅れて届いても、前の続きに置く
        XCTAssertEqual(timeline.timestamp(sampleCount: 480, arrival: hostTime(10.050)).seconds, 10.030, accuracy: 0.0001)
    }

    func testAGapLongerThanThresholdResyncsToArrival() {
        var timeline = AudioTimeline()
        _ = timeline.timestamp(sampleCount: 480, arrival: hostTime(10))
        XCTAssertEqual(timeline.timestamp(sampleCount: 480, arrival: hostTime(11)).seconds, 11, accuracy: 0.0001)
    }
}

final class StreamRecorderTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("StreamRecorderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// 渡した操作を直列キューの上で実行し、finish の完了まで待って、できたファイルの URL を順に返す。
    private func record(_ operations: @escaping (StreamRecorder) -> Void) -> [URL] {
        let queue = DispatchQueue(label: "StreamRecorderTests")
        let lock = NSLock()
        var urls: [URL] = []
        let finished = expectation(description: "finish が終わった")
        queue.async { [directory] in
            let recorder = StreamRecorder(directory: directory!)
            recorder.onFileFinished = { url in
                lock.lock()
                urls.append(url)
                lock.unlock()
            }
            operations(recorder)
            recorder.finish { finished.fulfill() }
        }
        wait(for: [finished], timeout: 10)
        lock.lock()
        defer { lock.unlock() }
        return urls
    }

    func testWritesAPlayableMovieWithVideoAndAudio() async throws {
        let frames = makeFrames(count: 30)
        let urls = record { recorder in
            for (i, frame) in frames.enumerated() { recorder.appendVideo(frame, at: hostTime(100 + Double(i) / 30)) }
            for i in 0..<33 { recorder.appendAudio(Data(count: 960), at: hostTime(100 + Double(i) * 0.03)) }
        }
        XCTAssertEqual(urls.count, 1)
        XCTAssertEqual(urls[0].pathExtension, "mp4"); XCTAssertFalse(urls[0].lastPathComponent.contains(".partial"))
        let asset = AVURLAsset(url: urls[0])
        let video = try await asset.loadTracks(withMediaType: .video)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(video.count, 1); XCTAssertEqual(audio.count, 1)
        let size = try await video[0].load(.naturalSize)
        XCTAssertEqual(size, CGSize(width: 640, height: 480))
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, 1.0, accuracy: 0.2)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).allSatisfy { !$0.contains(".partial") })
    }

    // Review Focus 3
    func testVideoOnlyStillProducesAMovie() async throws {
        let frames = makeFrames(count: 15)
        let urls = record { r in for (i, f) in frames.enumerated() { r.appendVideo(f, at: hostTime(Double(i) / 30)) } }
        XCTAssertEqual(urls.count, 1)
        let audioTracks = try await AVURLAsset(url: urls[0]).loadTracks(withMediaType: .audio)
        XCTAssertTrue(audioTracks.isEmpty)
    }

    // Review Focus 2
    func testNothingWrittenLeavesNoFile() throws {
        let deltasOnly = Array(makeFrames(count: 5).dropFirst())
        let urls = record { r in
            for (i, f) in deltasOnly.enumerated() { r.appendVideo(f, at: hostTime(Double(i) / 30)) }
            r.appendAudio(Data(count: 960), at: hostTime(0))
            XCTAssertFalse(r.hasContent)
        }
        XCTAssertTrue(urls.isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    func testSizeChangeSplitsIntoTwoMovies() async throws {
        let landscape = makeFrames(count: 15), portrait = makeFrames(count: 15, width: 480, height: 640)
        let urls = record { r in
            for (i, f) in (landscape + portrait).enumerated() { r.appendVideo(f, at: hostTime(Double(i) / 30)) }
        }
        XCTAssertEqual(urls.count, 2)
        let second = try await AVURLAsset(url: urls[1]).loadTracks(withMediaType: .video)[0].load(.naturalSize)
        XCTAssertEqual(second, CGSize(width: 480, height: 640))
    }

    // Review Focus 5
    func testFinishingTwiceProducesOneMovie() {
        // finish を 2 回呼んでも、onFileFinished は 1 回、completion は 2 回とも呼ばれる
        let frames = makeFrames(count: 15)
        let fileFinished = expectation(description: "onFileFinished")
        fileFinished.expectedFulfillmentCount = 1
        fileFinished.assertForOverFulfill = true
        let completed = expectation(description: "completion")
        completed.expectedFulfillmentCount = 2
        completed.assertForOverFulfill = true
        let queue = DispatchQueue(label: "StreamRecorderTests")
        queue.async { [directory] in
            let recorder = StreamRecorder(directory: directory!)
            recorder.onFileFinished = { _ in fileFinished.fulfill() }
            for (i, f) in frames.enumerated() { recorder.appendVideo(f, at: hostTime(Double(i) / 30)) }
            recorder.finish { completed.fulfill() }
            recorder.finish { completed.fulfill() }
        }
        wait(for: [fileFinished, completed], timeout: 10)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        XCTAssertEqual(files.count, 1)
        XCTAssertTrue(files.allSatisfy { !$0.contains(".partial") })
    }
}
