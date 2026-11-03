# 機能対応表

KonomiTV 公式 Web クライアント（master `0.15.0-dev` と最新リリース `v0.14.1`）の機能と、
このアプリでの対応状況です。`0.15` と書いた機能は `v0.14.1` のサーバーにはなく、
API が 404 を返すサーバーでは画面に出しません。

状態: ✅ 対応済み / 🚧 実装予定（フェーズ番号） / ⚠️ 要検討

## ナビゲーション

| Web | iOS | 状態 |
| --- | --- | --- |
| サイドバー（テレビ・番組表・ビデオ・マイリスト・視聴履歴・オフライン保存・録画予約・キャプチャ・設定） | レギュラー幅のサイドバー（テレビ・番組表・ビデオ・マイリスト・視聴履歴・キャプチャ・設定） | ✅ |
| ボトムナビ（テレビ・ビデオ・録画予約・キャプチャ・マイページ） | コンパクト幅のタブバー（テレビ・ビデオ・マイページ）とマイページの一覧（キャプチャを含む） | ✅ |

## テレビ

| 機能 | API | 状態 |
| --- | --- | --- |
| 放送種別ごとのチャンネル一覧・現在と次の番組 | `GET /api/channels` | ✅ |
| ピン留めチャンネル（並べ替え・設定画面） | クライアント設定 `pinned_channel_ids` | ✅ |
| 実況勢いでの並べ替え | `tv_channel_sort_by_jikkyo_force` | ✅ |
| チャンネル・番組検索（`/tv/search`） | `POST /api/programs/search`（キーワード検索のみ） | ✅ |
| ライブ視聴 | `GET /api/streams/live/{id}/{quality}/mpegts` | ✅ |
| 視聴中の状態（Standby / ONAir など）と視聴人数 | `GET /api/streams/live/{id}/{quality}/events`（SSE） | ✅ |
| チャンネル切り替え（上下・リモコンパネル） | — | ✅ |
| ライブ視聴の番組・チャンネルパネル | `GET /api/channels` | ✅ |
| ライブのコメントパネル（一覧・自動スクロール・投稿・色／位置／サイズ） | `GET /api/channels/{id}/jikkyo`、WebSocket | ✅ |
| ライブの Twitter / Bluesky パネル（投稿・タイムライン・検索・キャプチャ添付） | `/api/twitter/*`, `/api/bluesky/*` | ✅ |

## 番組表・番組検索

| 機能 | API | 状態 |
| --- | --- | --- |
| 番組表（放送種別・日付・ジャンル色・ショッピング番組の減光） | `GET /api/programs/timetable` | ✅ |
| 番組検索（条件フィルター） | `GET /api/programs/search` | 🚧 1 |

## ビデオ

| 機能 | API | 状態 |
| --- | --- | --- |
| 録画番組一覧・無限スクロール・検索 | `GET /api/videos`, `/api/videos/search` | ✅ |
| 並び順の切り替え | `order` クエリ | ✅ |
| シリーズ一覧・検索・詳細 | `GET /api/series`, `/api/series/search`, `/api/series/{id}` | 🚧 1（ビデオ詳細のシリーズ欄のみ） |
| マイリスト（番組・シリーズ） | クライアント設定 `mylist`（録画番組のみ） | ✅ |
| 視聴履歴・続きから再生 | クライアント設定 `watched_history` | ✅ |
| 録画ファイル情報 | `GET /api/videos/{id}` | ✅ |
| 管理者: 録画ファイル削除・メタデータ再解析・サムネイル再生成 | `DELETE /api/videos/{id}` ほか | ✅ |
| 録画ファイルのダウンロード | `GET /api/videos/{id}/download` | ✅ |
| シークバーのサムネイルプレビュー（シーン一覧） | `GET /api/videos/{id}/thumbnail/tiled` | ✅ |
| オフライン保存・オフライン再生（0.15） | `GET /api/streams/video/{id}/{quality}/offline-stream` | 🚧 9 |

## プレイヤー

| 機能 | 状態 |
| --- | --- |
| 画質の選択（Wi-Fi とモバイル通信で別設定、データ節約・低遅延・24fps） | ✅ |
| 再生中の画質切り替え・再生速度・主音声／副音声 | ✅ |
| ライブの低遅延モード（ライブエッジ付近の再生） | ✅ |
| L 字画面のクロップ | ⚠️ AVPlayerViewController に映像をクロップ／ズームする API がない |
| デュアルモノ（1 本のステレオトラックに左右で別音声） | ⚠️ AVPlayer の HLS 再生ではチャンネルをミックスし直せない |
| キーボードショートカット（iPad のハードウェアキーボード） | ✅ |
| PiP・バックグラウンド再生・ロック画面の再生中情報 | ✅ |
| ニコニコ実況コメントの表示・投稿・NG 設定 | ✅ |
| 録画番組の過去ログコメント | ✅ |
| ARIB 字幕・文字スーパー | ✅ |
| キャプチャ（字幕・コメント合成、写真への保存、サーバーへのアップロード） | ✅ |
| Twitter / Bluesky パネル（投稿・タイムライン・検索・RT・いいね） | ✅ |
| データ放送 | ⚠️ 10 |

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
| 予約一覧・詳細・追加・設定変更・削除 | `/api/recording/reservations/*` | 🚧 7 |
| キーワード自動予約条件 | `/api/recording/conditions/*` | 🚧 7 |
| 録画設定プリセット | `/api/recording/presets` | 🚧 7 |

## アカウント・設定・管理

| 機能 | API | 状態 |
| --- | --- | --- |
| ログイン・ログアウト | `POST /api/users/token` | ✅ |
| アカウント作成 | `POST /api/users` | 🚧 8 |
| ユーザー名・パスワード変更、アイコン、アカウント削除 | `/api/users/me*` | 🚧 8 |
| ニコニコ・Twitter・Bluesky アカウント連携 | `/api/niconico/*`, `/api/twitter/*`, `/api/bluesky/*` | ✅ |
| 設定の同期 | `GET/PUT /api/settings/client` | ✅ |
| 管理者: ユーザー管理 | `/api/users`, `/api/users/{name}` | 🚧 8 |
| 管理者: サーバー設定 | `GET/PUT /api/settings/server` | 🚧 8 |
| 管理者: メンテナンス（ログ、DB 更新、スキャン、再起動、終了） | `/api/maintenance/*` | 🚧 8 |
