# 家族プラン（アプリ内課金） 実装計画

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 無料はカメラ 1 台・見る側 1 台、家族プラン（月額・年額・買い切り）で見る側 4 台・カメラ複数台、という線引きを、サーバー無しで動かす。

**Architecture:** 家族プランの判定は StoreKit 2 の結果を端末に覚え、純粋な関数（`PlanJudge`）で有効かどうかを決める。見る側の上限はカメラの `CameraEngine` が接続を受けるときに決め、断る理由を新しいパケットで返す。カメラの台数は、Bonjour の TXT レコードに載せた「組の目印」を起動時に 2 秒探して決める（`CameraCensus`）。判断の部分はどれも通信や StoreKit から切り離して、単体テストで押さえる。

**Tech Stack:** Swift 5 / SwiftUI / StoreKit 2 / Network framework（`NWListener`・`NWBrowser`・`NWTXTRecord`）/ CryptoKit（HMAC）/ XCTest / XcodeGen

**Spec:** `docs/superpowers/specs/2026-11-22-family-plan-design.md`（製品全体の仕様は `docs/spec.md`）

## Global Constraints

- iOS 17 以上。外部ライブラリは足さない。
- ファイルを足したら `xcodegen generate` を実行し、`Uchidake.xcodeproj` と `Uchidake/Info.plist` も一緒にコミットする。`Info.plist` は手で直さない。
- 画面の文言は日本語を元にし、英語を `Uchidake/Localizable.xcstrings` に足す。通信の層は文言を持たない（`Uchidake/Problem.swift` と同じ考え方）。金額は文言に書かず、StoreKit の `displayPrice` を出す。
- 商品 ID: `com.toshihirooya.uchidake.family.monthly` / `.family.yearly` / `.family.lifetime`。
- 見る側の上限: 家族プラン無し 1 台、有り 4 台。
- 月額・年額の猶予: 覚えている期限から 30 日。
- カメラの起動時の確認: 2 秒。上限のときに最初の生存通知を待つ時間: 2 秒。
- 判断できないときは止めずに動かす。見ている最中の相手は、プランが変わっても切らない。
- 古い版と混ざっても壊れないこと: ID の無い生存通知は「ID 無し」、TXT レコードの無いカメラは数えない、知らない種類のパケットは読み飛ばす（いまの `MediaPacket.init?` は nil を返す）。
- 通信の状態は各エンジンの `queue` の上だけで触る。画面の状態は `@MainActor`。
- コメントは日本語、コミットメッセージは英語、末尾に `Co-Authored-By: Claude Fable 5.2 <noreply@anthropic.com>`。コミットはこのブランチ（`feature/family-plan`）の手元だけ。プッシュはしない。
- テストの実行（以下「テストを実行」）:
  `xcodebuild -project Uchidake.xcodeproj -scheme Uchidake -destination 'platform=iOS Simulator,name=iPhone 15 Pro' test`

## Review Focus

仕様が直接は書いていないが、使う人が踏みそうな所。それぞれ、持ち主のタスクにテストを足してある。

1. 無料のカメラを見ている端末が、Wi-Fi の一瞬の切れでつなぎ直す → 自分の古い枠に断られず、入れ替わって見続けられる。（Task 2）
2. カメラが、探索で自分自身の広告を見つける → 自分を「ほかのカメラ」と数えない。1 台しか無いのに止まらない。（Task 3）
3. ほかのアプリや古い版の広告（TXT レコードが無い・欠けている・数字でない）→ 数えずに始める。落ちない。（Task 3）
4. 置きっぱなしの iPhone の時計がずれている（期限より前の日付、ずっと先の日付）→ 落ちない。前なら有効、先なら猶予の計算どおり。（Task 1）
5. 家族プランで 4 台が見ている最中に、プランが切れる → 誰も切られない。新しくつなぐ 5 台目だけが断られ、1 台に減るまで新しい相手は入れない。（Task 2）

## ファイルの分け方

