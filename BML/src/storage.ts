/**
 * web-bml が使う localStorage / sessionStorage の代替。
 *
 * WKWebView のカスタムスキーム (konomitv-bml://) では localStorage が使えない
 * ことがあるため、ページの先頭でメモリ上の実装に差し替える。保存データは
 * ページの世代 (チャンネル切り替え・設定変更のたびに作り直される) の中だけ
 * 保持する。受信機情報 (郵便番号・都道府県) はネイティブが注入した値を
 * 毎回シードし直すので、チャンネルを変えても引き継がれる。
 */

/** web-bml に渡す storagePrefix */
export const STORAGE_PREFIX = 'KonomiTV-BMLBrowser_'
/** web-bml に渡す nvramPrefix */
export const NVRAM_PREFIX = 'nvram_'
/** web-bml の NVRAM の localStorage キーの前置き (Web 版と同じ) */
export const RECEIVER_INFO_KEY_PREFIX = `${STORAGE_PREFIX}${NVRAM_PREFIX}prefix=receiverinfo%2F`

type StorageLike = {
  readonly length: number
  getItem(key: string): string | null
  setItem(key: string, value: string): void
  removeItem(key: string): void
  clear(): void
  key(index: number): string | null
}

function createStorage(): StorageLike & { entries(): Map<string, string> } {
  const entries = new Map<string, string>()
  return {
    entries: () => entries,
    get length() {
      return entries.size
    },
    getItem(key: string): string | null {
      return entries.has(key) ? (entries.get(key) as string) : null
    },
    setItem(key: string, value: string): void {
      entries.set(String(key), String(value))
    },
    removeItem(key: string): void {
      entries.delete(key)
    },
    clear(): void {
      entries.clear()
    },
    key(index: number): string | null {
      const keys = [...entries.keys()]
      return index >= 0 && index < keys.length ? keys[index] : null
    },
  }
}

const memoryLocalStorage = createStorage()
const memorySessionStorage = createStorage()

/** localStorage / sessionStorage をメモリ上の実装に差し替える。 */
export function installStorage(): void {
  for (const [name, storage] of [
    ['localStorage', memoryLocalStorage],
    ['sessionStorage', memorySessionStorage],
  ] as const) {
    try {
      Object.defineProperty(window, name, {
        value: storage,
        configurable: true,
        writable: false,
      })
    } catch {
      // 差し替えられない環境では本物の storage をそのまま使う
    }
  }
}

/**
 * ネイティブが注入した受信機情報を web-bml の NVRAM に書く。
 *
 * Web 版と同じく、値は base64 にした生のバイト列 (zipcode = 7 桁の数字、
 * prefecture = 1 バイト、regioncode = 2 バイト)。
 */
export function seedReceiverInfo(receiverInfo: { [name: string]: string }): void {
  for (const [name, value] of Object.entries(receiverInfo)) {
    memoryLocalStorage.setItem(`${RECEIVER_INFO_KEY_PREFIX}${name}`, value)
  }
}

/** データ放送の保存データ (NVRAM と localStorage) をすべて消す。 */
export function clearStorage(): void {
  memoryLocalStorage.clear()
  memorySessionStorage.clear()
}
