# KonomiTV for iOS / iPadOS

KonomiTV サーバーに接続して、テレビ放送のライブ視聴と録画ビデオの再生ができるネイティブクライアントです。
SwiftUI と AVKit だけで構成し、WebView やサードパーティ製 UI ライブラリは使っていません。

## 主な機能

- **テレビ**: 放送種別（地デジ / BS / CS / CATV / SKY / BS4K）ごとのチャンネル一覧、現在・次の番組表示、ライブ再生。
  ピン留めチャンネル、実況勢いでの並び替え、番組のキーワード検索
- **番組表**: 放送種別・日付ごとのグリッド（チャンネル列と時間軸を固定表示）、ジャンル別の色分け、現在時刻のライン、番組詳細
- **ビデオ**: 新着・視聴履歴・マイリストのホーム、並び順の切り替え付きグリッド、無限スクロール（30 件ずつ）、検索、詳細画面での HLS 再生。
  マイリストの追加・削除、視聴履歴（続きから再生）、シリーズのほかのエピソード、録画ファイル情報の表示、録画ファイルのダウンロード、
  管理者向けの再解析・サムネイル再生成・録画ファイル削除
- **設定**: サーバー URL の変更・切断、再生品質の選択、任意のログイン（トークンは Keychain に保存）、
  設定のデバイス間同期、ピン留めチャンネルの並び替え、番組表の表示設定、視聴履歴の保持件数、サーバー情報の表示
- **アダプティブレイアウト**: コンパクト幅ではタブバー（テレビ / ビデオ / マイページ）とマイページの一覧、
  レギュラー幅（iPad・Split View・Stage Manager）ではサイドバー。ウィンドウサイズの変更に追従
- 再生中の keep-alive、ピクチャ・イン・ピクチャ、AirPlay、バックグラウンド音声

## ライブ再生のしくみ

KonomiTV のライブ配信 API は MPEG-TS をそのまま流し続けるため、AVPlayer では直接再生できません。
アプリ内で MPEG-TS をキーフレーム単位の約 1 秒のセグメントに区切り（`KonomiStreaming`）、
`127.0.0.1` で待ち受ける小さな HTTP サーバー（Network.framework）からライブ HLS として AVPlayer に渡します。

## ピクチャ・イン・ピクチャとバックグラウンド再生

- **ピクチャ・イン・ピクチャ (PiP)**: 録画ビデオ・ライブのどちらも、再生中にホーム画面へ移ると iOS が自動で PiP を開始します。
  プレイヤーの PiP ボタンからも開始できます。PiP 中はアプリ内でほかの画面へ移っても再生が止まらず、
  PiP の「元の画面に戻る」ボタンで再生中のビデオ／チャンネルの画面へ戻ります。
- **バックグラウンド再生**: ホーム画面に戻っても再生を継続します（`UIBackgroundModes: audio` と
  `audiovisualBackgroundPlaybackPolicy = .continuesIfPossible`）。PiP を使わない音声だけの継続も同じ経路です。
- **再生中情報**: ロック画面・コントロールセンターには、ビデオ名（ライブは放送中の番組名、番組情報がなければチャンネル名）と
  チャンネル名を表示します。

再生はアプリ全体で 1 つの `PlaybackController` が所有する `AVPlayerViewController` が行います。
PiP を使っていないときに再生画面を離れると、再生を止めます。

UI テストでは `-UITestingDisableAutoPiP` を渡すと PiP の自動開始を無効にし、バックグラウンド再生だけを検証できます。
iPhone のシミュレーターは PiP に対応していないため、PiP のテストは iPad のシミュレーターでだけ実行されます。

## 動作環境

- iOS / iPadOS 17.0 以上
- Xcode 26.6（Swift 6）
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)

## セットアップ

`KonomiTV.xcodeproj` は生成物のためリポジトリに含めていません。初回と `project.yml` の変更後に生成してください。

```sh
brew install xcodegen
xcodegen generate
open KonomiTV.xcodeproj
```

Xcode でスキーム `KonomiTV` を選択して実行します。初回起動時はサーバー URL（例: `http://192.168.0.10:7000`）を入力して接続します。

## リポジトリ構成

| パス | 内容 |
| --- | --- |
| `App/KonomiTV/` | iOS アプリ本体（SwiftUI） |
| `App/KonomiTVUITests/` | XCUITest による E2E テスト |
| `Packages/KonomiKit` | API クライアント・モデルと MPEG-TS → HLS セグメンタ（SwiftPM） |
| `MockServer/` | 開発・テスト用のモックサーバー（Python 標準ライブラリのみ） |
| `project.yml` | XcodeGen のプロジェクト定義 |