| ファイル | 役目 |
|---|---|
| `Uchidake/Store/PlanRecord.swift`（新） | 商品の種類、覚えておく記録、有効かどうかの判断（StoreKit を知らない） |
| `Uchidake/Store/FamilyPlanStore.swift`（新） | StoreKit 2 とのやり取り。記録の保存。画面に見せる状態 |
| `Uchidake/FamilyPlan.storekit`（新） | シミュレータ用の商品定義 |
| `Uchidake/Camera/ViewerAdmission.swift`（新） | 見る側を入れるか・入れ替えるか・断るかの判断 |
| `Uchidake/Camera/CameraCensus.swift`（新） | 組の目印、TXT レコード、カメラを始めてよいかの判断、2 秒の探索 |
| `Uchidake/Views/FamilyPlanView.swift`（新） | 購入画面と、カメラを始められないときの画面 |
| `Uchidake/Media/MediaPacket.swift` | 生存通知の ID、種類 7 |
| `Uchidake/Camera/CameraEngine.swift` / `CameraStation.swift` | 上限、入れ替え、断り、TXT レコード、起動時の確認 |
| `Uchidake/Viewer/ViewerEngine.swift` / `ViewerSession.swift` / `Views/ViewerViews.swift` | ID を送る、断られた理由を出す |
| `Uchidake/UchidakeApp.swift` / `Views/HomeView.swift` / `Views/CameraView.swift` | `FamilyPlanStore` を持つ、入口、`-autoPlan` |

---

### Task 1: 家族プランの判定と StoreKit

**Files:**
- Create: `Uchidake/Store/PlanRecord.swift`, `Uchidake/Store/FamilyPlanStore.swift`, `Uchidake/FamilyPlan.storekit`
- Modify: `Uchidake/UchidakeApp.swift`, `project.yml`
- Test: `UchidakeTests/FamilyPlanTests.swift`

**Interfaces:**
- Produces:

```swift
enum PlanProduct: String, Codable, CaseIterable {
    case monthly = "com.toshihirooya.uchidake.family.monthly"
    case yearly = "com.toshihirooya.uchidake.family.yearly"
    case lifetime = "com.toshihirooya.uchidake.family.lifetime"
}
struct PlanRecord: Codable, Equatable {
    var product: PlanProduct
    var expires: Date?   // 買い切りは nil
}
enum PlanJudge {
    static let grace: TimeInterval = 30 * 24 * 60 * 60
    /// 記録が、その時刻に家族プランとして有効か
    static func isActive(_ record: PlanRecord?, now: Date) -> Bool
    /// StoreKit がいま返した権利（current）と、覚えていた記録から、次に覚える記録を決める
    static func next(remembered: PlanRecord?, current: [PlanRecord], now: Date) -> PlanRecord?
}

@MainActor @Observable final class FamilyPlanStore {
    private(set) var record: PlanRecord?
    var isActive: Bool { get }                 // debugOverride があればそれ、無ければ PlanJudge
    var debugOverride: Bool?                   // DEBUG のみ。-autoPlan
    enum Catalog: Equatable { case loading, ready, unavailable }
    private(set) var catalog: Catalog
    private(set) var products: [Product]       // monthly, yearly, lifetime の順
    private(set) var monthlyTrialAvailable: Bool
    enum PurchaseOutcome { case purchased, cancelled, pending, failed }
    func start()                               // 記録を読み、権利を読み直し、Transaction.updates を追う
    func refresh() async
    func loadProducts() async
    func purchase(_ product: Product) async -> PurchaseOutcome
    func restore() async -> Bool               // AppStore.sync() のあと refresh。有効になれば true
}
```

- `AppModel` に `let plan = FamilyPlanStore()` を足し、`UchidakeApp` の `onAppear` で `model.plan.start()` を、`resumeLastRole()` より前に呼ぶ。

`PlanJudge.next` の決まり:
- `current` が空でない → 買い切りがあれば買い切り。無ければ期限がいちばん先のもの。
- `current` が空で、覚えているのが買い切り → nil（返金・サインアウト）。
- `current` が空で、覚えているのが月額・年額 → `now` が期限より前なら nil（取り消し。期限内なら StoreKit は端末の控えを返すはず）。期限以後なら、覚えている記録を残す（更新を知れないだけかもしれない）。猶予を過ぎたら nil。

`PlanJudge.isActive`: 買い切りは true。月額・年額は `now < expires + grace`。

- [ ] **Step 1: 失敗するテストを書く**（`FamilyPlanTests`）

