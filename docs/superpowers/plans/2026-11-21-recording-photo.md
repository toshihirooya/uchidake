# 見ながら撮る写真と録画 実装計画

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 見る側の画面から、写真を 1 枚撮る・録画を始めて止めることができ、できたものが手元の端末の「写真」アプリに入る。

**Architecture:** 見る側だけで作る。届いた H.264 のコマを、最後のキーフレームから覚えておき（写真用）、録画中は圧縮し直さずに `AVAssetWriter` へ書く。保存はアプリ全体で 1 つの `MediaSaver` が受け持ち、見ている画面を閉じても続く。カメラへは、生存通知に足した 1 バイトで「録画中」を知らせる。

**Tech Stack:** Swift 5 / SwiftUI / AVFoundation（`AVAssetWriter`）/ VideoToolbox（`VTDecompressionSession`）/ Photos（追加のみ）/ Network framework / XCTest / XcodeGen

**Spec:** `docs/superpowers/specs/2026-11-21-recording-photo-design.md`（製品全体の仕様は `docs/spec.md`）

## Global Constraints

- iOS 17 以上。外部ライブラリは足さない。
- ファイルを足したら `xcodegen generate` を実行し、`Uchidake.xcodeproj` と `Uchidake/Info.plist` も一緒にコミットする。`Info.plist` は手で直さない（`project.yml` から作られる）。
- 画面の文言は日本語を元にし、英語を `Uchidake/Localizable.xcstrings`（許可の文言は `Uchidake/InfoPlist.xcstrings`）に足す。通信の層は文言を持たない（`Uchidake/Problem.swift` と同じ考え方）。
- 映像は 640×480 の H.264。1 コマのバイト列は `H264Encoder` の形式（先頭 1 バイトが 1 ならキーフレームで、SPS・PPS が続く）。音声は 16kHz・モノラル・16 ビット・リトルエンディアンの PCM。
- 通信の状態は各エンジンの `queue` の上だけで触る。画面の状態は `@MainActor`。
- 古い版と混ざっても壊れないこと: フラグの無い生存通知は「録画していない」、`recorders` の無い状態は 0。
- 空き容量のしきい値は 200MB（`200_000_000` バイト）。
- コメントとコミットは今までの流儀に合わせる（コメントは日本語、コミットメッセージは英語、末尾に `Co-Authored-By: Claude Fable 5.2 <noreply@anthropic.com>`）。
- テストの実行（以下「テストを実行」）:
  `xcodebuild -project Uchidake.xcodeproj -scheme Uchidake -destination 'platform=iOS Simulator,name=iPhone 15 Pro' test`
  （その名前のシミュレータが無ければ、`xcrun simctl list devices available` にある iPhone を使う）

## Review Focus

仕様が直接は書いていないが、使う人が踏みそうな所。それぞれ、持ち主のタスクにテストを足してある。

1. 「写真」の許可を断っている → 撮らない・録らない。案内が出る。落ちない。（Task 4）
2. 録画を始めてすぐ止めた、またはキーフレームが届く前に止まった → ファイルも「保存しました」も出ない。落ちない。（Task 3）
3. 音声が 1 つも届かない（カメラ側でマイクが断られている）→ 映像だけの動画として保存できる。（Task 3）
4. 録画中の見る側が、止めずに消えた（アプリが落ちた・電波が切れた）→ カメラの「録画中」が 6 秒以内に消える。（Task 2、Task 6 の通し確認）
5. 録画ボタンの連打、保存の途中でもう一度押す → 動画は 1 本だけ。二重に書かない。（Task 3、Task 5）

## ファイルの分け方

