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
        XCTAssertEqual(timeline.place(sampleCount: 480, arrival: hostTime(10.000)).start.seconds, 10.000, accuracy: 0.0001)
        // 少し遅れて届いても、前の続きに置く
        let late = timeline.place(sampleCount: 480, arrival: hostTime(10.050))
        XCTAssertEqual(late.start.seconds, 10.030, accuracy: 0.0001)
        XCTAssertEqual(late.silence, 0)
    }

    // 合わせ直すときは、前の音の終わりから届いた時刻までを無音で埋める
    func testAGapLongerThanThresholdResyncsToArrivalWithSilence() {
        var timeline = AudioTimeline()
        _ = timeline.place(sampleCount: 480, arrival: hostTime(10))
        let resynced = timeline.place(sampleCount: 480, arrival: hostTime(11))
        XCTAssertEqual(resynced.start.seconds, 11, accuracy: 0.0001)
        XCTAssertEqual(resynced.silence, 15_520)  // 10.03 秒から 11 秒まで
        XCTAssertEqual(resynced.silenceStart.seconds, 10.030, accuracy: 0.0001)
    }

    // 止まったあとにまとめて届いても、時刻は戻さない（前の音に重ねない）
    func testBurstAfterStallNeverMovesBackward() {
        var timeline = AudioTimeline()
        _ = timeline.place(sampleCount: 480, arrival: hostTime(10))
        // 0.22 秒止まって、たまっていた 10 個が同じ時刻にまとめて届く
        var previous = timeline.place(sampleCount: 480, arrival: hostTime(10.25))
        XCTAssertEqual(previous.start.seconds, 10.25, accuracy: 0.0001)
        for _ in 0..<9 {
            let placement = timeline.place(sampleCount: 480, arrival: hostTime(10.25))
            XCTAssertEqual((placement.start - previous.start).seconds, 0.03, accuracy: 0.0001)
            XCTAssertEqual(placement.silence, 0)
            previous = placement
        }
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

    // 音声が 2 秒届かなかったあとも、音声は映像と同じ時刻に並ぶ（届かなかったところは無音）
    func testAudioGapKeepsAudioAlignedWithVideo() async throws {
        let frames = makeFrames(count: 120)
        let urls = record { recorder in
            // 映像は 4 秒間、届いた時刻のまま。音声は始めの 1 秒と終わりの 1 秒だけ届く
            for (i, frame) in frames.enumerated() { recorder.appendVideo(frame, at: hostTime(100 + Double(i) / 30)) }
            for i in 0..<33 { recorder.appendAudio(Data(count: 960), at: hostTime(100 + Double(i) * 0.03)) }
            for i in 0..<33 { recorder.appendAudio(Data(count: 960), at: hostTime(103 + Double(i) * 0.03)) }
        }
        XCTAssertEqual(urls.count, 1)
        let asset = AVURLAsset(url: urls[0])
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let video = try XCTUnwrap(videoTracks.first), audio = try XCTUnwrap(audioTracks.first)
        let videoRange = try await video.load(.timeRange)
        let audioRange = try await audio.load(.timeRange)
        XCTAssertEqual(videoRange.duration.seconds, 4.0, accuracy: 0.1)
        XCTAssertEqual(audioRange.start.seconds, videoRange.start.seconds, accuracy: 0.1)
        XCTAssertEqual(audioRange.end.seconds, videoRange.end.seconds, accuracy: 0.15)
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

    // 書き込みが追いつかずに落としたコマの後は、次のキーフレームまで差分を書かない
    func testDroppedFrameSkipsDeltasUntilNextKeyframe() async throws {
        let first = makeFrames(count: 15), second = makeFrames(count: 15)
        XCTAssertEqual(second.first?.first, 1)
        let dropped = hostTime(3.0 / 30)
        let urls = record { r in
            r.videoReadinessOverride = { $0 != dropped }
            for (i, f) in (first + second).enumerated() { r.appendVideo(f, at: hostTime(Double(i) / 30)) }
        }
        XCTAssertEqual(urls.count, 1)
        // 落とす前の 3 コマと、次のキーフレームからの 15 コマ。書き直しはキーフレームから
        let samples = try await videoSamples(of: urls[0])
        XCTAssertEqual(samples.count, 18)
        XCTAssertEqual(samples.map(\.isKeyframe), [true, false, false, true] + Array(repeating: false, count: 14))
        XCTAssertEqual((samples[3].time - samples[0].time).seconds, 15.0 / 30, accuracy: 0.001)
    }

    // ファイルの最初のキーフレームを落としたら、差分から始まるファイルにしない
    func testDroppedOpeningKeyframeWaitsForNextKeyframe() async throws {
        let first = makeFrames(count: 15), second = makeFrames(count: 15)
        let urls = record { r in
            r.videoReadinessOverride = { $0 != hostTime(0) }
            for (i, f) in (first + second).enumerated() { r.appendVideo(f, at: hostTime(Double(i) / 30)) }
        }
        XCTAssertEqual(urls.count, 1)
        let samples = try await videoSamples(of: urls[0])
        XCTAssertEqual(samples.count, 15)
        XCTAssertEqual(samples.first?.isKeyframe, true)
        // 落としたキーフレームの時刻からではなく、次のキーフレームから始まる（0.5 秒ぶん）
        let duration = try await AVURLAsset(url: urls[0]).load(.duration).seconds
        XCTAssertEqual(duration, 0.5, accuracy: 0.1)
    }

    /// 動画の映像トラックに書かれたコマを順に返す（表示時刻と、キーフレームか）
    private func videoSamples(of url: URL) async throws -> [(time: CMTime, isKeyframe: Bool)] {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var samples: [(time: CMTime, isKeyframe: Bool)] = []
        while let sample = output.copyNextSampleBuffer() {
            guard CMSampleBufferGetNumSamples(sample) > 0 else { continue }
            let data = try XCTUnwrap(sample.dataBuffer).dataBytes()
            samples.append((sample.presentationTimeStamp, containsIDRSlice(data)))
        }
        return samples
    }

    /// AVCC 形式（各 NAL の前に 4 バイトの長さ）のコマに、IDR（種類 5）の NAL があるか
    private func containsIDRSlice(_ data: Data) -> Bool {
        let bytes = [UInt8](data)
        var offset = 0
        while offset + 4 < bytes.count {
            let length = bytes[offset..<offset + 4].reduce(0) { $0 << 8 | Int($1) }
            if bytes[offset + 4] & 0x1F == 5 { return true }
            offset += 4 + length
        }
        return false
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

// MARK: - MediaSaver

/// 「写真」の偽物。許可の有無・失敗させるか・受け取ったものを持つ。
private final class FakeLibrary: PhotoLibrary {
    var permitted = true
    var fails = false
    private(set) var photos: [Data] = []
    private(set) var videos: [URL] = []

    struct Failure: Error {}

    func requestAddPermission() async -> Bool { permitted }
    var hasAddPermission: Bool { permitted }

    func addPhoto(_ jpeg: Data) async throws {
        if fails { throw Failure() }
        photos.append(jpeg)
    }

    func addVideo(at url: URL) async throws {
        if fails { throw Failure() }
        videos.append(url)
    }
}

@MainActor
final class MediaSaverTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("MediaSaverTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func file(_ name: String) -> URL {
        let url = directory.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: Data([0]))
        return url
    }

    func testSavedVideoIsRemovedFromDisk() async {
        let library = FakeLibrary(), saver = MediaSaver(library: library, directory: directory)
        let url = file("recording-a.mp4")
        await saver.saveVideo(at: url)
        XCTAssertEqual(library.videos, [url]); XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(saver.notice, .videoSaved); XCTAssertEqual(saver.pendingVideos, 0)
    }

    func testFailedVideoStaysOnDiskAndIsRetriedAtNextLaunch() async {
        let library = FakeLibrary(); library.fails = true
        let url = file("recording-a.mp4")
        let saver = MediaSaver(library: library, directory: directory)
        await saver.saveVideo(at: url)
        XCTAssertEqual(saver.notice, .videoFailed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        library.fails = false
        let next = MediaSaver(library: library, directory: directory)
        await next.recoverLeftovers()
        XCTAssertEqual(library.videos, [url]); XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testRecoveryDeletesUnfinishedFiles() async {
        let library = FakeLibrary(), partial = file("recording-b.partial.mp4")
        await MediaSaver(library: library, directory: directory).recoverLeftovers()
        XCTAssertTrue(library.videos.isEmpty); XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
    }

    func testDeniedPermissionSavesNothingAndSaysSo() async {
        let library = FakeLibrary(); library.permitted = false
        let saver = MediaSaver(library: library, directory: directory)
        let allowed = await saver.ensurePermission()
        XCTAssertFalse(allowed); XCTAssertEqual(saver.notice, .permissionDenied)
        let url = file("recording-a.mp4")
        await saver.recoverLeftovers()
        XCTAssertTrue(library.videos.isEmpty); XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testPhotoSaveReportsResult() async {
        let library = FakeLibrary(), saver = MediaSaver(library: library, directory: directory)
        await saver.savePhoto(Data([0xFF, 0xD8]))
        XCTAssertEqual(library.photos.count, 1); XCTAssertEqual(saver.notice, .photoSaved)
        library.fails = true
        await saver.savePhoto(Data([0xFF, 0xD8]))
        XCTAssertEqual(saver.notice, .photoFailed)
    }

    // .onAppear はもう一度来ることがある。2 回目に録画中の *.partial.mp4 を消してはいけない
    func testRecoveryRunsOnlyOncePerSaver() async {
        let library = FakeLibrary(), saver = MediaSaver(library: library, directory: directory)
        await saver.recoverLeftovers()
        let recording = file("recording-c.partial.mp4")
        await saver.recoverLeftovers()
        XCTAssertTrue(FileManager.default.fileExists(atPath: recording.path))
    }

    func testFreeBytesIsReadableForExistingDirectory() {
        XCTAssertNotNil(MediaSaver.freeBytes(at: directory))
        XCTAssertTrue(MediaSaver(library: FakeLibrary(), directory: directory).ensureStorage())
    }
}

// MARK: - 見る側のエンジン

final class ViewerEngineRecordingTests: XCTestCase {
    private var directory: URL!
    private var engine: ViewerEngine!
    private var nextFrameID: UInt32 = 0

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ViewerEngineRecordingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // つながらない宛先で作り、start() しない。受信はテストから流し込む
        engine = ViewerEngine(endpoint: .hostPort(host: "127.0.0.1", port: 9), key: Data(count: 32), layer: AVSampleBufferDisplayLayer())
    }

    override func tearDownWithError() throws {
        engine = nil
        try? FileManager.default.removeItem(at: directory)
    }

    /// 各コマを送るときと同じ形に分けて、受信として流す
    private func feed(_ frames: [Data]) {
        for frame in frames {
            for data in MediaPacket.videoPackets(frame: frame, frameID: nextFrameID) {
                engine.receiveForTesting(MediaPacket(data)!)
            }
            nextFrameID += 1
        }
    }

    private func capturePhoto() -> Data? {
        let done = expectation(description: "capturePhoto が返った")
        var result: Data?
        engine.capturePhoto { jpeg in
            result = jpeg
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
        return result
    }

    func testPhotoComesFromBufferedFrames() throws {
        let canTakePhoto = expectation(description: "canTakePhoto が true になった")
        canTakePhoto.assertForOverFulfill = false
        engine.onChange = { snapshot in
            if snapshot.canTakePhoto { canTakePhoto.fulfill() }
        }
        feed(makeFrames(count: 5))
        wait(for: [canTakePhoto], timeout: 10)
        let jpeg = try XCTUnwrap(capturePhoto())
        XCTAssertEqual(jpeg.prefix(2), Data([0xFF, 0xD8]))
    }

    func testNoPhotoBeforeAnyFrame() {
        XCTAssertNil(capturePhoto())
    }

    func testRecordingProducesOneFileAndStopsOnce() {
        let lock = NSLock()
        var sent: [Data] = []
        engine.sentForTesting = { data in lock.withLock { sent.append(data) } }
        var files: [URL] = []
        let fileFinished = expectation(description: "onFile")
        fileFinished.assertForOverFulfill = true
        let stopped = expectation(description: "onStop")
        stopped.assertForOverFulfill = true
        engine.startRecording(directory: directory, onFile: { url in
            files.append(url)
            fileFinished.fulfill()
        }, onStop: { lowStorage in
            XCTAssertFalse(lowStorage)
            stopped.fulfill()
        })
        feed(makeFrames(count: 30))
        engine.stopRecording()
        wait(for: [fileFinished, stopped], timeout: 10, enforceOrder: true)

        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files.first?.pathExtension, "mp4")
        XCTAssertTrue(files.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        // 録画の開始と終了の瞬間に、生存通知で知らせる。開始ではキーフレームも頼む
        let packets = lock.withLock { sent }.compactMap(MediaPacket.init)
        XCTAssertEqual(packets.filter { if case .keepAlive = $0 { true } else { false } },
                       [.keepAlive(isRecording: true), .keepAlive(isRecording: false)])
        XCTAssertTrue(packets.contains(.keyframeRequest))
    }

    // Review Focus 5
    func testStartingTwiceAndStoppingTwiceStillProducesOneFile() {
        let fileFinished = expectation(description: "onFile")
        fileFinished.assertForOverFulfill = true
        let stopped = expectation(description: "onStop")
        stopped.assertForOverFulfill = true
        let start = {
            self.engine.startRecording(directory: self.directory, onFile: { _ in fileFinished.fulfill() },
                                       onStop: { _ in stopped.fulfill() })
        }
        start()
        start()
        feed(makeFrames(count: 30))
        engine.stopRecording()
        engine.stopRecording()
        wait(for: [fileFinished, stopped], timeout: 10)
        // 遅れて 2 本目や 2 回目の onStop が来ないことを、少し待って確かめる
        let extra = expectation(description: "余分な呼び出しが無い")
        extra.isInverted = true
        wait(for: [extra], timeout: 1)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        XCTAssertEqual(files.count, 1)
    }

    // Review Focus 2
    func testStoppingBeforeAnyKeyframeProducesNoFile() {
        let fileFinished = expectation(description: "onFile が呼ばれない")
        fileFinished.isInverted = true
        let stopped = expectation(description: "onStop")
        stopped.assertForOverFulfill = true
        engine.startRecording(directory: directory, onFile: { _ in fileFinished.fulfill() }, onStop: { lowStorage in
            XCTAssertFalse(lowStorage)
            stopped.fulfill()
        })
        engine.stopRecording()
        wait(for: [stopped], timeout: 10)
        wait(for: [fileFinished], timeout: 1)
        XCTAssertTrue(((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).isEmpty)
    }
}

// MARK: - 見る側のセッション

/// 確保した時間の偽物。確保と返却を順に記録し、返却の重なりや確保していない返却を見つける。
@MainActor
private final class FakeBackgroundTime {
    private(set) var events: [String] = []
    private var held: [String: Int] = [:]

    var backgroundTime: BackgroundTime {
        BackgroundTime { [self] name in
            events.append("begin \(name)")
            held[name, default: 0] += 1
            var ended = false
            return { [self] in
                XCTAssertFalse(ended, "\(name) を 2 回返した")
                ended = true
                XCTAssertGreaterThan(held[name, default: 0], 0, "確保していない \(name) を返した")
                held[name, default: 0] -= 1
                events.append("end \(name)")
            }
        }
    }

    func events(named name: String) -> [String] {
        events.filter { $0.hasSuffix(" \(name)") }
    }
}

@MainActor
final class ViewerSessionRecordingTests: XCTestCase {
    private var directory: URL!
    private var nextFrameID: UInt32 = 0

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ViewerSessionRecordingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// つながらない宛先で作り、start() しない。「写真」は偽物
    private func makeSession(_ time: FakeBackgroundTime) -> ViewerSession {
        ViewerSession(
            camera: CameraFinder.FoundCamera(name: "テスト", endpoint: .hostPort(host: "127.0.0.1", port: 9)),
            key: Data(count: 32),
            saver: MediaSaver(library: FakeLibrary(), directory: directory),
            backgroundTime: time.backgroundTime)
    }

    private func feed(_ frames: [Data], to session: ViewerSession) {
        for frame in frames {
            for data in MediaPacket.videoPackets(frame: frame, frameID: nextFrameID) {
                session.receiveForTesting(MediaPacket(data)!)
            }
            nextFrameID += 1
        }
    }

    /// 条件が成り立つまで、メインの処理を進めながら待つ
    private func waitUntil(_ description: String, _ condition: () -> Bool) async throws {
        for _ in 0..<1000 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("待ちきれなかった: \(description)")
    }

    /// つないで録画を始め、キーフレームから 30 コマ流す
    private func startRecording(_ session: ViewerSession) async throws {
        let warmUp = makeFrames(count: 3), recorded = makeFrames(count: 30)
        feed(warmUp, to: session)
        try await waitUntil("つながった") { session.isLive }
        await session.toggleRecording()
        XCTAssertTrue(session.isRecording)
        feed(recorded, to: session)
    }

    func testStoppingHoldsBackgroundTimeUntilTheFileIsClosed() async throws {
        let time = FakeBackgroundTime()
        let session = makeSession(time)
        try await startRecording(session)
        XCTAssertTrue(time.events.isEmpty)

        session.stopRecording()
        session.stopRecording()  // 2 度押しでも重ねて確保しない
        XCTAssertEqual(time.events, ["begin FinishRecording"])

        try await waitUntil("録画が止まった") { !session.isRecording }
        XCTAssertEqual(time.events(named: "FinishRecording"), ["begin FinishRecording", "end FinishRecording"])
        // できたファイルの保存は、閉じ終える時間を返す前に自分の時間を確保している（すき間が無い）
        let saveBegin = try XCTUnwrap(time.events.firstIndex(of: "begin SaveVideo"))
        XCTAssertLessThan(saveBegin, try XCTUnwrap(time.events.firstIndex(of: "end FinishRecording")))
        try await waitUntil("保存の時間を返した") { time.events.contains("end SaveVideo") }
    }

    // 画面を閉じてすぐバックグラウンドに回ることがある。セッションが消えても、閉じ終えたら返す
    func testClosingTheScreenHoldsBackgroundTimeEvenAfterTheSessionIsGone() async throws {
        let time = FakeBackgroundTime()
        var session: ViewerSession? = makeSession(time)
        try await startRecording(session!)
        session!.stop()
        session = nil
        XCTAssertEqual(time.events, ["begin FinishRecording"])

        try await waitUntil("閉じ終えて時間を返した") { time.events.contains("end FinishRecording") }
        XCTAssertEqual(time.events(named: "FinishRecording"), ["begin FinishRecording", "end FinishRecording"])
        XCTAssertTrue(time.events.contains("begin SaveVideo"))
    }

    // 録画していなければ、止めても時間を確保しない
    func testStoppingWhenNotRecordingHoldsNothing() {
        let time = FakeBackgroundTime()
        let session = makeSession(time)
        session.stopRecording()
        session.stop()
        XCTAssertTrue(time.events.isEmpty)
    }
}