## ローカルでのテスト

### KonomiKit（SwiftPM）

```sh
swift test --package-path Packages/KonomiKit
```

Linux でも実行できます。

### モックサーバー

```sh
python3 MockServer/mock_server.py --port 7010
```

別のターミナルで単体テストを実行します。

```sh
cd MockServer
python3 -m unittest -v
```

### UI テスト（XCUITest）

モックサーバーを起動したまま、UI テストを実行します。テストランナーには
`TEST_RUNNER_KONOMITV_SERVER_URL`（既定は `http://127.0.0.1:7010`）が渡され、
アプリはその URL を保存済みサーバーとして起動します。

```sh
python3 MockServer/mock_server.py --port 7010 &

TEST_RUNNER_KONOMITV_SERVER_URL=http://127.0.0.1:7010 \
xcodebuild test \
  -project KonomiTV.xcodeproj \
  -scheme KonomiTV \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' \
  -resultBundlePath TestResults.xcresult \
  CODE_SIGNING_ALLOWED=NO
```

iPad では `-destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5),OS=26.5'` を使います。
レギュラー幅ではサイドバー、コンパクト幅ではタブバーになることをレイアウトテストで確認し、
回転テストは iPad では自動的にスキップされます。

## CI / CD

### CI（`.github/workflows/ci.yml`）

`main` / `feat/ios-client` への push、pull request、手動実行（workflow_dispatch）で起動します。
Markdown などドキュメントだけの変更では起動しません。

- `package-linux`: Swift 6.2 コンテナ上で KonomiKit の `swift test`
- `mock-server`: モックサーバーの `unittest`
- `ios`: 上記 2 つが成功したあとに動く唯一の macOS ジョブ。macOS 26 + Xcode 26.6 でプロジェクトを 1 回だけ生成・ビルドし、
  "iPhone 17" で UI テストを実行したあと "iPad Pro 13-inch (M5)" でも実行します（iPhone のテストが失敗しても iPad は実行）。
  ドラフトの pull request ではスキップします。xcresult とモックサーバーのログは 7 日間 artifact として保存します
- 署名なしの `.ipa`（artifact `KonomiTV-unsigned-ipa`）は push と手動実行のときだけビルド・保存し、pull request では作りません。
  署名なしのため、インストールには Xcode、AltStore、Sideloadly などで自分の証明書による再署名が必要

### リリース（`.github/workflows/release.yml`）

`v*` タグの push、または手動実行（workflow_dispatch）で起動します。

次の Secrets がすべて設定されている場合は、署名済みの App Store 用 IPA をビルドして
App Store Connect へアップロードし、タグの GitHub Release に IPA を添付します（artifact としても保存）。

| Secret | 内容 |
| --- | --- |
| `APPLE_TEAM_ID` | Apple Developer Team ID |
| `BUILD_CERTIFICATE_BASE64` | Distribution 証明書（.p12）の Base64 |
| `P12_PASSWORD` | .p12 のパスワード |
| `PROVISIONING_PROFILE_BASE64` | App Store 用プロビジョニングプロファイルの Base64 |
| `ASC_KEY_ID` | App Store Connect API キー ID |
| `ASC_ISSUER_ID` | App Store Connect API の Issuer ID |
| `ASC_PRIVATE_KEY` | API キー（.p8）の中身、またはその Base64 |

Secrets が不足している場合は署名を行わず、`scripts/build-unsigned-ipa.sh` で作った署名なしの
`.ipa` をタグでは GitHub Release に添付し、artifact `KonomiTV-<version>-unsigned-ipa` としても
保存します（タグ以外の手動実行では artifact のみ）。署名なしのため、インストールには
Xcode、AltStore、Sideloadly などで自分の証明書による再署名が必要です。
Apple の資格情報がないフォークでもリリース処理を確認できる構成です。

## 補足

- バージョンは `v1.2.3` のようなタグから `MARKETING_VERSION` に設定され、
  `CURRENT_PROJECT_VERSION` は GitHub Actions の実行番号になります。
- `KonomiTV.xcodeproj`、`DerivedData`、`.build`、`*.xcresult`、`__pycache__` などは
  `.gitignore` で除外しています。