```swift
let day: TimeInterval = 86_400
let t0 = Date(timeIntervalSince1970: 1_800_000_000)
func sub(_ p: PlanProduct = .monthly, expiresIn d: Double) -> PlanRecord { .init(product: p, expires: t0 + d * day) }
let lifetime = PlanRecord(product: .lifetime, expires: nil)

func testNoRecordIsFree() { XCTAssertFalse(PlanJudge.isActive(nil, now: t0)) }
func testLifetimeIsAlwaysActive() { XCTAssertTrue(PlanJudge.isActive(lifetime, now: t0 + 9999 * day)) }
func testSubscriptionIsActiveUntilThirtyDaysAfterExpiry() {
    XCTAssertTrue(PlanJudge.isActive(sub(expiresIn: 1), now: t0))
    XCTAssertTrue(PlanJudge.isActive(sub(expiresIn: -29.9), now: t0))
    XCTAssertFalse(PlanJudge.isActive(sub(expiresIn: -30.1), now: t0))
}
func testClockFarInThePastStillCountsAsActive() {      // Review Focus 4
    XCTAssertTrue(PlanJudge.isActive(sub(expiresIn: 1), now: t0 - 4000 * day))
}
func testStoreKitResultWins() {
    XCTAssertEqual(PlanJudge.next(remembered: nil, current: [sub(expiresIn: 5), sub(.yearly, expiresIn: 300)], now: t0), sub(.yearly, expiresIn: 300))
    XCTAssertEqual(PlanJudge.next(remembered: sub(expiresIn: 5), current: [sub(expiresIn: 5), lifetime], now: t0), lifetime)
}
func testEmptyResultBeforeExpiryMeansRevoked() {
    XCTAssertNil(PlanJudge.next(remembered: sub(expiresIn: 5), current: [], now: t0))
    XCTAssertNil(PlanJudge.next(remembered: lifetime, current: [], now: t0))
}
func testEmptyResultAfterExpiryKeepsRecordDuringGrace() {
    XCTAssertEqual(PlanJudge.next(remembered: sub(expiresIn: -10), current: [], now: t0), sub(expiresIn: -10))
    XCTAssertNil(PlanJudge.next(remembered: sub(expiresIn: -31), current: [], now: t0))
}
func testRecordSurvivesJSON() {   // PlanRecord を JSONEncoder → JSONDecoder で往復して等しい（買い切りと月額）
}
```

- [ ] **Step 2: テストを実行して、コンパイルできずに失敗することを確かめる**
- [ ] **Step 3: `PlanRecord.swift` を書く**（上の決まりどおり）
- [ ] **Step 4: テストを実行して通ることを確かめる**
- [ ] **Step 5: `FamilyPlanStore.swift` を書く**
  - 記録は `UserDefaults` の `familyPlanRecord` に JSON で保存する。
  - `refresh()`: `Transaction.currentEntitlements` を回し、`.verified` で `revocationDate == nil`、`productID` が `PlanProduct` のものだけを `PlanRecord(product:, expires: transaction.expirationDate)` にして、`PlanJudge.next` に渡す。結果を保存する。
  - `start()`: 保存してある記録を読む → `refresh()` → `Transaction.updates` を回すタスクを持ち、届いたら `finish()` して `refresh()`。
  - `loadProducts()`: `Product.products(for:)`。3 つそろわなければ `.unavailable`。`monthlyTrialAvailable` は月額の `subscription?.isEligibleForIntroOffer`。
  - `purchase`: `.success(.verified)` → `finish()`・`refresh()`・`.purchased`。`.userCancelled` → `.cancelled`。`.pending` → `.pending`。それ以外と例外 → `.failed`。
- [ ] **Step 6: `Uchidake/FamilyPlan.storekit` を作る。** 3 商品（月額 300 円・1 か月・初回 1 週間無料／年額 1,500 円・1 年／買い切り 3,000 円・非消耗型）、月額と年額は同じグループ「家族プラン」、3 つともファミリー共有を有効、既定のストアフロントは日本。`project.yml` の `schemes.Uchidake.run` に `storeKitConfiguration: Uchidake/FamilyPlan.storekit` を足す。`.storekit` はアプリの中に入れない（`project.yml` の `sources` で `buildPhase: none`）。
- [ ] **Step 7: `AppModel` に `plan` を足し、起動時に `start()` を呼ぶ。** `applyDebugLaunchOptions()` に `-autoPlan family` / `-autoPlan free` を足す（`plan.debugOverride` に true / false）。
- [ ] **Step 8: `xcodegen generate` のあとテストを実行して、全部通ることを確かめる**
- [ ] **Step 9: コミット** `Add family plan entitlement with StoreKit 2`

---

### Task 2: 見る側の上限、断りの理由、同じ端末の入れ替え

**Files:**
- Create: `Uchidake/Camera/ViewerAdmission.swift`
- Modify: `Uchidake/Media/MediaPacket.swift`, `Uchidake/Camera/CameraEngine.swift`, `Uchidake/Camera/CameraStation.swift`, `Uchidake/Viewer/ViewerEngine.swift`, `Uchidake/Viewer/ViewerSession.swift`, `Uchidake/Views/ViewerViews.swift`, `Uchidake/UchidakeApp.swift`
- Test: `UchidakeTests/MediaPacketTests.swift`, `UchidakeTests/ViewerAdmissionTests.swift`

**Interfaces:**
- Consumes: `FamilyPlanStore.isActive`（Task 1）
- Produces:

```swift
enum RefusalReason: UInt8 { case freeLimit = 1, familyLimit = 2 }

// MediaPacket
case keepAlive(isRecording: Bool, viewerID: UInt64?)   // [4, フラグ] + ID 8 バイト（あるとき）
case refusal(RefusalReason)                             // [7, 理由]

enum ViewerAdmission {
    static func limit(hasFamilyPlan: Bool) -> Int       // 1 / 4
    enum Decision: Equatable { case admit, replace(index: Int), refuse(RefusalReason) }
    /// admitted: いま入っている見る側の ID（分からなければ nil）を、入った順に
    static func decide(newID: UInt64?, admitted: [UInt64?], hasFamilyPlan: Bool) -> Decision
}

// CameraEngine
init(name: String, key: Data, previewLayer: AVSampleBufferDisplayLayer, hasFamilyPlan: Bool)
func setFamilyPlan(_ active: Bool)

// ViewerEngine.Snapshot
var refusal: RefusalReason?      // 断られているあいだ。映像か状態が届いたら nil
// ViewerSession
private(set) var refusal: RefusalReason?
```

`ViewerAdmission.decide` の決まり: `newID` が nil でなく `admitted` の中にあれば `.replace(その位置)`（上限に関係なく）。無ければ、`admitted.count < limit` なら `.admit`、そうでなければ `.refuse`（家族プラン無しは `.freeLimit`、有りは `.familyLimit`）。

`CameraEngine` の動き:
- `Viewer` に `id: UInt64?` と `isAdmitted` を足す。映像・音・状態を送る相手と `viewerCount` は、`isAdmitted` の相手だけ。
- 接続が `.ready` になったとき、入っている数が上限より少なければすぐ入れる（いまと同じ速さ）。上限に達していれば「保留」にして、最初の生存通知を 2 秒待つ。
- 生存通知を受けたら `viewer.id` を覚える。保留の相手なら `decide` を呼ぶ: `.replace` → 古い接続を切って入れ替え、キーフレームと状態を送る。`.admit` → 入れる。`.refuse` → `MediaPacket.refusal` を 3 回送ってから切る。2 秒たっても生存通知が来ない保留も、同じように断る。
- いまの `guard viewers.count < Self.maxViewers` は、保留も含めた接続の総数の上限（`ViewerAdmission.limit(hasFamilyPlan: true) + 4`）に置き換える。`maxViewers` は消す。
- `setFamilyPlan` は上限を変えるだけ。入っている相手は切らない。

`ViewerEngine` の動き:
- `viewerID` はプロセスごとに 1 つ（`static let viewerID = UInt64.random(in: 1...UInt64.max)`）。生存通知に必ず付ける。
- `.refusal` を受けたら `snapshot.refusal` に入れ、接続を落として、いまと同じ間隔でつなぎ直す。`failedAttempts` は増やさない。

- [ ] **Step 1: 失敗するテストを書く**

`MediaPacketTests` に足す・直す（既存の `.keepAlive(isRecording:)` は `viewerID: nil` を足して直す）:

```swift
func testKeepAliveCarriesViewerID() {
    let packet = MediaPacket.keepAlive(isRecording: true, viewerID: 0x0102_0304_0506_0708)
    XCTAssertEqual(packet.encoded(), Data([4, 1, 1, 2, 3, 4, 5, 6, 7, 8]))
    XCTAssertEqual(MediaPacket(packet.encoded()), packet)
}
func testKeepAliveWithoutIDIsReadAsNoID() {
    XCTAssertEqual(MediaPacket(Data([4, 1])), .keepAlive(isRecording: true, viewerID: nil))
    XCTAssertEqual(MediaPacket(Data([4, 0, 9, 9])), .keepAlive(isRecording: false, viewerID: nil))   // 半端な長さ
}
func testRefusalRoundTrips() {
    XCTAssertEqual(MediaPacket.refusal(.freeLimit).encoded(), Data([7, 1]))
    XCTAssertEqual(MediaPacket(Data([7, 2])), .refusal(.familyLimit))
    XCTAssertNil(MediaPacket(Data([7])))
    XCTAssertNil(MediaPacket(Data([7, 99])))
}
```

`ViewerAdmissionTests`:

```swift
func testLimits() { XCTAssertEqual(ViewerAdmission.limit(hasFamilyPlan: false), 1); XCTAssertEqual(ViewerAdmission.limit(hasFamilyPlan: true), 4) }
func testFreeCameraAdmitsFirstAndRefusesSecond() {
    XCTAssertEqual(ViewerAdmission.decide(newID: 1, admitted: [], hasFamilyPlan: false), .admit)
    XCTAssertEqual(ViewerAdmission.decide(newID: 2, admitted: [1], hasFamilyPlan: false), .refuse(.freeLimit))
}
func testSameViewerReplacesItsOldSlot() {               // Review Focus 1
    XCTAssertEqual(ViewerAdmission.decide(newID: 1, admitted: [1], hasFamilyPlan: false), .replace(index: 0))
    XCTAssertEqual(ViewerAdmission.decide(newID: 3, admitted: [1, 2, 3, 4], hasFamilyPlan: true), .replace(index: 2))
}
func testOldViewerWithoutIDIsNeverTreatedAsTheSame() {
    XCTAssertEqual(ViewerAdmission.decide(newID: nil, admitted: [nil], hasFamilyPlan: false), .refuse(.freeLimit))
}
func testFamilyCameraRefusesFifth() {
    XCTAssertEqual(ViewerAdmission.decide(newID: 5, admitted: [1, 2, 3, 4], hasFamilyPlan: true), .refuse(.familyLimit))
}
func testAfterPlanEndsNobodyNewGetsInUntilOneIsLeft() {  // Review Focus 5
    XCTAssertEqual(ViewerAdmission.decide(newID: 5, admitted: [1, 2, 3, 4], hasFamilyPlan: false), .refuse(.freeLimit))
    XCTAssertEqual(ViewerAdmission.decide(newID: 5, admitted: [1], hasFamilyPlan: false), .refuse(.freeLimit))
    XCTAssertEqual(ViewerAdmission.decide(newID: 2, admitted: [1, 2, 3, 4], hasFamilyPlan: false), .replace(index: 1))
    XCTAssertEqual(ViewerAdmission.decide(newID: 5, admitted: [], hasFamilyPlan: false), .admit)
}
```

`RecordingTests` にある `ViewerEngine.receiveForTesting` の使い方にならって、1 本足す:

```swift
func testRefusalIsShownAndClearedByNextStatus() {
    // engine.receiveForTesting(.refusal(.freeLimit)) のあと snapshot.refusal == .freeLimit、failedAttempts は増えない。
    // 続けて .status(...) を受けると refusal == nil。
}
```

- [ ] **Step 2: テストを実行して失敗を確かめる**
- [ ] **Step 3: `MediaPacket` と `ViewerAdmission.swift` を書く**
- [ ] **Step 4: `CameraEngine` を上の動きに直す。** `CameraStation.init(name:key:plan:)` で `FamilyPlanStore` を受け取り、エンジンに `plan.isActive` を渡す。`plan.isActive` の変化を `withObservationTracking` で追い、`engine.setFamilyPlan` を呼ぶ。`AppModel.startCamera` は `plan` を渡す。
- [ ] **Step 5: `ViewerEngine` / `ViewerSession` を直す**
- [ ] **Step 6: `ViewerViews.swift` の「つながりません。…」を出している所（`session.failedAttempts > 0`）の前に、断られたときの文言を出す。**
  - `.freeLimit`: 「このカメラは、いま別の端末が見ています。カメラの端末を家族プランにすると、同時に 4 台まで見られます。」
  - `.familyLimit`: 「このカメラは、いま 4 台が見ています。」
  - 英語を `Localizable.xcstrings` に足す。
- [ ] **Step 7: `xcodegen generate` のあとテストを実行して、全部通ることを確かめる**
- [ ] **Step 8: コミット** `Limit viewers per camera by family plan and tell refused viewers why`

---

### Task 3: カメラの台数の確認

**Files:**
- Create: `Uchidake/Camera/CameraCensus.swift`
- Modify: `Uchidake/Camera/CameraEngine.swift`, `Uchidake/Camera/CameraStation.swift`, `Uchidake/Views/CameraView.swift`
- Test: `UchidakeTests/CameraCensusTests.swift`

**Interfaces:**
- Consumes: `FamilyPlanStore.isActive`（Task 1）、`CameraStation.init(name:key:plan:)`（Task 2）
- Produces:

```swift
struct CameraAdvert: Equatable {
    var familyTag: String    // f
    var hasPlan: Bool        // p: "1" / "0"
    var isRunning: Bool      // r: "1" / "0"
    var since: Int           // s: UNIX 秒
    var deviceID: String     // i
    init(familyTag: String, hasPlan: Bool, isRunning: Bool, since: Int, deviceID: String)
    init?(txt: [String: String])          // 欠けていたり読めなければ nil
    var txt: [String: String] { get }
    /// HMAC-SHA256(鍵, "Uchidake-v2-family-tag") の先頭 8 バイトを小文字の 16 進で（16 文字）
    static func familyTag(key: Data) -> String
}

enum CameraCensus {
    enum Decision: Equatable { case start, blocked(by: String) }
    /// others: 探索で見つかった (広告名, 広告)。自分自身や、読めなかった広告が混ざっていてもよい
    static func decide(me: CameraAdvert, others: [(name: String, advert: CameraAdvert?)]) -> Decision
    /// 2 秒探して、見つかったものを返す（メインスレッドで呼ぶ）。探せなければ空。
    static func survey(seconds: TimeInterval = 2) async -> [(name: String, advert: CameraAdvert?)]
}

// CameraEngine
func startListening(advert: CameraAdvert)   // 広告だけ始める。撮影はまだ
func startCapture()                         // いまの start() の撮影の部分
func setAdvert(_ advert: CameraAdvert)      // TXT レコードを差し替える

// CameraStation
enum Phase: Equatable { case checking, running, blocked(by: String) }
private(set) var phase: Phase
```