| ファイル | 役目 |
|---|---|
| `Uchidake/Media/MediaPacket.swift`（変更） | 生存通知のフラグ、`CameraStatus.recorders` |
| `Uchidake/Media/StillDecoder.swift`（新規） | `GopBuffer`（最後のキーフレームからのコマを覚える）と `StillDecoder`（コマの列から最後の 1 枚を復元） |
| `Uchidake/Media/StreamRecorder.swift`（新規） | `AudioTimeline`（音声の時刻付け）と `StreamRecorder`（MP4 を書く。大きさが変わったら分ける） |
| `Uchidake/Media/MediaSaver.swift`（新規） | 「写真」への追加、許可、一時ファイルの置き場所、失敗したものの再試行、空き容量 |
| `Uchidake/Camera/*`、`Uchidake/Views/CameraView.swift`（変更） | 見る側ごとの録画中フラグ、「録画中」の表示 |
| `Uchidake/Viewer/*`、`Uchidake/Views/ViewerViews.swift`（変更） | 写真・録画の操作と表示 |
| `UchidakeTests/RecordingTests.swift`（新規） | Task 2〜4 のテストと、テスト用の画像・コマを作る道具 |

---

### Task 1: 通信の形式（生存通知のフラグと `recorders`）

**Files:**
- Modify: `Uchidake/Media/MediaPacket.swift`
- Modify: `Uchidake/Viewer/ViewerEngine.swift`、`Uchidake/Camera/CameraEngine.swift`（`.keepAlive` を使っている所をコンパイルが通るように直すだけ。動作は Task 2・5 で入れる）
- Test: `UchidakeTests/MediaPacketTests.swift`

**Interfaces:**
- Produces:
  - `MediaPacket.keepAlive(isRecording: Bool)`（今の `.keepAlive` を置き換える）。符号化は `[4, フラグ]`、フラグのビット 0 が録画中。復号は、2 バイト目が無ければ `isRecording: false`、あればビット 0 だけを見る（ほかのビットは無視）。
  - `CameraStatus.recorders: Int`（録画中の見る側の数）。JSON に無ければ 0。`init(from:)` を自前で書く。メンバーごとのイニシャライザは `recorders: Int = 0` を最後の引数にして、今の呼び出しがそのまま通るようにする。

- [ ] **Step 1: 失敗するテストを書く**（`MediaPacketTests` に足す）

```swift
func testKeepAliveCarriesRecordingFlag() {
    XCTAssertEqual(MediaPacket.keepAlive(isRecording: true).encoded(), Data([4, 1]))
    XCTAssertEqual(MediaPacket.keepAlive(isRecording: false).encoded(), Data([4, 0]))
    XCTAssertEqual(MediaPacket(Data([4, 1])), .keepAlive(isRecording: true))
    XCTAssertEqual(MediaPacket(Data([4, 0xFE])), .keepAlive(isRecording: false))  // ほかのビットは無視
}

func testOldKeepAliveWithoutFlagMeansNotRecording() {
    XCTAssertEqual(MediaPacket(Data([4])), .keepAlive(isRecording: false))
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
```

既存の `testEachKindSurvivesEncodingAndDecoding` の `.keepAlive` は `.keepAlive(isRecording: true)` に直す。

- [ ] **Step 2: テストを実行して、コンパイルエラーで失敗することを確かめる**
- [ ] **Step 3: `MediaPacket.swift` を上の Interfaces のとおりに直す。** `ViewerEngine` の 2 か所は `.keepAlive(isRecording: false)`、`CameraEngine.handle` は `case .keepAlive:` のまま（値は Task 2 で使う）。
- [ ] **Step 4: テストを実行して、全部通ることを確かめる**
- [ ] **Step 5: コミット** — `Add recording flag to keep-alive and recorder count to status`

---

### Task 2: カメラ側（録画中の見る側を数えて、表示する）

**Files:**
- Modify: `Uchidake/Camera/CameraEngine.swift`、`Uchidake/Camera/CameraStation.swift`、`Uchidake/Views/CameraView.swift`、`Uchidake/Localizable.xcstrings`
- Test: `UchidakeTests/RecordingTests.swift`（新規）

**Interfaces:**
- Consumes: Task 1 の `MediaPacket.keepAlive(isRecording:)`、`CameraStatus.recorders`
- Produces:
  - `CameraEngine.Snapshot.recorderCount: Int`
  - `CameraStation.recorderCount: Int`（`private(set)`）
  - 数え方は `RecorderTally` に切り出してテストする:

