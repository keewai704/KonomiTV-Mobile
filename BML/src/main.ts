/**
 * データ放送ページの入口。
 *
 * ネイティブ (WKWebView) は次の関数だけを呼ぶ:
 *   KonomiBML.start()           ページの設定 (window.__KonomiBMLConfig) で開始
 *   KonomiBML.start({...})      設定を上書きして開始
 *   KonomiBML.stop()            BML ブラウザとストリームを終了
 *   KonomiBML.key(name, down)   リモコンのキー (ARIB キーコード)
 *   KonomiBML.setVisible(bool)  データ放送画面の表示/非表示
 *   KonomiBML.toggle()          表示/非表示の切り替え
 *   KonomiBML.resize(w, h)      ページの大きさ (CSS px) の変更
 *
 * ネイティブへの通知はすべて window.webkit.messageHandlers.bml 経由
 * (bridge.ts 参照)。
 */

import type { BMLPageConfig } from './session.ts'
import { DataBroadcastingSession } from './session.ts'
import { clearStorage, installStorage } from './storage.ts'

export type KonomiBMLAPI = {
  readonly version: string
  start: (overrides?: Partial<BMLPageConfig>) => void
  stop: () => void
  key: (name: string, down: boolean) => void
  setVisible: (visible: boolean) => void
  toggle: () => void
  resize: (width: number, height: number) => void
  clearStorage: () => void
}

declare global {
  interface Window {
    KonomiBML?: KonomiBMLAPI
    /** WKUserScript が文書の先頭で注入する設定 */
    __KonomiBMLConfig?: Partial<BMLPageConfig>
  }
}

// web-bml は localStorage / sessionStorage を使うので先に差し替える
installStorage()

let session: DataBroadcastingSession | null = null

const api: KonomiBMLAPI = {
  get version(): string {
    return '1.0.0'
  },

  start(overrides: Partial<BMLPageConfig> = {}): void {
    session?.stop()
    session = null

    const injected = window.__KonomiBMLConfig ?? {}
    const config: BMLPageConfig = {
      channelId: '',
      networkId: 0,
      serviceId: 0,
      quality: '',
      apiBase: '',
      internetAccess: false,
      receiverInfo: {},
      ...injected,
      ...overrides,
    }
    if (config.channelId === '' || config.apiBase === '' || config.quality === '') {
      console.error('[KonomiBML] start() without a channel configuration')
      return
    }
    if (config.pageSize == null) {
      config.pageSize = { width: window.innerWidth, height: window.innerHeight }
    }
    const created = new DataBroadcastingSession(config)
    session = created
    created.start()
  },

  stop(): void {
    session?.stop()
    session = null
  },

  key(name: string, down: boolean): void {
    session?.key(name, down)
  },

  setVisible(visible: boolean): void {
    session?.setVisible(visible)
  },

  toggle(): void {
    session?.toggle()
  },

  resize(width: number, height: number): void {
    session?.resize(width, height)
  },

  clearStorage(): void {
    clearStorage()
  },
}

window.KonomiBML = api
