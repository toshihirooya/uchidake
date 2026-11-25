# App Store に出す手順

うちだけカメラを App Store に出すまでの手順と、App Store Connect の画面で答える内容。リポジトリで管理しているもの（説明文・URL・審査用メモ・スクリーンショット）は fastlane で上げ、画面でしか決められないものはここに書く。

## リポジトリで管理しているもの

| もの | 場所 | 上げ方 |
|---|---|---|
| プライバシーポリシー・サポートページ（日英） | `site/` | `firebase deploy --only hosting`（プロジェクト `uchidake-camera`、`.firebaserc`） |
| 説明文・サブタイトル・キーワード・宣伝文・URL（ja / en-US） | `fastlane/metadata/` | `bundle exec fastlane metadata` |
| 審査用メモと連絡先 | `fastlane/metadata/review_information/` | 同上 |
| スクリーンショット | `fastlane/screenshots/` | `bundle exec fastlane screenshots` で撮り、`metadata` で上げる |
| ビルド | — | `bundle exec fastlane beta`（TestFlight へ。build 番号は最新 + 1） |
| プライバシーマニフェスト | `Uchidake/PrivacyInfo.xcprivacy` | アプリに入る |

公開ページ:

- サポート: https://uchidake-camera.web.app/ （英語 https://uchidake-camera.web.app/en/ ）
- プライバシーポリシー: https://uchidake-camera.web.app/privacy （英語 https://uchidake-camera.web.app/en/privacy ）

## 最初の 1 回だけ

1. **App Store Connect にアプリを作る**: `bundle exec fastlane create_app`（Apple ID でのログインが要る）か、画面の「新規 App」。名前「うちだけカメラ」、主言語「日本語」、バンドル ID `com.toshihirooya.uchidake`、SKU `uchidake`。
2. **契約・税金・口座**: 有料 App 契約が有効か確かめる（課金があるため必須）。
3. **アプリ内課金を作る**（商品 ID は `Uchidake/FamilyPlan.storekit` と同じにする）:
   - 自動更新サブスクリプション グループ「家族プラン」
     - `com.toshihirooya.uchidake.family.monthly` 月額 300 円、導入オファー 7 日間無料
     - `com.toshihirooya.uchidake.family.yearly` 年額 1,500 円
   - 非消耗型 `com.toshihirooya.uchidake.family.lifetime` 3,000 円
   - 3 つともファミリー共有をオン。表示名・説明（日英）と、審査用のスクリーンショット（購入画面）を付ける。配信地域はアプリと同じ（下の「価格と配信」）。
   - 最初の版の審査に、この 3 つを一緒に出す（版のページの「App 内課金とサブスクリプション」で選ぶ）。
4. **RevenueCat**: プロジェクトに iOS アプリを足し、App Store Connect の In-App Purchase キー（または共有シークレット）を登録する。Entitlement `family` に 3 商品を結び、Offering `default` に月額・年額・買い切りのパッケージを入れる。**Public SDK キー（`appl_…`）を `Uchidake/Store/FamilyPlanStore.swift` の `RevenueCatConfig.publicSDKKey` に入れる**（空のままだと購入画面が「商品を読み込めませんでした」になり、審査で落ちる）。
5. **App Review の電話番号**: `fastlane/metadata/review_information/` には入れていない。画面の「App Review に関する情報」で入れる。

## App Store Connect の画面で答えるもの

### App のプライバシー（プライバシーの詳細）

