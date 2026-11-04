# BML (データ放送)

KonomiTV for iOS のデータ放送画面です。[web-bml](https://github.com/tsukumijima/web-bml)
(MIT License, Copyright (c) 2022 tsukumijima) を WKWebView の中で動かします。

アプリの他の画面はすべてネイティブ SwiftUI ですが、データ放送 (BML) だけは
放送波のデータカルーセルから流れてくる BML 文書を解釈して描画する必要がある
ため、Web クライアントと同じ web-bml をそのまま使っています。BML の外側
(リモコン・設定・映像の配置) はネイティブです。

## 構成

| ファイル | 内容 |
| --- | --- |
| `src/main.ts` | ページの入口 (`window.KonomiBML`) |
| `src/session.ts` | BML ブラウザと PSI/SI アーカイブデータのデコード (Web 版の LiveDataBroadcastingManager + LivePSIArchivedDataDecoder) |
| `src/psi.ts` | psisiarc (PSI/SI アーカイブデータ) の読み取りと TS パケットのヘッダ付与 |
| `src/program.ts` | EIT[p/f] → 番組情報 (現在 / 次の番組) |
| `src/bridge.ts` | ネイティブとのメッセージ (`window.webkit.messageHandlers.bml`) |
| `src/storage.ts` | localStorage / sessionStorage の代替と受信機情報 (郵便番号・都道府県) のシード |
| `src/index.html` | ページ本体 (透明・スクロールなし) |
| `fonts/` | web-bml 用フォント (Kosugi / Kosugi Maru, Apache License 2.0) |
| `test/` | node:test による単体テスト (psisiarc のパーサ・メッセージ・EIT[p/f]・モックのデータ) |

## ビルド

生成物 (`App/KonomiTV/Resources/BML/bml.js`・`index.html`・`fonts/`) は
リポジトリに含めています。iOS の CI には Node が無いため、アプリのバンドルには
常にビルド済みのページを入れます。

```sh
cd BML
npm ci                 # package-lock.json のとおりに web-bml と esbuild を固定
npm run build          # App/KonomiTV/Resources/BML に出力
npm test               # node:test (nix shell nixpkgs#nodejs_22 -c npm test)
npm run typecheck      # tsc --noEmit
```

`web-bml` は `47fec53cd66734d6cba0fff3c6dfcfc150043109`、`esbuild` は
`0.25.10` に固定しています。ビルドは決定的 (minify のみ) なので、同じ
`node_modules` からは同じ `bml.js` ができます。開発中は
`node esbuild.config.mjs --dev` でソースマップ付きの非圧縮版を出力できます。

## ネイティブとのやり取り

ネイティブはページの関数を呼びます。

| 関数 | 内容 |
| --- | --- |
| `KonomiBML.start()` | `WKUserScript` が注入した `window.__KonomiBMLConfig` で開始する |
| `KonomiBML.start({...})` | 設定を上書きして開始する |
| `KonomiBML.stop()` | BML ブラウザとストリームを終了する |
| `KonomiBML.key(name, down)` | リモコンのキー (ARIB キーコード) を送る |
| `KonomiBML.setVisible(bool)` / `toggle()` | データ放送画面の表示/非表示 |
| `KonomiBML.resize(width, height)` | ページの大きさ (CSS px) の変更 |

ページは `window.webkit.messageHandlers.bml.postMessage()` で次のメッセージを
送ります (`src/bridge.ts`)。

| type | 内容 |
| --- | --- |
| `state` | `unavailable` / `loading` / `ready` / `visible` / `invisible` / `error` |
| `usedKeys` | 押せるリモコンのキー名 (web-bml の used-key-list をキー名に展開したもの) |
| `videoRect` | 映像プレーンの矩形 (ページの CSS px)。`null` なら映像は全面 |
| `programPF` | EIT[p/f] の現在 / 次の番組 |
| `error` | web-bml のエラーメッセージ (タイトル・本文・コード) |

API (PSI/SI アーカイブデータ・データ放送のインターネットアクセス) は、
ネイティブが `konomitv-bml://app/api/...` を KonomiTV サーバーへ中継します。
ページ側は同じオリジンの `fetch` だけでよく、CORS も認証ヘッダも意識しません。
