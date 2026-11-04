# 機能対応表

KonomiTV 公式 Web クライアント（master `0.15.0-dev` と最新リリース `v0.14.1`）の機能と、
このアプリでの対応状況です。`0.15` と書いた機能は `v0.14.1` のサーバーにはなく、
API が 404 を返すサーバーでは画面に出しません。

状態: ✅ 対応済み / 🚧 実装予定（フェーズ番号） / ⚠️ 要検討

## ネイティブでない部分（データ放送だけ）

BML（データ放送）の文書は放送波から降ってくるマークアップで、描画には受信機（ブラウザ）の
実装が要ります。Web クライアントと同じ [web-bml](https://github.com/tsukumijima/web-bml) を
WKWebView の中だけで動かし、その外側（リモコン・設定・映像プレーンのレイアウト・映像の描画）は
すべてネイティブ SwiftUI / VLCKit です。ページは `BML/` の TypeScript をビルドしたものを
アプリに同梱しています（再ビルドは `BML/README.md` 参照）。

## ナビゲーション

| Web | iOS | 状態 |
| --- | --- | --- |
| サイドバー（テレビ・番組表・ビデオ・マイリスト・視聴履歴・オフライン保存・録画予約・キャプチャ・設定） | レギュラー幅のサイドバー（テレビ・番組表・ビデオ・マイリスト・視聴履歴・キャプチャ・録画予約・オフライン・設定） | ✅ |
| ボトムナビ（テレビ・ビデオ・録画予約・キャプチャ・マイページ） | コンパクト幅のタブバー（テレビ・ビデオ・マイページ）とマイページの一覧（キャプチャ・録画予約・オフラインを含む） | ✅ |

## テレビ

| 機能 | API | 状態 |
| --- | --- | --- |
| 放送種別ごとのチャンネル一覧・現在と次の番組 | `GET /api/channels` | ✅ |
| ピン留めチャンネル（並べ替え・設定画面） | クライアント設定 `pinned_channel_ids` | ✅ |
| 実況勢いでの並べ替え | `tv_channel_sort_by_jikkyo_force` | ✅ |
| チャンネル・番組検索（`/tv/search`） | `POST /api/programs/search`（キーワード・除外キーワード・ジャンル・チャンネル・放送日時・番組長・放送種別） | ✅ |
| ライブ視聴 | `GET /api/streams/live/{id}/{quality}/mpegts` | ✅ |
| 視聴中の状態（Standby / ONAir など）と視聴人数 | `GET /api/streams/live/{id}/{quality}/events`（SSE） | ✅ |
| チャンネル切り替え（上下・リモコンパネル） | — | ✅ |
| ライブ視聴の番組・チャンネルパネル | `GET /api/channels` | ✅ |
| ライブのコメントパネル（一覧・自動スクロール・投稿・色／位置／サイズ） | `GET /api/channels/{id}/jikkyo`、WebSocket | ✅ |
| ライブの Twitter / Bluesky パネル（投稿・タイムライン・検索・キャプチャ添付） | `/api/twitter/*`, `/api/bluesky/*` | ✅ |
| ライブのデータ放送（BML）。表示の切り替え（リモコンの d／ツールバー）と読み込み状態 | `GET /api/streams/live/{id}/{quality}/psi-archived-data` | ✅ |
| データ放送のリモコン（方向・決定・戻る・データ・青赤緑黄・1〜12、受け付けるキーだけ有効） | — | ✅ |
| データ放送の双方向機能（データ放送からのインターネットアクセス） | `/api/data-broadcasting/*` | ✅ |
| データ放送の設定（有効／無効、インターネットアクセス、郵便番号・都道府県） | ローカル設定（Web 版で同期無効の項目） | ✅ |
| EIT[p/f] による現在・次の番組のリアルタイム更新 | `psi-archived-data` | ✅ |
| データ放送からのチャンネル切り替え（EPG チューン） | — | ⚠️ コンテンツからの選局には未対応（切り替えられないことをコンテンツに返す） |
| データ放送の保存データのリセット（Web 版の設定画面のボタン） | — | ⚠️ ページの保存データはページの世代の中だけ保持する |

## 番組表・番組検索

| 機能 | API | 状態 |
| --- | --- | --- |
| 番組表（放送種別・日付・ジャンル色・ショッピング番組の減光） | `GET /api/programs/timetable` | ✅ |
| 番組表からの録画予約（予約・プリセット指定・設定変更・キャンセル、予約マーカー） | `/api/recording/reservations/*` | ✅ |
| 番組検索（条件フィルター） | `POST /api/programs/search` | ✅ |
| 番組検索の条件シート（キーワード・除外キーワード・番組名のみ・大小文字・あいまい／正規表現・ジャンルと除外・チャンネル・放送日時と除外・番組長・無料／有料） | `POST /api/programs/search` | ✅ |

## ビデオ

| 機能 | API | 状態 |
| --- | --- | --- |
| 録画番組一覧・無限スクロール・検索 | `GET /api/videos`, `/api/videos/search` | ✅ |
| 並び順の切り替え | `order` クエリ | ✅ |
| シリーズ一覧・検索・詳細（放送期間ごとのエピソード） | `GET /api/series`, `/api/series/search`, `/api/series/{id}` | ✅ |
| マイリスト（番組・シリーズ） | クライアント設定 `mylist`（`RecordedProgram` と `Series`） | ✅ |
| 視聴履歴・続きから再生 | クライアント設定 `watched_history` | ✅ |
| 録画ファイル情報 | `GET /api/videos/{id}` | ✅ |
| 管理者: 録画ファイル削除・メタデータ再解析・サムネイル再生成 | `DELETE /api/videos/{id}` ほか | ✅ |
| 録画ファイルのダウンロード | `GET /api/videos/{id}/download` | ✅ |
| シークバーのサムネイルプレビュー（シーン一覧） | `GET /api/videos/{id}/thumbnail/tiled` | ✅ |
| オフライン保存・オフライン再生（0.15） | `GET /api/streams/video/{id}/{quality}/offline-stream` | ✅ |

## プレイヤー

| 機能 | 状態 |
| --- | --- |
| 画質の選択（Wi-Fi とモバイル通信で別設定、データ節約・低遅延・24fps） | ✅ |
| 再生中の画質切り替え・再生速度・主音声／副音声 | ✅ |
| ライブの低遅延モード（ライブエッジ付近の再生） | ✅ |
| L 字画面のクロップ | ⚠️ VLCKit のクロップ／ズームは未実装（libVLC には `setCropRatioWithNumerator:denominator:` がある） |
| デュアルモノ（1 本のステレオトラックに左右で別音声） | ⚠️ ライブの HLS 再パケット化ではチャンネルをミックスし直せない |
| プレイヤーの操作パネル（タップで表示、再生中は約 3 秒で自動非表示） | ✅ |
| シークバー（経過・残り時間）と ±10 秒／±30 秒スキップ | ✅ |
| ライブのライブエッジ復帰（「ライブ」ボタン） | ✅ |
| ミュート・AirPlay・PiP のプレイヤー内ボタン | ✅ |
| キーボードショートカット（iPad のハードウェアキーボード） | ✅ |
| PiP・バックグラウンド再生・ロック画面の再生中情報（再生／一時停止・スキップ・シークのリモート操作を含む） | ✅ |
| ニコニコ実況コメントの表示・投稿・NG 設定 | ✅ |
| 録画番組の過去ログコメント | ✅ |
| ARIB 字幕・文字スーパー | ✅ |
| キャプチャ（字幕・コメント合成、写真への保存、サーバーへのアップロード） | ✅ |
| Twitter / Bluesky パネル（投稿・タイムライン・検索・RT・いいね） | ✅ |
| データ放送（web-bml を WKWebView で表示、PSI/SI アーカイブデータのデコード、映像プレーンへの映像配置） | ✅ |

## オフライン保存（0.15）

オフライン保存 API がないサーバー（v0.14.1）では保存の項目を表示しません。保存済みのビデオは
サーバーに接続できないときも一覧・再生できます。

| 機能 | API | 状態 |
| --- | --- | --- |
| 録画番組のオフライン保存（画質の選択・容量の見積もり・通信節約モード、空き容量の確認、進捗・キャンセル・再試行） | `GET /api/streams/video/{id}/{quality}/offline-stream` | ✅ |
| 保存したビデオの再生（ループバックサーバー経由、ネットワーク不要、続きから再生、PiP・バックグラウンド再生・字幕） | — | ✅ |
| 保存データの管理（保存容量・空き容量の表示、削除の確認） | — | ✅ |
| 保存時に付随データ（サムネイル・過去ログコメント）を保存し、オフラインでも一覧とコメントを表示 | `GET /api/videos/{id}/thumbnail`, `GET /api/videos/{id}/jikkyo` | ✅ |
| 副音声の切り替え（オフライン再生） | — | ⚠️ 保存した MPEG-TS の副音声を選び分けるプレイリストを生成していないため、主音声のみ |
| シークバーのタイルサムネイル（オフライン再生） | `GET /api/videos/{id}/thumbnail/tiled` | ⚠️ 保存していないため、オフライン再生では表示しない |

## キャプチャ（0.15）

キャプチャの一覧 API がないサーバー（v0.14.1）ではセクション自体を表示しません。保存（アップロード）だけは動きます。

| 機能 | API | 状態 |
| --- | --- | --- |
| 一覧・日付別・放送回別・お気に入り・タグ・検索 | `/api/captures/*` | ✅ |
| 保存先（端末・KonomiTV サーバー・両方）・ファイル名パターン・クリップボードへのコピー | `POST /api/captures`、クライアント設定 | ✅ |
| 字幕・コメントの合成（EXIF の XPComment に番組情報を書き込む） | — | ✅ |

## Twitter / Bluesky

視聴画面のパネルの「Twitter」タブと、設定 → Twitter / Bluesky の画面です。

| 機能 | API | 状態 |
| --- | --- | --- |
| Twitter アカウント連携（Cookie / cookies.txt）・連携解除 | `POST /api/twitter/auth`, `DELETE /api/twitter/accounts/{screen_name}` | ✅ |
| Bluesky アカウント連携（ハンドル + App Password）・連携解除 | `POST /api/bluesky/auth`, `DELETE /api/bluesky/accounts/{handle}` | ✅ |
| Twitter / Bluesky アカウントの紐付け・紐付け解除 | `POST/DELETE /api/users/me/account-links` | ✅ |
| 投稿（ハッシュタグ、保存したハッシュタグ、文字数、位置、キャプチャ 4 枚まで・透かし、同時投稿） | `POST /api/twitter/accounts/{screen_name}/tweets`, `POST /api/bluesky/accounts/{handle}/posts` | ✅ |
| リプライツリー実況（ハッシュタグごと・1 日ごと・無効） | — | ✅ |
| タイムライン（Twitter と Bluesky の統合表示、続きの読み込み） | `GET /api/twitter/accounts/{screen_name}/timeline`, `GET /api/bluesky/accounts/{handle}/timeline` | ✅ |
| 検索（チャンネルの局タグで自動検索、統合表示） | `GET /api/twitter/accounts/{screen_name}/search`, `GET /api/bluesky/accounts/{handle}/search` | ✅ |
| リツイート／リポスト・いいね | `PUT/DELETE .../retweet`, `.../repost`, `.../favorite`, `.../like` | ✅ |
| ヘッドレスブラウザの Keep-Alive | `POST /api/twitter/accounts/{screen_name}/keep-alive` | ✅ |
| ツイートの動画（プロキシ再生） | `GET /api/twitter/video-proxy` | ⚠️ 画像のみ対応 |
| 「リツイートを表示する」の切り替え | — | ⚠️ 未対応 |

## 録画予約

| 機能 | API | 状態 |
| --- | --- | --- |
| 予約一覧（録画中・放送が近い予約・チューナー不足・無効のグループと「すべて」） | `GET /api/recording/reservations` | ✅ |
| 予約詳細・設定変更（有効・優先度・プリセット・録画フォルダ・マージン・字幕／データ放送・録画後動作） | `GET/PUT /api/recording/reservations/{id}` | ✅ |
| 番組表・ライブの番組パネルからの予約追加・キャンセル | `POST/DELETE /api/recording/reservations` | ✅ |
| 削除（確認ダイアログ・削除後の再追加） | `DELETE /api/recording/reservations/{id}` | ✅ |
| キーワード自動予約条件（一覧・追加・変更・削除、キーワード・除外キーワード・検索オプション・チャンネル範囲・番組長・放送種別・重複チェック） | `/api/recording/conditions/*` | ✅ |
| キーワード自動予約条件でのジャンル範囲・曜日／時間帯範囲の編集 | `/api/recording/conditions/*` | ⚠️ 未対応（Web クライアントにも編集 UI がない） |
| 録画設定プリセット | `GET /api/recording/presets` | ✅ |

## アカウント・設定・管理

| 機能 | API | 状態 |
| --- | --- | --- |
| ログイン・ログアウト | `POST /api/users/token` | ✅ |
| アカウント作成（作成後すぐログイン、最初のアカウントは管理者） | `POST /api/users` | ✅ |
| ユーザー名・パスワード変更（現在のパスワード・新しいパスワード・確認）、アカウント削除 | `/api/users/me` | ✅ |
| アイコン画像のアップロード（PhotosPicker、JPEG / PNG） | `GET/PUT /api/users/me/icon` | ✅ |
| アイコン画像の初期状態へのリセット | — | ⚠️ サーバーにアイコン削除 API がないため、選択の取り消し（アップロード前の状態に戻す）のみ |
| アイコンの表示（設定・アカウント・ユーザー管理） | `GET /api/users/me/icon`, `GET /api/users/{name}/icon` | ✅ |
| ニコニコ・Twitter・Bluesky アカウント連携 | `/api/niconico/*`, `/api/twitter/*`, `/api/bluesky/*` | ✅ |
| 設定の同期 | `GET/PUT /api/settings/client` | ✅ |
| 管理者: ユーザー管理（一覧・アイコン・管理者権限の付与／剥奪・削除） | `GET /api/users`, `PUT/DELETE /api/users/{name}` | ✅ |
| 管理者: 他ユーザーのユーザー名・パスワード変更 | — | ⚠️ サーバーの管理用 API が管理者権限の変更のみ許可しているため（本人のアカウント設定から変更） |
| 管理者: サーバー設定（全般・サーバー・テレビ・ビデオ・キャプチャ、再起動が必要な旨の表示） | `GET/PUT /api/settings/server` | ✅ |
| 管理者: メンテナンス（サーバーログ／アクセスログの SSE 表示・追従、DB 更新、一括スキャン・バックグラウンド解析・キャプチャスキャン・DB 最適化の実行と進捗、再起動・終了と再接続状態） | `/api/maintenance/*` | ✅ |
| バージョン情報（サーバーのバージョン・最新バージョン・アップデート通知） | `GET /api/version` | ✅ |
