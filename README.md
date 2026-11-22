# うちだけカメラ

使っていない iPhone を見守りカメラにして、ペットや子どもの様子を手元の iPhone / iPad で確認する iOS アプリ。映像と音声はサーバーを通らず、Network Framework で端末同士が直接やり取りする。家の中専用で、外出先からは見られない。

カメラ役と見る役は同じアプリで、最初の画面でどちらにするかを選ぶ。

仕様は [docs/spec.md](docs/spec.md)。

## 開き方

`Uchidake.xcodeproj` を Xcode で開いて実行する。iOS 17 以上。

実機で動かすときは、Xcode の Signing & Capabilities で自分のチームを選ぶ。

## プロジェクトファイルの作り直し

ファイルを足したり設定を変えたりしたら、[XcodeGen](https://github.com/yonaskolb/XcodeGen) で作り直す。

```bash
xcodegen generate
```

設定は `project.yml` にある。`Uchidake/Info.plist` もここから生成される。

## テスト

パケットの形式、映像の断片の組み立て、鍵と QR コードの中身の変換に単体テストがある。Xcode で ⌘U、またはコマンドラインで実行する。

```bash
xcodebuild -project Uchidake.xcodeproj -scheme Uchidake -destination 'platform=iOS Simulator,name=iPhone Air' test
```

## 家族プランの購入を試す

商品は `Uchidake/FamilyPlan.storekit` に書いてある。Xcode からシミュレータで実行すると、最初の画面の「家族プラン」から購入・復元を試せる（購入の取り消しは Xcode の Debug > StoreKit > Manage Transactions）。購入を通さずに台数の制限だけを試すときは、起動オプション `-autoPlan family` / `-autoPlan free` を使う（`docs/spec.md` の9章）。

## 構成

| 場所 | 中身 |
|---|---|
| `Uchidake/Security/` | 端末どうしで共有する鍵（QR コードで渡す）と、DTLS の設定。 |
| `Uchidake/Media/` | パケットの形式、カメラの取り込み、H.264 の圧縮、音声。見る側の写真の復元と録画（MP4）、「写真」への保存。 |
| `Uchidake/Camera/` | カメラ役。待ち受けて、見る側すべてに映像と音を送る。見る側の上限と、同じ組のカメラの台数の確認。 |
| `Uchidake/Store/` | 家族プラン（アプリ内課金）。StoreKit 2 とのやり取りと、有効かどうかの判断。 |
| `Uchidake/Viewer/` | 見る役。カメラを探してつなぎ、映像と音を受ける。 |
| `Uchidake/Views/` | 画面。 |

## 画面を操作せずに動かす

デバッグビルドには、検証用の起動オプションがある（[仕様の9章](docs/spec.md)）。シミュレータ 2 台で、カメラ役と見る役を動かす例。シミュレータでは QR コードを読み取れないので、先に検証用の鍵を作って両方に渡す:

```bash
KEY=$(head -c 32 /dev/urandom | base64 | tr '+/' '-_' | tr -d '=')
```

```bash
xcrun simctl launch --console <カメラ役の UDID> com.toshihirooya.uchidake -autoKey "$KEY" -autoRole camera -autoName リビング
```

```bash
xcrun simctl privacy <見る役の UDID> grant photos-add com.toshihirooya.uchidake
xcrun simctl launch --console <見る役の UDID> com.toshihirooya.uchidake -autoKey "$KEY" -autoRole viewer
```

写真と録画も試すときは、見る役に `-autoPhoto YES -autoRecord 5` を足す（つながったら写真を 1 枚撮り、5 秒録画する）。`privacy` の行は、見る役の「写真」への追加を許可する。

`--console` を付けると、つながったことと受信したコマ数が `[Uchidake]` で始まる行に出る。シミュレータにはカメラもマイクも無いので、テスト画像と確認音のデータが流れる。

## 言語

画面の文言は日本語で書き、ほかの言語は String Catalog に訳を足す。いまは日本語と英語。

| ファイル | 中身 |
|---|---|
| `Uchidake/Localizable.xcstrings` | 画面の文言。キーはコード中の日本語そのもの。 |
| `Uchidake/InfoPlist.xcstrings` | アプリ名と、カメラ・マイク・ローカルネットワークの許可ダイアログの文言。 |

- 文言を足すときは、コードに日本語で書き、`Localizable.xcstrings` に訳を足す（Xcode で開くと、足りないキーが分かる）。
- 画面より下の層では文言を作らない。理由は `Problem` のような型で持ち、画面に出す直前に文言にする。
- 言語を増やすときは、2 つの `.xcstrings` にその言語の訳を足す。コードの変更は要らない。

英語で表示を確かめるには、起動オプションに `-AppleLanguages "(en)"` を付ける。
