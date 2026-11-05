# KonomiTV for iOS / iPadOS

KonomiTV サーバーに接続して、テレビ放送のライブ視聴と録画ビデオの再生ができるネイティブクライアントです。
SwiftUI と AVKit / VLCKit で構成し、サードパーティ製の UI ライブラリは使っていません。

唯一の例外がデータ放送 (BML) です。BML 文書は放送波のデータカルーセルから降ってくる
マークアップで、それを解釈して描画するには受信機 (ブラウザ) の実装が必要なため、
Web クライアントと同じ [web-bml](https://github.com/tsukumijima/web-bml) を WKWebView の
中だけで動かしています。その外側 (リモコン・設定・映像の配置・映像プレーンの切り抜き) は
すべてネイティブです。

## 主な機能

- **テレビ**: 放送種別（地デジ / BS / CS / CATV / SKY / BS4K）ごとのチャンネル一覧、現在・次の番組表示、ライブ再生。
  ピン留めチャンネル、実況勢いでの並び替え、番組検索（キーワードに加えて、除外キーワード・ジャンル・チャンネル・
  放送日時・番組長・無料／有料の条件シート）。
  ニコニコ実況 / NX-Jikkyo のコメントを映像上に流し、コメントパネルから一覧・投稿できる
  （色・位置・サイズ、キーワードやユーザー ID のミュート、コメントの表示切り替え）
- **番組表**: 放送種別・日付ごとのグリッド（チャンネル列と時間軸を固定表示）、ジャンル別の色分け、現在時刻のライン、番組詳細
- **ビデオ**: 新着・視聴履歴・マイリストのホーム、並び順の切り替え付きグリッド、無限スクロール（30 件ずつ）、検索、詳細画面での HLS 再生。
  シリーズ一覧・検索・詳細（放送期間ごとのエピソード）とシリーズのマイリスト、マイリストの追加・削除、視聴履歴（続きから再生）、
  録画ファイル情報の表示、録画ファイルのダウンロード、
  過去ログコメントの表示（再生位置に同期）、管理者向けの再解析・サムネイル再生成・録画ファイル削除
- **設定**: サーバー URL の変更・切断、画質プロファイル（テレビ／ビデオ × Wi-Fi／モバイル回線、データ節約・低遅延・24fps）、
  任意のログイン（トークンは Keychain に保存）、設定のデバイス間同期、ピン留めチャンネルの並び替え、
  番組表の表示設定、視聴履歴の保持件数、ニコニコアカウントの連携と解除、コメントの速さ・文字サイズ・ミュート設定、
  Twitter / Bluesky アカウントの連携・紐付けと実況の設定、バージョン情報とアップデート通知
- **アカウント・管理**: アカウント作成（最初のアカウントは管理者）、ユーザー名・パスワードの変更、アイコン画像のアップロード、
  アカウント削除。管理者はユーザー一覧と管理者権限の付与／剥奪・削除、サーバー設定（全般・サーバー・テレビ・ビデオ・キャプチャ）の
  編集と再起動の案内、サーバーログ／アクセスログのリアルタイム表示（追従）、データベース更新、録画フォルダの一括スキャン・
  バックグラウンド解析・キャプチャスキャン・データベース最適化の実行と進捗表示、サーバーの再起動・シャットダウンと再接続状態の表示
- **アダプティブレイアウト**: コンパクト幅ではタブバー（テレビ / ビデオ / マイページ）とマイページの一覧、
  レギュラー幅（iPad・Split View・Stage Manager）ではサイドバー。ウィンドウサイズの変更に追従
- **プレイヤー**: 再生中の画質切り替え（ビデオは同じ位置から再開）、ビデオの再生速度、主音声／副音声、
  ライブの低遅延モードとライブ状態表示、iPad のハードウェアキーボードショートカット、
  ライブの番組／チャンネルパネルとリモコン、ビデオのシーンサムネイル
- **録画予約**: 番組表・ライブの番組パネルから録画予約を追加（録画設定プリセットの選択、既定プリセットでのクイック予約）。
  予約一覧は録画中・放送が近い予約・チューナー不足・無効のグループに分けて表示し、詳細画面で有効／無効・優先度・
  プリセット・録画フォルダ・録画ファイル名テンプレート・録画マージン・字幕／データ放送の録画・録画後動作・実行スクリプトを
  変更できます。予約の削除（確認あり）と削除後の再追加、番組表セルの予約マーカー、キーワード自動予約条件の一覧・追加・
  変更・削除にも対応（EDCB バックエンド選択時のみ）
- **字幕**: ライブ・録画ビデオの ARIB 字幕と文字スーパー（`libaribcaption` で描画）。表示の切り替え（S）、
  フォント・縁取り・不透明度、テレビ／ビデオ別の文字スーパー表示設定
- **データ放送**: ライブ視聴中に BML (データ放送) を表示。web-bml を WKWebView の中で動かし、
  PSI/SI アーカイブデータ (EIT[p/f]・TOT など) をアプリ内でデコードして渡します。映像は
  データ放送が指定する映像プレーンに置いたまま、その上に BML を重ねます。リモコン
  (方向・決定・戻る・データ・青赤緑黄・1〜12、コンテンツが受け付けるキーだけ有効)、
  受信機情報 (郵便番号・都道府県) と双方向 (インターネット接続) の設定、EIT[p/f] による
  現在・次の番組のリアルタイム更新。ページはチャンネル切り替え・画質切り替え・PiP・
  バックグラウンドで作り直します
- **キャプチャ**: 再生中の映像を JPEG で保存（写真ライブラリ / KonomiTV サーバー / 両方）。字幕とニコニコ実況コメントの
  合成、ファイル名パターン、クリップボードへのコピー。番組情報は Web クライアントと同じ EXIF（XPComment）に書き込むため、
  サーバー側のキャプチャ一覧で放送回・お気に入り・タグと結び付く。キャプチャのタイムライン・放送回別アルバム・タグの
  一覧（閲覧・共有・お気に入り・タグ付け・削除）にも対応（サーバーが 0.15 未満の場合は非表示）
- **オフライン保存**: 録画番組を画質（1080p〜240p、通信節約モード）と容量の見積もりを見て端末へ保存し、
  保存の進捗・キャンセル・再試行、保存容量と空き容量の表示、削除（確認あり）に対応（サーバーが 0.15 未満の場合は非表示）。
  保存したビデオはサーバーに接続できないときも「オフライン」から再生でき、続きから再生・PiP・バックグラウンド再生・
  ARIB 字幕・保存時点の過去ログコメントもそのまま使えます
- **Twitter / Bluesky**: 視聴画面のパネルに「Twitter」タブを追加。Cookie（cookies.txt）で Twitter、
  ハンドル + App Password で Bluesky を連携し、紐付けたアカウントは両方へ同時投稿できます。
  視聴中のチャンネルの局タグの自動付与、保存したハッシュタグ、ハッシュタグの位置、文字数カウント、
  キャプチャ 4 枚までの添付（番組名の透かし入り）、リプライツリー実況、
  Twitter と Bluesky をまとめたタイムライン／検索、リツイート／リポスト・いいねに対応
- 再生中の keep-alive、ピクチャ・イン・ピクチャ、AirPlay、バックグラウンド音声

## ライブ再生のしくみ

KonomiTV のライブ配信 API は MPEG-TS をそのまま流し続けるため、AVPlayer も libVLC も直接は再生できません。
アプリ内で MPEG-TS をキーフレーム単位の約 1 秒のセグメントに区切り（`KonomiStreaming`）、
`127.0.0.1` で待ち受ける小さな HTTP サーバー（Network.framework）からライブ HLS として
VLCKit（libVLC）に渡します。各セグメントには `#EXT-X-PROGRAM-DATE-TIME` を付けます。

遅延はプレイリストの窓と libVLC の開始位置で決まります。窓は 6 セグメント（約 6 秒）で、
libVLC の HLS は既定で窓の後ろから 3 セグメント目（`hls-live-start` の既定値 3）から再生を始めるため、
ライブエッジの約 3 秒後ろを再生します（AVPlayer 時代の `configuredTimeOffsetFromLive = 3` と同じ）。
libVLC のネットワークキャッシュはライブ 1000 ms、録画ビデオ 3000 ms、オフライン保存 300 ms です。

libVLC は入力ごとに自分のタイムラインを 0 から数え直すため、再生位置と PTS はロードをまたいで
そのままでは比較できません。そこでループバックサーバーが実際に配信した最初のセグメント
（＝ libVLC が再生を始めたセグメント）の PROGRAM-DATE-TIME と先頭映像 PTS を固定点にして、
libVLC の再生位置 ↔ 壁時計 ↔ PTS の対応（`LivePlaybackClock`、`KonomiStreaming`）を作ります。
字幕 PES はこの対応で再生位置に変換し、録画と同じ字幕レンダラーに渡します。対応はロードのたび、
およびライブエッジへの復帰・再読み込みのたびに作り直します。

録画ビデオも同じループバックサーバー経由で再生します。サーバーの master / media プレイリストと
セグメントをアプリ内でプロキシし、映像のセグメントから字幕 PES を取り出して
`HLSMediaPlaylist.playbackTime(segmentIndex:pts:firstPTS:)` で再生位置に変換します。
サーバーへの master プレイリスト要求・keep-alive・画質切り替えはそのまま維持されます。
字幕 PES はセグメントから取り除いた複製を渡すため、libVLC 側の字幕デコーダーは動きません
（字幕は libaribcaption で描画するので、二重に出ることはありません）。

オフライン保存したビデオは、保存時に書いた VOD プレイリスト（`#EXT-X-ENDLIST`）と
`Application Support/OfflineVideos/<録画番組 ID>/` のセグメントを同じループバックサーバーから配信します。
サーバーにもネットワークにも触れず、オンライン再生と同じ経路で字幕を抽出するため、PiP・バックグラウンド再生・
字幕がそのまま動きます。保存の進捗は受信セグメント数 / 想定セグメント数（番組尺 ÷ セグメント長）で表示します。

## ピクチャ・イン・ピクチャとバックグラウンド再生

- **プレイヤー**: 映像は libVLC が `PlayerDrawableView`（`VLCDrawable`）に描画し、その上に字幕とコメントの
  オーバーレイ、さらに SwiftUI の操作パネル（タップで表示／再生中は約 3 秒で自動的に非表示、再生／一時停止、
  録画はシークバーと ±10 秒／±30 秒スキップ、ライブは「ライブ」ボタン、ミュート、AirPlay、PiP、全画面表示）が重なります。
  全画面表示ではナビゲーションバー・パネル・サイドバー・ステータスバーを隠し、iPhone は横向きに固定します
  （iPhone を横向きにしても全画面表示になります）。
- **ライブは常に最新の部分を再生**: ライブには再生時間を出さず、一時停止からの再開・PiP からの再開は
  最新の部分から再生します。バッファリングなどで放送より 5 秒以上遅れると、ループバックのプレイリストを開き直して
  最新の部分へ戻ります（自動で戻るのは 30 秒に 1 回まで）。PiP 中は libVLC の映像出力を作り直すと PiP が閉じるため、
  ウィンドウ内でシークできる場合だけ移動します。
- **アプリに戻ったときのライブの再開**: PiP の一時停止、ほかのアプリの音声による中断、PiP ウィンドウを閉じたことで
  止まったライブは、アプリに戻るとすぐ最新の部分から再生を再開します（配信が途切れていた場合は再接続します）。
  アプリ内の再生／一時停止ボタンで止めたときは止めたままにします。
- **ピクチャ・イン・ピクチャ (PiP)**: 録画ビデオ・ライブのどちらも、再生中にホーム画面へ移ると iOS が自動で PiP を開始します。
  操作パネルの PiP ボタンからも開始できます。PiP は libVLC の
  `VLCPictureInPictureWindowControlling` を `PlayerDrawableView` が受け取って駆動し、
  AVKit から呼ばれる再生位置・長さ・再生中かどうか・シーク可否はロックで保護したスナップショットから
  同期的に答えます（ライブはシーク不可）。PiP 中はアプリ内でほかの画面へ移っても再生が止まらず、
  アプリに戻すと再生中のビデオ／チャンネルの画面へ戻ります。
- **バックグラウンド再生**: ホーム画面に戻っても再生を継続します（`UIBackgroundModes: audio` と
  `.playback` のオーディオセッション）。PiP を使わない音声だけの継続も同じ経路で、
  映像を表示しないバックグラウンドでは 2 秒後に libVLC の映像トラックを外して消費電力を抑え、
  前面に戻ると再び選択します。
- **再生中情報**: ロック画面・コントロールセンターには、ビデオ名（ライブは放送中の番組名、番組情報がなければチャンネル名）と
  チャンネル名、再生位置・長さ・再生速度、チャンネルのロゴ／サムネイルを表示します。
  再生／一時停止・10 秒スキップ・シーク（録画のみ）は `MPRemoteCommandCenter` から操作できます。

再生はアプリ全体で 1 つの `PlaybackController` が所有する `VLCMediaPlayer` と、共有の
`PlayerHostViewController`（`PlayerDrawableView` + 字幕・コメントオーバーレイ）が行います。
PiP を使っていないときに再生画面を離れると、再生を止めます。

UI テストでは `-UITestingDisableAutoPiP` を渡すと PiP の自動開始を無効にし、バックグラウンド再生だけを検証できます。
iPhone のシミュレーターは PiP に対応していないため、PiP のテストは iPad のシミュレーターでだけ実行されます。

## 動作環境

- iOS / iPadOS 17.0 以上
- Xcode 26.6（Swift 6）
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)