```swift
/// 見る側ごとの「録画中」を数える。`CameraEngine` の `queue` の上で使う。
struct RecorderTally {
    /// 生存通知を受けたとき。数が変わったら true。
    mutating func update(viewer: ObjectIdentifier, isRecording: Bool) -> Bool
    /// 見る側が切れたとき。数が変わったら true。
    mutating func remove(viewer: ObjectIdentifier) -> Bool
    var count: Int { get }
}
```

- [ ] **Step 1: 失敗するテストを書く**

```swift
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

    // Review Focus 4: 止めずに消えた見る側は、切れた時点で数から外れる
    func testRemovingAViewerClearsItsRecording() {
        var tally = RecorderTally()
        let a = Token()
        _ = tally.update(viewer: ObjectIdentifier(a), isRecording: true)
        XCTAssertTrue(tally.remove(viewer: ObjectIdentifier(a)))
        XCTAssertEqual(tally.count, 0)
        XCTAssertFalse(tally.remove(viewer: ObjectIdentifier(a)))
    }
}
```

- [ ] **Step 2: テストを実行して失敗を確かめる**
- [ ] **Step 3: `RecorderTally` を `CameraEngine.swift` に足し、エンジンにつなぐ。**
  - `handle(_:from:)` の `.keepAlive(let isRecording)` で `update`。`remove(_:)` で `remove`。どちらも true が返ったら `snapshot.recorderCount` を更新して `publish()` し、`sendStatus()` をすぐ呼ぶ（2 秒待たせない）。
  - `sendStatus()` の `CameraStatus` に `recorders: snapshot.recorderCount` を渡す。
  - `CameraStation` は `recorderCount` を写す。`stop()` で 0 に戻す。デバッグの `NSLog` に `recorders=%d` を足し、変わったときにも出す。
- [ ] **Step 4: `CameraView` に「録画中」を出す。** `station.recorderCount > 0` のあいだ、`indicator` に赤（`Theme.recording`）で「見ている端末が録画しています」を出す。`dimmedContent`（画面を暗くした状態）にも同じ表示を出す。英語は "A viewer is recording"。
- [ ] **Step 5: `xcodegen generate` のあとテストを実行して、全部通ることを確かめる**
- [ ] **Step 6: コミット** — `Show on the camera when a viewer is recording`

---

### Task 3: 写真の復元と、動画の書き込み

**Files:**
- Create: `Uchidake/Media/StillDecoder.swift`、`Uchidake/Media/StreamRecorder.swift`
- Modify: `Uchidake/Media/VideoCodec.swift`
- Test: `UchidakeTests/RecordingTests.swift`

**Interfaces:**
- Produces:

```swift
// StillDecoder.swift
/// 最後のキーフレームから最新のコマまでを覚える。
struct GopBuffer {
    private(set) var frames: [Data]
    /// キーフレーム（先頭バイトが 1）なら、それまでを捨ててから足す。
    /// キーフレームをまだ 1 つも受けていなければ、差分のコマは足さない。
    mutating func append(_ frame: Data)
    mutating func reset()
    var isEmpty: Bool { get }
}

enum StillDecoder {
    /// コマを順に復元して、最後の 1 枚を返す。先頭がキーフレームでなければ nil。
    /// 呼んだスレッドで最後まで待つ（`VTDecompressionSessionWaitForAsynchronousFrames`）。
    static func lastImage(from frames: [Data]) -> CGImage?
    /// 品質 0.9 の JPEG。
    static func jpegData(from image: CGImage) -> Data?
}

// VideoCodec.swift に足す
extension VideoFrames {
    /// 録画用。表示用と同じだが、`time` を表示時刻として付け、「すぐ表示」の印は付けない。
    static func timedSampleBuffer(from frame: Data, format: inout CMFormatDescription?, at time: CMTime) -> CMSampleBuffer?
}

// StreamRecorder.swift
/// 音声のコマに時刻を付ける。届いた順に連続で並べ、届いた時刻から 0.2 秒以上ずれたら合わせ直す。
struct AudioTimeline {
    static let sampleRate: Int32 = 16_000
    static let resyncThreshold = CMTime(value: 1, timescale: 5)
    mutating func timestamp(sampleCount: Int, arrival: CMTime) -> CMTime
}

/// 届いたコマをそのまま MP4 に書く。1 つの直列キューの上だけで使う（スレッド安全ではない）。
final class StreamRecorder {
    /// `directory` に `recording-<UUID>.partial.mp4` を作りながら書き、
    /// 閉じ終えたら `.partial` を取って `recording-<UUID>.mp4` にする。
    init(directory: URL)
    /// 書き終えたファイルができるたびに呼ばれる（大きさが変わって分かれたとき、`finish` のとき）。
    var onFileFinished: ((URL) -> Void)?
    /// 書き込みに失敗した（以後は何も書かない）。
    var onFailure: (() -> Void)?
    /// 最初のキーフレームが来るまでのコマは捨てる。
    /// SPS・PPS が前と変わったら、今のファイルを閉じて、このコマから新しいファイルを始める。
    func appendVideo(_ frame: Data, at time: CMTime)
    /// 映像を書き始める前の音声は捨てる。
    func appendAudio(_ pcm: Data, at time: CMTime)
    /// 閉じる。閉じ終えたファイル（0 個以上）の `onFileFinished` をすべて呼んでから `completion` を呼ぶ。
    /// 2 回目以降の呼び出しは、何もせず `completion` だけ呼ぶ。
    func finish(completion: @escaping () -> Void)
    /// 映像を 1 コマでも書いたか。
    private(set) var hasContent: Bool
}
```

  決めたこと: 映像の入力は `outputSettings: nil`（素通し）で `sourceFormatHint` に形式を渡す。音声の入力は AAC・16kHz・モノラル・32kbps（`AVAssetWriter.canApply` が断ったらビットレートの指定を外す）。両方 `expectsMediaDataInRealTime = true`。`startSession(atSourceTime:)` は最初のキーフレームの時刻。1 コマも書かずに閉じたときは、途中のファイルを消して `onFileFinished` を呼ばない。

- [ ] **Step 1: テスト用の道具を書く**（`RecordingTests.swift`）
  - `func makeFrames(count: Int, width: Int = 640, height: Int = 480, lastColor: (r: UInt8, g: UInt8, b: UInt8)? = nil) -> [Data]`: 単色の `CVPixelBuffer`（BGRA）を `H264Encoder` に 1/30 秒刻みで通し、`onFrame` の出力を順に集めて返す（`VTCompressionSessionCompleteFrames` 相当の待ちは `XCTestExpectation` で）。最後のコマだけ `lastColor` にできる。
  - `func hostTime(_ seconds: Double) -> CMTime`
- [ ] **Step 2: 失敗するテストを書く**

```swift
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
    // setUp で空の一時フォルダ `directory` を作り、tearDown で消す。
    // `record(_:)` は、渡した操作を直列キューの上で実行し、finish の完了まで待って、できた URL の配列を返す道具。

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
        // record の中で finish を 2 回呼んでも、onFileFinished は 1 回、completion は 2 回とも呼ばれる
    }
}
```

  最後のテストは、コメントのとおりの検証を `XCTestExpectation`（`expectedFulfillmentCount`）で書く。

- [ ] **Step 3: テストを実行して、コンパイルエラーで失敗することを確かめる**
- [ ] **Step 4: `StillDecoder.swift` と `VideoFrames.timedSampleBuffer` を実装する。** `timedSampleBuffer` は、今の `compressedSampleBuffer` と中身を共有する（複製しない）。
- [ ] **Step 5: `StreamRecorder.swift` を実装する。**
- [ ] **Step 6: `xcodegen generate` のあとテストを実行して、全部通ることを確かめる**
- [ ] **Step 7: コミット** — `Add still decoding and passthrough movie recording`

---

### Task 4: 「写真」への保存（`MediaSaver`）

**Files:**
- Create: `Uchidake/Media/MediaSaver.swift`
- Modify: `project.yml`、`Uchidake/InfoPlist.xcstrings`、`Uchidake/UchidakeApp.swift`
- Test: `UchidakeTests/RecordingTests.swift`

