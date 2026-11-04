/**
 * ネイティブ (WKWebView のホスト) とのメッセージブリッジ。
 *
 * ページからネイティブへは `window.webkit.messageHandlers.bml.postMessage()`
 * だけを使い、ネイティブからページへは `KonomiBML.*` の関数を呼んでもらう。
 * ここではメッセージの形を 1 か所にまとめ、ブラウザ (開発用) では console に
 * 出す。
 */

export type BMLState = 'unavailable' | 'loading' | 'ready' | 'visible' | 'invisible' | 'error'

/** 映像プレーンの矩形 (ページの CSS px) */
export type VideoRect = { left: number, top: number, width: number, height: number }

export type PageSize = { width: number, height: number }

/** 番組情報 (EIT[p/f])。ネイティブは Program に変換して UI に出す */
export type ProgramPFProgram = {
  id: string
  channel_id: string
  network_id: number
  service_id: number
  event_id: number
  title: string
  description: string
  /** ISO 8601 (UTC) */
  start_time: string
  /** ISO 8601 (UTC) */
  end_time: string
  /** 秒。番組長が未定のときは null */
  duration: number | null
  is_free: boolean
}

export type BridgeMessage =
  | { type: 'state', state: BMLState }
  | { type: 'usedKeys', keys: string[] }
  | { type: 'videoRect', rect: VideoRect | null, pageSize: PageSize }
  | { type: 'programPF', presentOrFollowing: 'Present' | 'Following', program: ProgramPFProgram }
  | { type: 'error', title: string, message: string, code?: string }
  | { type: 'log', message: string }

export type Poster = (message: BridgeMessage) => void

/**
 * リモコンのキーと BML のキー種別 (used-key-list) の対応。
 *
 * web-bml の `usedkeylistchanged` はキー種別 (`basic` / `data-button` /
 * `numeric-tuning` / `other-tuning` / `special-1` / `special-2`) を返すので、
 * リモコンのキー名に展開してネイティブに渡す。データボタン (d) は仕様上
 * キー種別に含まれないため、常に有効にする (Web 版のリモコンと同じ)。
 */
export const REMOTE_KEY_GROUPS: { [key: string]: string } = {
  up: 'basic',
  down: 'basic',
  left: 'basic',
  right: 'basic',
  enter: 'basic',
  back: 'basic',
  blue: 'data-button',
  red: 'data-button',
  green: 'data-button',
  yellow: 'data-button',
  '1': 'numeric-tuning',
  '2': 'numeric-tuning',
  '3': 'numeric-tuning',
  '4': 'numeric-tuning',
  '5': 'numeric-tuning',
  '6': 'numeric-tuning',
  '7': 'numeric-tuning',
  '8': 'numeric-tuning',
  '9': 'numeric-tuning',
  '10': 'numeric-tuning',
  '11': 'numeric-tuning',
  '12': 'numeric-tuning',
}

/** リモコンのキー名 (レイアウト順) */
export const REMOTE_KEYS: string[] = [
  'up', 'down', 'left', 'right', 'enter', 'back',
  'blue', 'red', 'green', 'yellow',
  '1', '2', '3', '4', '5', '6', '7', '8', '9', '10', '11', '12',
]

/** 使えるキー種別から、押せるリモコンのキー名を返す。 */
export function enabledKeys(groups: Iterable<string>): string[] {
  const used = new Set(groups)
  const enabled = REMOTE_KEYS.filter((key) => used.has(REMOTE_KEY_GROUPS[key]))
  // データボタンは常に押せる
  return ['d', ...enabled]
}

/** ブラウザで開いたときのフォールバック */
function consolePoster(message: BridgeMessage): void {
  console.log('[KonomiBML]', message)
}

/** ネイティブのメッセージハンドラ (`bml`) に送る */
export function nativePoster(): Poster {
  if (typeof window === 'undefined') {
    return consolePoster
  }
  const handler = (window as unknown as {
    webkit?: { messageHandlers?: { bml?: { postMessage(message: BridgeMessage): void } } }
  }).webkit?.messageHandlers?.bml
  if (handler == null) {
    return consolePoster
  }
  return (message) => handler.postMessage(message)
}

export class Bridge {
  private readonly post: Poster

  constructor(post: Poster = nativePoster()) {
    this.post = post
  }

  send(message: BridgeMessage): void {
    this.post(message)
  }

  state(state: BMLState): void {
    this.post({ type: 'state', state })
  }

  usedKeys(groups: Iterable<string>): void {
    this.post({ type: 'usedKeys', keys: enabledKeys(groups) })
  }

  videoRect(rect: VideoRect | null, pageSize: PageSize): void {
    this.post({ type: 'videoRect', rect, pageSize })
  }

  programPF(presentOrFollowing: 'Present' | 'Following', program: ProgramPFProgram): void {
    this.post({ type: 'programPF', presentOrFollowing, program })
  }

  error(title: string, message: string, code?: string): void {
    this.post({ type: 'error', title, message, code })
  }

  log(message: string): void {
    this.post({ type: 'log', message })
  }
}