## セットアップ

`KonomiTV.xcodeproj` は生成物のためリポジトリに含めていません。初回と `project.yml` の変更後に生成してください。
先に `scripts/fetch-vlckit.py` で VLCKit 4 を `Vendor/VLCKit.xcframework` に取得します
（動的フレームワークのため `Vendor/` は `.gitignore` 済み）。

```sh
brew install xcodegen
python3 scripts/fetch-vlckit.py   # Vendor/VLCKit.xcframework (iOS device + simulator)
xcodegen generate
open KonomiTV.xcodeproj
```

Xcode でスキーム `KonomiTV` を選択して実行します。初回起動時はサーバー URL（例: `http://192.168.0.10:7000`）を入力して接続します。

## リポジトリ構成

| パス | 内容 |
| --- | --- |
| `App/KonomiTV/` | iOS アプリ本体（SwiftUI + VLCKit） |
| `App/KonomiTVUITests/` | XCUITest による E2E テスト |
| `Packages/KonomiKit` | API クライアント・モデルと MPEG-TS → HLS セグメンタ（SwiftPM） |
| `Packages/ARIBCaption` | libaribcaption の Swift ラッパー（ARIB 字幕のデコードと描画、SwiftPM） |
| `BML/` | データ放送のページ（web-bml の TypeScript バンドル。ビルド済みの出力を `App/KonomiTV/Resources/BML` に含めています） |
| `MockServer/` | 開発・テスト用のモックサーバー（Python 標準ライブラリのみ。オフライン保存ストリームも配信） |
| `scripts/fetch-vlckit.py` | VLCKit 4（`Vendor/VLCKit.xcframework`）の取得 |
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