**Interfaces:**
- Consumes: Task 3 のファイル名の決まり（書いている途中は `*.partial.mp4`、閉じたら `*.mp4`）
- Produces:

```swift
/// 「写真」アプリとのやり取り。テストでは偽物に差し替える。
protocol PhotoLibrary {
    /// 「追加のみ」の許可。未回答なら求める。
    func requestAddPermission() async -> Bool
    /// いま許可されているか（求めない）。
    var hasAddPermission: Bool { get }
    func addPhoto(_ jpeg: Data) async throws
    func addVideo(at url: URL) async throws
}
struct SystemPhotoLibrary: PhotoLibrary   // PHPhotoLibrary（.addOnly）を使う本物

/// 写真と動画を「写真」に入れる。見ている画面より長く生きる（アプリ全体で 1 つ）。
@MainActor @Observable
final class MediaSaver {
    enum Notice: Equatable { case photoSaved, videoSaved, photoFailed, videoFailed, permissionDenied, lowStorage }
    static let minimumFreeBytes: Int64 = 200_000_000

    init(library: PhotoLibrary = SystemPhotoLibrary(), directory: URL = MediaSaver.defaultDirectory)
    /// Application Support の中の `Recordings`。無ければ作る。バックアップの対象から外す。
    static var defaultDirectory: URL { get }
    let directory: URL

    /// いま出す知らせ。出してから 3 秒で nil に戻る。
    private(set) var notice: Notice?
    /// 保存の途中の動画の数（画面が「保存中」を出すため）。
    private(set) var pendingVideos: Int

    /// 許可を確かめる。断られていたら notice を `.permissionDenied` にして false。
    func ensurePermission() async -> Bool
    /// 空き容量が足りるか。足りなければ notice を `.lowStorage` にして false。
    func ensureStorage() -> Bool
    /// `directory` のあるボリュームの空き（`volumeAvailableCapacityForImportantUsage`）。
    nonisolated static func freeBytes(at directory: URL) -> Int64?

    func savePhoto(_ jpeg: Data) async
    /// 成功したらファイルを消す。失敗したら残す（次の起動で `recoverLeftovers` が拾う）。
    func saveVideo(at url: URL) async
    /// 起動時に 1 回呼ぶ。`*.partial.mp4` を消し、残っている `*.mp4` をもう一度追加する。
    /// 許可が無いときは何もしない（ファイルは残す。許可は求めない）。
    func recoverLeftovers() async
    /// エンジン側で起きたこと（容量が減って止めた、写真を復元できなかった）を知らせとして出す。
    func report(_ notice: Notice)
}
```

  `AppModel` に `let saver = MediaSaver()` を持たせ、`UchidakeApp` の `.onAppear` で `Task { await model.saver.recoverLeftovers() }` を呼ぶ。
  許可の文言（`project.yml` の `NSPhotoLibraryAddUsageDescription`）: 「撮った写真と録画した動画を「写真」に保存するために使用します。」／英語 "Used to save the photos and videos you take to Photos."

- [ ] **Step 1: 失敗するテストを書く**（偽物 `FakeLibrary: PhotoLibrary` は、許可の有無・失敗させるか・受け取ったものの記録を持つ）

```swift
@MainActor
final class MediaSaverTests: XCTestCase {
    // setUp で空の一時フォルダ `directory` を作る。`file(_ name:)` はそこに 1 バイトのファイルを作って URL を返す。

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

    // Review Focus 1
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
}
```

- [ ] **Step 2: テストを実行して失敗を確かめる**
- [ ] **Step 3: `MediaSaver.swift` を実装し、`project.yml`・`InfoPlist.xcstrings`・`UchidakeApp.swift` を直す**
- [ ] **Step 4: `xcodegen generate` のあとテストを実行して、全部通ることを確かめる。** `Uchidake/Info.plist` に `NSPhotoLibraryAddUsageDescription` が入ったことも確かめる。
- [ ] **Step 5: コミット** — `Add MediaSaver for saving photos and movies to Photos`

---

### Task 5: 見る側のエンジンとセッション