映像・音声・鍵はどこにも送らない。送るのは RevenueCat SDK による購入の情報だけ（[RevenueCat の案内](https://www.revenuecat.com/docs/platform-resources/apple-platform-resources/apple-app-privacy)）。

- データを収集しますか: **はい**
- 収集するデータ: **購入 › 購入履歴** だけ
  - 目的: **アナリティクス**、**App の機能**（RevenueCat の案内で、どちらも必須とされている）
  - ユーザーに関連付けられていますか: **いいえ**（RevenueCat の匿名 ID だけで、ログインも独自 ID も無い）
  - トラッキングに使用しますか: **いいえ**
- ID（ユーザ ID・デバイス ID）、使用状況データ、診断、連絡先情報: **収集しない**

RevenueCat に独自の ID（`logIn`）や広告 ID を使う連携を足したら、ここを見直す。

### 年齢制限

すべての質問に「なし」で、**4+** になる想定。「ユーザー生成コンテンツ」「無制限の Web アクセス」は無し。カメラ映像は家の中の端末どうしでしか見られず、他人と共有する機能は無い。

### 輸出コンプライアンス

`ITSAppUsesNonExemptEncryption = NO` を Info.plist に入れてあるので、アップロードのたびの質問は出ない。暗号は iOS 標準の DTLS（Network.framework）だけで、免除の範囲。

### 価格と配信

- 価格: 無料（家族プランはアプリ内課金）
- 配信地域: 日本語と英語しか無いので、**日本と、英語が公用語の 58 の国と地域**だけにする。アプリと課金 3 商品で同じ範囲にそろえる。
  - JPN USA GBR CAN AUS NZL IRL
  - アジア: SGP HKG IND PHL MYS PAK
  - アフリカ: ZAF NGA KEN GHA UGA TZA RWA ZMB ZWE BWA NAM MWI SLE LBR GMB MUS SYC SWZ CMR
  - カリブ海など: JAM BHS BRB TTO ATG DMA GRD KNA LCA VCT BLZ GUY AIA BMU CYM MSR TCA VGB
  - 太平洋: FJI PNG SLB VUT TON NRU PLW FSM
  - EU の国（マルタなど）は入れない（DSA のトレーダー情報を登録すると、住所・電話番号が EU の App Store に公開されるため）。
  - 中国本土は入れない（ICP 届出番号が要るため）。
  - 「新しい国や地域で自動的に配信」はオフにする（アプリは「価格および配信状況」の画面で。API では変えられない）。
- iPad: 対応（`TARGETED_DEVICE_FAMILY = 1,2`）。iPad のスクリーンショットも要る。

### カテゴリ

主カテゴリ「ユーティリティ」、副カテゴリ「ライフスタイル」（`fastlane/metadata/*_category.txt`）。

## スクリーンショットについて

`scripts/capture_screenshots.sh` がシミュレータで撮る（iPhone 6.9 インチ 1320×2868、iPad 13 インチ 2064×2752、日英）。シミュレータにはカメラが無いので、カメラ役には `IMAGE=` で渡した写真を映像として送らせる（デバッグビルドの `-screenshotImage`。docs/spec.md の 9 章）。

```bash
IMAGE=build/shots/nursery-portrait.jpg DEVICES="iPhone 17 Pro Max,iPad Pro 13-inch (M5)" WAIT=12 scripts/capture_screenshots.sh
```

- 今の写真は Unsplash の [白いベビーベッドとアームチェアの子ども部屋](https://unsplash.com/photos/a-cozy-nursery-with-a-white-crib-and-armchair-QYwo037ITqk)（Unsplash License。商用利用可、表記不要）。`images.unsplash.com/photo-1774578342155-8d7e44a18bfd?fm=jpg&q=85&w=1600` を取ってきて、ベビーベッドが入るよう縦長に切り抜いた（`sips -c 1067 800 --cropOffset 0 700`）。写真は `build/`（Git に入れない）に置く。
- カメラの名前は「子ども部屋」「Nursery」。文字の大きさは標準にそろえて起動する（シミュレータの文字の設定が大きくても崩れない）。
- iPad のステータスバーには、日付とアプリ名が出る（iPadOS の表示で、上書きできない）。

## 審査で気をつけること

- **2 台要る**: 審査用メモ（`review_information/notes.txt`）に、2 台での試し方を書いてある。審査で「つながらない」と返されやすいので、2 台で動かしている短い動画を用意し、メモに URL を足すと通りやすい。
- **バックグラウンドの音声**（`UIBackgroundModes: audio`）: 見る側で、画面を閉じても音を聞き続ける（夜のベビーモニターの使い方）ためと、メモに書いてある。音を流していないのにバックグラウンドに残る作りにはしない。
- **サブスクリプションの表示**: 購入画面に、価格・期間・自動更新の説明・利用規約とプライバシーポリシーへのリンク・「購入を復元」がある。説明文の最後にも利用規約とプライバシーポリシーの URL を入れてある。
- **医療機器ではない**: 説明文に「乳幼児の安全確認を、このアプリだけに頼らないで」と入れてある。

## 出すまでの順番

1. RevenueCat の Public SDK キーを入れて、`develop` に入れる。
2. `bundle exec fastlane beta` で TestFlight に上げ、実機 2 台で、つなぐ・見る・話す・写真と録画・購入（Sandbox）・復元を確かめる。
3. `bundle exec fastlane screenshots` → `bundle exec fastlane metadata` で説明文とスクリーンショットを上げる。
4. 画面で、プライバシーの詳細・年齢制限・価格・アプリ内課金・電話番号を埋め、ビルドを選んで審査に出す。