### データ放送のページ（Node）

`BML/` の TypeScript は esbuild で 1 つのスクリプトにまとめてからアプリに同梱します。
ビルド済みの出力はリポジトリに含めているので、通常のビルドに Node は要りません。

```sh
cd BML
npm ci                 # web-bml と esbuild を package-lock.json のとおりに固定
npm test               # psisiarc のパーサ・メッセージ・EIT[p/f]・モックのデータ
npm run build          # App/KonomiTV/Resources/BML に出力（変更したら実行）
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
- `build`: 上記 2 つが成功したあとに macOS 26 + Xcode 26.6 でアプリと UI テストを 1 回だけビルド（build-for-testing）し、
  成果物を後続の E2E ジョブへ渡します。ドラフトの pull request ではスキップします
- `e2e`: `build` の成果物を使い、"iPhone 17" と "iPad Pro 13-inch (M5)" の 2 ジョブを並列に実行します。
  iPhone ではすべての UI テスト、iPad ではレイアウト・再生（PiP）・番組表のテストだけを実行します（片方が失敗しても、もう片方は最後まで実行）。
  xcresult、アプリのログ、モックサーバーのログは 7 日間 artifact として保存します。
  失敗したテストのメッセージ、そのテスト中のアプリのログ、失敗時の画面構造は `gh run view <run-id> --log-failed` で確認できます。
  同じ内容を artifact `logs-<端末>` の `ui-test-report.txt` にも保存します（長いジョブのログを GitHub が保存できなかったとき用）
- 手動実行では入力 `tests` に `PlaybackUITests/testLiveKeepsPlayingInBackground` のようなテストを空白区切りで指定すると、
  両方の端末でそのテストだけを実行します（例: `gh workflow run ci.yml --ref feat/ios-client -f tests="PlaybackUITests/testLiveKeepsPlayingInBackground"`）
- `ipa`: 署名なしの `.ipa`（artifact `KonomiTV-unsigned-ipa`）を `build` と並列にビルドします。push と手動実行のときだけ動き、pull request では作りません。
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

- 字幕のデコードと描画には [libaribcaption](https://github.com/magicxqq/libaribcaption)（MIT License,
  Copyright (c) 2022 magicxqq）を `Packages/ARIBCaption` に同梱しています。
- データ放送の描画には [web-bml](https://github.com/tsukumijima/web-bml)（MIT License,
  Copyright (c) tsukumijima）を WKWebView 用のバンドルとして同梱しています。BML の描画に使う
  [Kosugi / Kosugi Maru](https://github.com/tsukumijima/web-bml/tree/master/fonts)（Fontworks,
  Apache License 2.0）も同梱しています。ライセンスの全文は
  `App/KonomiTV/Resources/BML/fonts/` にあります。データ放送だけが WKWebView を使う理由は
  冒頭のとおりです。
- 再生エンジンには [VLCKit 4](https://code.videolan.org/videolan/VLCKit)（libVLC, LGPL-2.1-or-later,
  Copyright (c) VideoLAN and VLC authors）を動的フレームワークとして同梱しています。LGPL のため、
  アプリと静的にリンクせず `VLCKit.framework` をそのまま埋め込み・署名しています
  （`scripts/fetch-vlckit.py` で取得）。
- バージョンは `v1.2.3` のようなタグから `MARKETING_VERSION` に設定され、
  `CURRENT_PROJECT_VERSION` は GitHub Actions の実行番号になります。
- `KonomiTV.xcodeproj`、`DerivedData`、`.build`、`*.xcresult`、`__pycache__` などは
  `.gitignore` で除外しています。