**Files:**
- Modify: `Uchidake/Viewer/ViewerEngine.swift`、`Uchidake/Viewer/ViewerSession.swift`、`Uchidake/Views/ViewerViews.swift`（`ViewerSession` を作る所だけ）
- Test: `UchidakeTests/RecordingTests.swift`

**Interfaces:**
- Consumes: Task 1（`.keepAlive(isRecording:)`）、Task 3（`GopBuffer`、`StillDecoder`、`StreamRecorder`）、Task 4（`MediaSaver`）
- Produces:

```swift
// ViewerEngine
extension ViewerEngine.Snapshot {
    var isRecording: Bool        // 既定 false
    var canTakePhoto: Bool       // 覚えているコマがあるか。既定 false
}
/// 覚えているコマから 1 枚を JPEG にする。`queue` の外（復元用のキュー）で復元し、結果を `completion` に渡す。
func capturePhoto(completion: @escaping (Data?) -> Void)
/// 録画を始める。カメラにキーフレームを頼む。すでに録画中なら何もしない。
/// `onFile` は書き終えたファイルごとに、`onStop` は録画が止まったときに 1 回（自分で止めた・失敗した・容量が減った、のどれでも）呼ばれる。
func startRecording(directory: URL, onFile: @escaping (URL) -> Void, onStop: @escaping (_ lowStorage: Bool) -> Void)
/// 録画を止める。録画中でなければ何もしない。
func stopRecording()

// ViewerSession
init(camera: CameraFinder.FoundCamera, key: Data, saver: MediaSaver)
private(set) var isRecording: Bool
private(set) var recordingStartedAt: Date?
private(set) var canTakePhoto: Bool
/// 写真を撮った瞬間に増える（画面を光らせるきっかけ）。
private(set) var photoFlashes: Int
func takePhoto() async
func toggleRecording() async
/// 録画中なら止める。画面を閉じるとき、バックグラウンドに回るときに呼ぶ。
func stopRecording()
```

  エンジンで決めたこと:
  - コマは `show(_:)` で表示に回せたものだけを `GopBuffer` に足し、録画中なら同じコマを `StreamRecorder.appendVideo` に渡す。時刻は `CMClockGetTime(CMClockGetHostTimeClock())`。音声は `handle` の `.audio` で `appendAudio` に渡す（スピーカーを消していても渡す。自分が話す声は渡さない）。
  - `setVideoPaused(false)` と `dropConnection()` では `GopBuffer` を空にする（表示とそろえる）。録画は続ける。
  - `tick()` と接続直後の生存通知は `.keepAlive(isRecording: 現在の値)`。録画の開始・終了の瞬間にも 1 回すぐ送る。
  - `tick()` で、録画中なら `MediaSaver.freeBytes(at:)` を見て、`minimumFreeBytes` を下回ったら止める（`onStop(true)`）。
  - `stop()` は、録画中なら先に止めてから接続を切る。`StreamRecorder.finish` の完了は接続が無くても届くこと。
  - `StreamRecorder.onFailure` でも止める（`onStop(false)`）。

  セッションで決めたこと:
  - `takePhoto()`: `isLive` かつ `canTakePhoto` でなければ何もしない → `saver.ensurePermission()` → `capturePhoto` → `photoFlashes += 1` → `saver.savePhoto`。JPEG が nil なら `saver.report(.photoFailed)`。
  - `toggleRecording()`: 録画中なら `stopRecording()`。そうでなければ、`isLive` でなければ何もしない → `ensurePermission()` → `ensureStorage()` → `engine.startRecording`。許可を待っているあいだの 2 度押しは、`isStartingRecording` の印で防ぐ。
  - `onFile` を受けたら、`UIApplication.shared.beginBackgroundTask` で時間を確保して `Task { await saver.saveVideo(at:) }`（`saver` を強く持つので、セッションが消えても続く）。
  - `onStop` を受けたら `isRecording = false`、`recordingStartedAt = nil`。`lowStorage` なら `saver.report(.lowStorage)`。
  - `stop()`（画面を閉じる）は、先に `stopRecording()` を呼ぶ。