`CameraCensus.decide` の決まり（`me.hasPlan` が true なら常に `.start`）:
1. `others` から、広告が nil のもの、`deviceID` が自分と同じもの、`familyTag` が違うもの、`hasPlan` が true のものを外す。
2. 残りに `isRunning` が true のものがあれば、`.blocked(by: その名前)`（複数あれば名前の順で最初）。
3. 残り（同時に始めようとしている）のうち、`(since, deviceID)` が自分より小さいものがあれば `.blocked(by: その名前)`。
4. どれでもなければ `.start`。

`CameraStation.start()` の流れ:
- `since` は `UserDefaults` の `cameraSince`（無ければいまの時刻を入れて保存）、`deviceID` は `cameraDeviceID`（無ければ UUID を作って保存）。
- 家族プランあり → `isRunning: true` の広告で `startListening`、すぐ `startCapture`、`phase = .running`。
- 家族プラン無し → `phase = .checking`、`isRunning: false` で `startListening` → `survey()` → `decide`。`.start` なら `setAdvert(isRunning: true)`・`startCapture`・`.running`。`.blocked` ならエンジンを止めて `phase = .blocked(by:)`。
- `.blocked` のあいだに `plan.isActive` が true になったら、`start()` をやり直す。`.running` のあいだにプランが変わったら、`setAdvert` で `p` を差し替える（Task 2 の `setFamilyPlan` と同じ所で）。
- `CameraEngine` の待ち受けのやり直し（`.failed` のあとの `startListener()`）でも、最新の広告を載せる。

`survey` は `NWBrowser(for: .bonjourWithTXTRecord(type: MediaSecurity.serviceType, domain: nil), using:)`（`includePeerToPeer = true`）で、`metadata` の `.bonjour(txtRecord)` から辞書を作る。ブラウザが `.failed` になったら、それまでの結果を返す。

- [ ] **Step 1: 失敗するテストを書く**（`CameraCensusTests`）

```swift
let key = Data(repeating: 7, count: 32)
func ad(_ id: String, plan: Bool = false, running: Bool = true, since: Int = 100, tag: String? = nil) -> CameraAdvert {
    .init(familyTag: tag ?? CameraAdvert.familyTag(key: key), hasPlan: plan, isRunning: running, since: since, deviceID: id)
}
let me = ad("me", running: false, since: 200)   // テストごとに作る

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
func testBrokenTXTIsNotAnAdvert() {                    // Review Focus 3
    XCTAssertNil(CameraAdvert(txt: [:]))
    XCTAssertNil(CameraAdvert(txt: ["f": "x", "p": "0", "r": "1", "s": "abc", "i": "a"]))
    XCTAssertNil(CameraAdvert(txt: ["f": "x", "p": "0", "r": "1", "s": "1"]))
}
func testAloneStarts() { XCTAssertEqual(CameraCensus.decide(me: me, others: []), .start) }
func testOwnAdvertIsNotAnotherCamera() {               // Review Focus 2
    XCTAssertEqual(CameraCensus.decide(me: me, others: [("カメラ", ad("me", running: true))]), .start)
}
func testRunningFreeCameraOfSameFamilyBlocks() {
    XCTAssertEqual(CameraCensus.decide(me: me, others: [("リビング", ad("a"))]), .blocked(by: "リビング"))
}
func testCameraWithPlanDoesNotBlock() {
    XCTAssertEqual(CameraCensus.decide(me: me, others: [("リビング", ad("a", plan: true))]), .start)
}
func testOtherFamilyAndUnreadableAdvertsDoNotBlock() { // Review Focus 3
    XCTAssertEqual(CameraCensus.decide(me: me, others: [("隣", ad("a", tag: "0000000000000000")), ("古い版", nil)]), .start)
}
func testIHaveThePlanSoIAlwaysStart() {
    var planned = me; planned.hasPlan = true
    XCTAssertEqual(CameraCensus.decide(me: planned, others: [("リビング", ad("a"))]), .start)
}
func testWhenBothAreStartingTheOlderOneWins() {
    XCTAssertEqual(CameraCensus.decide(me: me, others: [("寝室", ad("a", running: false, since: 100))]), .blocked(by: "寝室"))
    XCTAssertEqual(CameraCensus.decide(me: me, others: [("寝室", ad("a", running: false, since: 300))]), .start)
}
func testSameAgeIsSettledByDeviceID() {
    XCTAssertEqual(CameraCensus.decide(me: me, others: [("寝室", ad("aa", running: false, since: 200))]), .blocked(by: "寝室"))
    XCTAssertEqual(CameraCensus.decide(me: me, others: [("寝室", ad("zz", running: false, since: 200))]), .start)
}
```

