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

パケットの形式、映像の断片の組み立て、合言葉からの鍵の導出に単体テストがある。Xcode で ⌘U、またはコマンドラインで実行する。

```bash
xcodebuild -project Uchidake.xcodeproj -scheme Uchidake -destination 'platform=iOS Simulator,name=iPhone Air' test
```

## 構成

| 場所 | 中身 |
|---|---|
| `Uchidake/Security/` | 合言葉から作る鍵と、DTLS の設定。 |
| `Uchidake/Media/` | パケットの形式、カメラの取り込み、H.264 の圧縮、音声。 |
| `Uchidake/Camera/` | カメラ役。待ち受けて、見る側すべてに映像と音を送る。 |
| `Uchidake/Viewer/` | 見る役。カメラを探してつなぎ、映像と音を受ける。 |
| `Uchidake/Views/` | 画面。 |

## 画面を操作せずに動かす

デバッグビルドには、検証用の起動オプションがある（[仕様の9章](docs/spec.md)）。シミュレータ 2 台で、カメラ役と見る役を動かす例:

```bash
xcrun simctl launch --console <カメラ役の UDID> com.example.Uchidake -autoPassphrase test-pass-1234 -autoRole camera -autoName リビング
```

```bash
xcrun simctl launch --console <見る役の UDID> com.example.Uchidake -autoPassphrase test-pass-1234 -autoRole viewer
```

`--console` を付けると、つながったことと受信したコマ数が `[Uchidake]` で始まる行に出る。シミュレータにはカメラもマイクも無いので、テスト画像と確認音のデータが流れる。