- [ ] **Step 1: 失敗するテストを書く。** エンジンは通信が要るので、ここでは通信無しで確かめられる所をテストする。`ViewerEngine` に、テストから受信を流し込む入口 `func receiveForTesting(_ packet: MediaPacket)`（`#if DEBUG`、`queue` の上で `handle` を呼ぶ）と、送ったパケットを覗く `var sentForTesting: ((Data) -> Void)?`（`#if DEBUG`）を足す。

```swift
final class ViewerEngineRecordingTests: XCTestCase {
    // `engine` は、つながらない宛先（.hostPort(host: "127.0.0.1", port: 9)）で作り、start() しない。
    // `feed(_ frames: [Data])` は、各コマを MediaPacket.videoPackets で分けて receiveForTesting に流す。

    func testPhotoComesFromBufferedFrames() {
        // makeFrames(count: 5) を流す → Snapshot.canTakePhoto が true → capturePhoto が JPEG（先頭 FF D8）を返す
    }

    func testNoPhotoBeforeAnyFrame() {
        // 何も流さずに capturePhoto → nil
    }

    func testRecordingProducesOneFileAndStopsOnce() {
        // startRecording → 30 コマ流す → stopRecording
        // onFile が 1 回（.mp4 が存在する）、onStop(false) が 1 回
    }

    // Review Focus 5
    func testStartingTwiceAndStoppingTwiceStillProducesOneFile() {
        // startRecording を 2 回 → 30 コマ → stopRecording を 2 回 → onFile 1 回、onStop 1 回
    }

    // Review Focus 2
    func testStoppingBeforeAnyKeyframeProducesNoFile() {
        // startRecording → すぐ stopRecording → onFile 0 回、onStop(false) 1 回
    }
}
```

  各コメントのとおりに、`XCTestExpectation` で書く（`isInverted` で「呼ばれない」を確かめる）。

- [ ] **Step 2: テストを実行して失敗を確かめる**
- [ ] **Step 3: `ViewerEngine` を実装する**
- [ ] **Step 4: `ViewerSession` を実装し、`ViewerListView.open` で `saver: model.saver` を渡す**
- [ ] **Step 5: テストを実行して、全部通ることを確かめる**
- [ ] **Step 6: コミット** — `Capture photos and record movies in the viewer engine`

---

### Task 6: 画面、検証用の起動オプション、仕様書、通しの確認

**Files:**
- Modify: `Uchidake/Views/ViewerViews.swift`、`Uchidake/UchidakeApp.swift`、`Uchidake/Localizable.xcstrings`、`docs/spec.md`、`README.md`

**Interfaces:**
- Consumes: Task 5 の `ViewerSession`、Task 4 の `MediaSaver.notice` / `pendingVideos`、`CameraStatus.recorders`
- Produces: `AppModel.autoPhoto: Bool`、`AppModel.autoRecordSeconds: Double?`（どちらも `#if DEBUG` の起動オプションから）

- [ ] **Step 1: `LiveView` に操作と表示を足す。**
  - 操作の列の上に、写真（`camera.fill`）と録画（録画中は `stop.fill` で赤、そうでなければ `record.circle`）のボタンを並べる。大きさは今の `roundIcon` と同じ。
  - 押せる条件: 写真は `session.isLive && session.canTakePhoto`。録画の開始は `session.isLive`。録画の停止はいつでも（今の `controls` 全体に掛かっている `.disabled(!session.isLive)` の外に置く）。
  - 録画中は、ヘッダーの右に赤い丸と経過時間（`m:ss`、`TimelineView(.periodic(from:by: 1))` で `recordingStartedAt` から計算）。
  - `session.photoFlashes` が変わったら、画面全体を白く 0.15 秒光らせる。
  - `model.saver.notice` を、操作の列の上に短く出す（下の文言）。`pendingVideos > 0` のあいだは「動画を保存しています…」。
  - ヘッダーの視聴台数の横に、`status.recorders` から自分の分（`session.isRecording ? 1 : 0`）を引いた数が 1 以上なら「ほかの端末が録画中」。
  - `scenePhase` が `.background` になったら `session.stopRecording()`。閉じるボタンは今のまま（`session.stop()` が録画も止める）。
  - アクセシビリティのラベル: 「写真を撮る」「録画を始める」「録画を止める」。