- [ ] **Step 2: テストを実行して失敗を確かめる**
- [ ] **Step 3: `CameraCensus.swift` の `CameraAdvert` と `decide` を書く**
- [ ] **Step 4: テストを実行して通ることを確かめる**
- [ ] **Step 5: `survey` を書き、`CameraEngine` を `startListening` / `startCapture` / `setAdvert` に分ける。** 広告は `NWListener.Service(name:type:domain:txtRecord:)` に `NWTXTRecord(advert.txt)` を渡す。差し替えは `listener.service` の入れ直し。既存の `start()` は消し、呼び出し側を直す。
- [ ] **Step 6: `CameraStation` を上の流れに直す**
- [ ] **Step 7: `CameraView` を直す。** `station.phase` が `.checking` のあいだは「ほかのカメラを確かめています…」と進行中の表示。`.blocked(by:)` のときは、映像の代わりに `CameraBlockedView(otherName:)`（Task 4 で作る。この時点では文言と「戻る」だけの仮の表示でよい）を出す。画面を暗くする処理は `.running` のときだけ動かす。
- [ ] **Step 8: `xcodegen generate` のあとテストを実行して、全部通ることを確かめる**
- [ ] **Step 9: コミット** `Check for other cameras in the family before starting a free camera`

---

### Task 4: 購入画面と入口

**Files:**
- Create: `Uchidake/Views/FamilyPlanView.swift`
- Modify: `Uchidake/Views/HomeView.swift`, `Uchidake/Views/CameraView.swift`, `Uchidake/Localizable.xcstrings`
- Test: `UchidakeTests/FamilyPlanTests.swift`

**Interfaces:**
- Consumes: `FamilyPlanStore`（Task 1）、`CameraStation.Phase`（Task 3）
- Produces:

```swift
struct FamilyPlanView: View            // シートで出す。@Environment(AppModel.self) から plan を使う
struct CameraBlockedView: View { let otherName: String }   // 「家族プランを見る」「戻る」
enum LegalLinks {
    static let terms = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
    static let privacy = URL(string: "https://example.com/uchidake/privacy")!   // 仮。人間が URL を決めたら差し替える
}
/// 購入画面に並べる商品。買い切りの人には何も出さず、月額・年額の人には買い切りだけ出す。
static func FamilyPlanView.offered(for record: PlanRecord?, isActive: Bool) -> [PlanProduct]
```

`offered` の決まり: 有効でない → 3 つとも（月額・年額・買い切りの順）。月額・年額で有効 → 買い切りだけ。買い切り → 空。

画面に出すもの（文言は設計書の「購入画面」の節のとおり。細かい配置は任せる。見た目は `Theme` と `HomeView` のカードに合わせる）:
- 何が変わるか（見る側が同時 4 台まで、カメラが複数台）。
- `offered` の商品。名前、`displayPrice`、期間。月額には `monthlyTrialAvailable` のときだけ「最初の 7 日間は無料」。
- 買い切りの範囲の説明、カメラの端末で有効にする説明、「購入を復元」。復元しても有効にならなければ「購入が見つかりませんでした。」。
- 自動更新の説明、利用規約とプライバシーポリシーのリンク。
- 有効なとき: 「家族プランが有効です」と商品名。月額・年額なら「サブスクリプションを管理」（`manageSubscriptionsSheet`）。月額・年額の人が買い切りを買ったあとは「買い切りを購入しました。月額・年額は自動では止まらないので、「サブスクリプションを管理」から解約してください。」。
- `catalog == .unavailable`: 「商品を読み込めませんでした。通信を確かめて、もう一度試してください。」と「もう一度試す」。
- 購入の結果: `.pending` は「承認を待っています。承認されると、自動で有効になります。」、`.failed` は「購入できませんでした。もう一度試してください。」、`.cancelled` は何も出さない。

- [ ] **Step 1: 失敗するテストを書く**（`FamilyPlanTests` に足す）

```swift
func testOfferedProducts() {
    XCTAssertEqual(FamilyPlanView.offered(for: nil, isActive: false), [.monthly, .yearly, .lifetime])
    XCTAssertEqual(FamilyPlanView.offered(for: sub(expiresIn: -40), isActive: false), [.monthly, .yearly, .lifetime])
    XCTAssertEqual(FamilyPlanView.offered(for: sub(expiresIn: 5), isActive: true), [.lifetime])
    XCTAssertEqual(FamilyPlanView.offered(for: lifetime, isActive: true), [])
}
```

- [ ] **Step 2: テストを実行して失敗を確かめる**
- [ ] **Step 3: `FamilyPlanView.swift` を書く。** 開いたときに `plan.loadProducts()`。
- [ ] **Step 4: `HomeView` に「家族プラン」のカードを足す**（`cameraCard` の下。有効なら「家族プランが有効です」、無ければ「見る側を 4 台まで、カメラを複数台に」）。押すと `FamilyPlanView` をシートで出す。
- [ ] **Step 5: `CameraBlockedView` を仕上げ、`CameraView` につなぐ。** 文言は「この家では、すでに「\(otherName)」がカメラとして動いています。カメラを 2 台以上使うには、家族プランが必要です。」。カメラの画面の操作の列にも、家族プランが無いときだけ購入画面を開くボタンを足す。
- [ ] **Step 6: 足した文言すべてに、英語を `Localizable.xcstrings` に足す。** 訳し残しが無いことを、`xcstrings` に `"state" : "new"` や英語の無い項目が残っていないことで確かめる。
- [ ] **Step 7: `xcodegen generate` のあとテストを実行して、全部通ることを確かめる**
- [ ] **Step 8: コミット** `Add the family plan purchase screen`

---

### Task 5: 仕様書と、シミュレータでの通し確認

**Files:**
- Modify: `docs/spec.md`, `README.md`

**Interfaces:**
- Consumes: Task 1〜4 のすべて

- [ ] **Step 1: `docs/spec.md` を更新する。** 1 章（無料と家族プランの範囲、買い切りの範囲）、2 章（見る側は無料 1 台・家族プラン 4 台、カメラは家族プラン無しなら組に 1 台）、3 章（TXT レコードの 5 つの項目、起動時の 2 秒の確認と決まり、判断できないときは始める）、4 章「守れないこと」（組の目印と家族プランの有無が同じ Wi-Fi の人に見える。同じ組のカメラがどれかが分かる）、5 章（種類 4 の ID、種類 7、上限のときの 2 秒の保留、古い版との混在）、6・7 章（確認中・始められないとき・断られたときの画面、購入画面）、9 章（`-autoPlan`、足したログ）、10 章（家族プランはカメラの端末ごと。インターネットに出られない端末は期限から 30 日まで）。`README.md` に StoreKit の設定ファイルでの試し方を 2〜3 行で足す。
- [ ] **Step 2: テストを実行して、全部通ることを確かめる**
- [ ] **Step 3: シミュレータ 3 台で通し確認する。** どれも同じ `-autoKey` で起動し、ログ（`[Uchidake]`）と画面で確かめる。結果を、確かめたこと・確かめられなかったことに分けて報告する。
  1. カメラ A（`-autoPlan free`）に見る側 1 がつながる。見る側 2 は断られ、理由 1 の文言が出る。A の `viewers` は 1 のまま。
  2. 見る側 1 を閉じると、見る側 2 が数秒で映像を出す。
  3. カメラ A を `-autoPlan family` で起動し直すと、見る側 1・2 の両方がつながる。
  4. カメラ A（free）が動いているとき、カメラ B（free）を始めると、B は「すでに…」の画面になり、Bonjour の一覧に B が出ない。
  5. カメラ B を `-autoPlan family` にすると、A・B の両方が動く。
  6. カメラ A だけのとき、A を何度起動し直しても始められる（自分の広告で止まらない）。
  7. 購入画面: StoreKit の設定ファイルで 3 商品と価格が出る。月額を買うと「家族プランが有効です」になり、買い切りだけが残る。Xcode の「Manage Transactions」で消すと無料に戻る。（`xcodebuild` から起動したシミュレータでは StoreKit の設定ファイルが効かないことがある。効かなければ、その旨を報告し、Xcode から実行して確かめる手順を書く）
- [ ] **Step 4: コミット** `Document the family plan in the spec`

## この計画に含めないもの（人間の作業）

App Store Connect での商品登録と契約、Small Business Program、プライバシーポリシーのページと URL、掲載文、実機でのサンドボックス購入とファミリー共有の確認、リリースの承認。