- [ ] **Step 2: `ViewerListView` にも `model.saver.notice` と「動画を保存しています…」を出す**（画面を閉じたあとの結果が見えるように）。
- [ ] **Step 3: 文言を `Localizable.xcstrings` に足す**

| 日本語 | 英語 |
|---|---|
| 写真を保存しました | Photo saved |
| 動画を保存しました | Video saved |
| 動画を保存しています… | Saving video… |
| 保存できませんでした。次にアプリを開いたとき、もう一度試します。 | Couldn't save. We'll try again the next time you open the app. |
| 「写真」への追加が許可されていません。設定アプリで許可してください。 | Adding to Photos isn't allowed. Allow it in the Settings app. |
| 空き容量が少ないので、録画できません。 | Not enough free space to record. |
| ほかの端末が録画中 | Another device is recording |
| 写真を撮る / 録画を始める / 録画を止める | Take photo / Start recording / Stop recording |

  「保存できませんでした。次に…」は `videoFailed` 用。`photoFailed` は「写真を保存できませんでした。」（"Couldn't save the photo."）。

- [ ] **Step 4: 起動オプションを足す**（`AppModel.applyDebugLaunchOptions`）。`-autoPhoto YES`: 最初に開いたカメラで、`canTakePhoto` になったら 1 枚撮る。`-autoRecord <秒>`: `isLive` になったら録画を始め、その秒数で止める。`LiveView` の `.task` で実行する。デバッグの `NSLog` に次の行を足す:
  - `[Uchidake] viewer recording=1` / `recording=0`（`ViewerSession`、変わったとき）
  - `[Uchidake] saved photo` / `saved video` / `save failed`（`MediaSaver`）
- [ ] **Step 5: `docs/spec.md` と `README.md` を直す。** 設計書の「そのほか」にある章ごとの直し（1・5・6・7・9・10 章）をそのまま入れる。10 章には「録画中にアプリが落ちると、そのときの録画は失われる」「録画は届いた映像のまま（640×480。コマが落ちた所は止まって見える）」「カメラの端末の向きが変わると、動画が分かれる」を足す。README の「構成」の表に `Media/` の新しい役目を、起動の例に下の `privacy` の行を足す。
- [ ] **Step 6: テストを実行して、全部通ることを確かめる**
- [ ] **Step 7: シミュレータ 2 台で通しの確認をする。** 2 台を起動してアプリを入れ、見る側に許可を与える:

```bash
xcrun simctl privacy <見る役の UDID> grant photos-add com.example.Uchidake
```

  鍵は 32 バイトの base64url（例: `AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA`）。カメラ役を `-autoKey <鍵> -autoRole camera -autoName リビング`、見る役を `-autoKey <鍵> -autoRole viewer -autoPhoto YES -autoRecord 5` で `--console` 付きで起動する。期待する行:
  - 見る役: `saved photo`、`recording=1`、約 5 秒後に `recording=0`、`saved video`
  - カメラ役: `recorders=1` のあと `recorders=0`
  - 見る役の「写真」に、テスト画像の写真 1 枚と約 5 秒の動画 1 本がある（`xcrun simctl io <UDID> screenshot` で「写真」アプリを撮って確かめる）
  - Review Focus 4: もう一度 `-autoRecord 60` で起動し、`recorders=1` が出たら見る役を `xcrun simctl terminate` で止める → カメラ役に 6 秒以内に `recorders=0` が出る
  - 画面の見た目（ボタン、録画中の表示、カメラ側の「録画中」）を両方のスクリーンショットで確かめる

  実機でしか確かめられないこと（本物のカメラ映像と音での録画、端末の向きを変えたときに動画が分かれること、バックグラウンドに回したときの保存）は、確かめていないこととして報告する。
- [ ] **Step 8: コミット** — `Add photo and record controls to the viewer`
