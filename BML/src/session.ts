/**
 * データ放送のセッション。
 *
 * Web クライアントの LiveDataBroadcastingManager (BML ブラウザの生成と設定,
 * 映像プレーンの通知, リモコンのキー) と LivePSIArchivedDataDecoder (PSI/SI
 * アーカイブデータの取得と TS のデコード) を、DPlayer と Vue 抜きで 1 つの
 * ページにまとめたもの。ネイティブとのやり取りは Bridge 経由のみ。
 */

import { AribKeyCode, BMLBrowser } from 'web-bml'
import type { BMLBrowserFontFace } from 'web-bml'
import { decodeTS } from 'web-bml/ts'

import { Bridge } from './bridge.ts'
import type { PageSize } from './bridge.ts'
import { buildProgramPF } from './program.ts'
import type { EITSection } from './program.ts'
import { PSIArchivedDataParser, TSPacketWriter } from './psi.ts'
import { NVRAM_PREFIX, seedReceiverInfo, STORAGE_PREFIX } from './storage.ts'

/** BML 用フォント (Web 版と同じ) */
const ROUND_GOTHIC: BMLBrowserFontFace = {
  source: 'url("fonts/KosugiMaru-Regular.woff2"), local("sans-serif")',
}
const SQUARE_GOTHIC: BMLBrowserFontFace = {
  source: 'url("fonts/Kosugi-Regular.woff2"), local("sans-serif")',
}

/** ネイティブが注入するページの設定 */
export type BMLPageConfig = {
  /** display_channel_id (例: gr011) */
  channelId: string
  channelName?: string
  /** チャンネルの network_id / service_id (EIT[p/f] の絞り込みに使う) */
  networkId: number
  serviceId: number
  /** API の画質 (例: 1080p-60fps) */
  quality: string
  /** API のベース URL (例: konomitv-bml://app/api) */
  apiBase: string
  /** データ放送からのインターネットアクセス */
  internetAccess: boolean
  /** 受信機情報 (web-bml の NVRAM に書く base64 の値) */
  receiverInfo: { [name: string]: string }
  /** ページの CSS px での大きさ (省略時はウィンドウの大きさ) */
  pageSize?: PageSize
}

/** リモコンのキー名 → ARIB のキーコード (Web 版 Remocon.vue と同じ) */
const KEY_CODES: { [key: string]: AribKeyCode } = {
  up: AribKeyCode.Up,
  down: AribKeyCode.Down,
  left: AribKeyCode.Left,
  right: AribKeyCode.Right,
  enter: AribKeyCode.Enter,
  back: AribKeyCode.Back,
  d: AribKeyCode.DataButton,
  blue: AribKeyCode.BlueButton,
  red: AribKeyCode.RedButton,
  green: AribKeyCode.GreenButton,
  yellow: AribKeyCode.YellowButton,
  '1': AribKeyCode.Digit1,
  '2': AribKeyCode.Digit2,
  '3': AribKeyCode.Digit3,
  '4': AribKeyCode.Digit4,
  '5': AribKeyCode.Digit5,
  '6': AribKeyCode.Digit6,
  '7': AribKeyCode.Digit7,
  '8': AribKeyCode.Digit8,
  '9': AribKeyCode.Digit9,
  '10': AribKeyCode.Digit10,
  '11': AribKeyCode.Digit11,
  '12': AribKeyCode.Digit12,
}

/** TS リーダー (web-bml/ts) のうち、ここで使う範囲 */
type TSReaderLike = {
  push(packets: Uint8Array): void
  close(): void
  addEventListener(type: 'eit', callback: (event: { pid: number, section: EITSection & { tableIdNumber: number } }) => void): void
}

export class DataBroadcastingSession {
  private readonly config: BMLPageConfig
  private readonly bridge: Bridge
  private browser: BMLBrowser | null = null
  private container: HTMLElement | null = null
  private scaleElement: HTMLElement | null = null
  private pageSize: PageSize
  private bmlWidth = 960
  private bmlHeight = 540
  /** 映像プレーンを表示しているか (BML の invisible とネイティブの操作の両方) */
  private isVisible = true
  /** 直前に伝えた表示状態 (同じ値を何度も送らない) */
  private lastReportedState: string = ''
  private parser = new PSIArchivedDataParser()
  private packetWriter = new TSPacketWriter()
  private tsStream: TSReaderLike | null = null
  private psiRequest: AbortController | null = null
  private greg: string[] = new Array(64).fill('')

  constructor(config: BMLPageConfig, bridge: Bridge = new Bridge()) {
    this.config = config
    this.bridge = bridge
    this.pageSize = config.pageSize ?? { width: window.innerWidth, height: window.innerHeight }
  }

  // MARK: - ライフサイクル

  /** ページを準備し、PSI/SI アーカイブデータの取得を始める。 */
  start(): void {
    this.isVisible = true
    this.lastReportedState = ''
    this.setState('loading')
    try {
      seedReceiverInfo(this.config.receiverInfo)
      this.createBrowser()
      this.applyScale()
      this.startPSI()
    } catch (error) {
      // ページ自体を組み立てられなかった (BML の不具合ではなくページの不具合)
      const message = error instanceof Error ? error.message : String(error)
      this.bridge.error('データ放送', message, 'E100')
      this.setState('error')
    }
  }

  /** BML ブラウザとデータの取得を終了する。 */
  stop(): void {
    this.psiRequest?.abort()
    this.psiRequest = null
    this.tsStream?.close()
    this.tsStream = null
    this.parser.reset()
    this.packetWriter.reset()

    const browser = this.browser
    this.browser = null
    if (browser != null) {
      browser.destroy().catch(() => {
        // 破棄中のエラーは無視する (チャンネル切り替え時によく起きる)
      })
    }
    if (this.container != null) {
      this.container.replaceChildren()
    }
    this.bridge.videoRect(null, this.pageSize)
    this.setState('invisible')
  }

  // MARK: - ネイティブからの操作

  /** リモコンのキーを送る。`down` が true なら押し、false なら離す。 */
  key(name: string, down: boolean): void {
    const keyCode = KEY_CODES[name]
    if (keyCode === undefined || this.browser == null) {
      return
    }
    if (!down) {
      this.browser.content.processKeyUp(keyCode)
      return
    }
    // リモコン番号 10 は "0" を押してから 10 を押す (Web 版と同じ)
    if (name === '10') {
      this.browser.content.processKeyDown(AribKeyCode.Digit0)
      this.browser.content.processKeyUp(AribKeyCode.Digit0)
    }
    this.browser.content.processKeyDown(keyCode)
  }

  /** データ放送画面の表示/非表示 (Web 版の d ボタンと同じ結果にする)。 */
  setVisible(visible: boolean): void {
    if (this.isVisible === visible) {
      return
    }
    this.isVisible = visible
    if (this.container != null) {
      this.container.style.visibility = visible ? 'visible' : 'hidden'
    }
    this.setState(visible ? 'visible' : 'invisible')
    this.reportVideoRect()
  }

  /** 表示/非表示を切り替える。 */
  toggle(): void {
    this.setVisible(!this.isVisible)
  }

  /** ページの大きさが変わった (回転・ウィンドウのリサイズ)。 */
  resize(width: number, height: number): void {
    this.pageSize = { width, height }
    this.applyScale()
    this.reportVideoRect()
  }

  // MARK: - BML ブラウザ

  private createBrowser(): void {
    const container = document.getElementById('bml-container')
    if (container == null) {
      throw new Error('bml-container is missing')
    }
    container.replaceChildren()
    container.style.visibility = 'visible'
    this.container = container
    this.scaleElement = document.getElementById('bml-scale')

    const browser = new BMLBrowser({
      containerElement: container,
      // 映像はネイティブが描くので、web-bml にはダミーの要素を渡す
      mediaElement: document.createElement('p'),
      storagePrefix: STORAGE_PREFIX,
      nvramPrefix: NVRAM_PREFIX,
      broadcasterDatabasePrefix: '',
      videoPlaneModeEnabled: true,
      fonts: {
        roundGothic: ROUND_GOTHIC,
        squareGothic: SQUARE_GOTHIC,
      },
      indicator: {
        // ローディングの表示は page 単位で行うので、ここでは何もしない
        setUrl(_name: string, _loading: boolean): void {},
        setNetworkingGetStatus(_connecting: boolean): void {},
        setNetworkingPostStatus(_connecting: boolean): void {},
        setReceivingStatus(_receiving: boolean): void {},
        setEventName(_name: string | null): void {},
      },
      greg: {
        getReg: (index: number) => this.greg[index] ?? '',
        setReg: (index: number, value: string) => {
          this.greg[index] = value
        },
      },
      // データ放送からのチャンネル切り替えは未対応 (切り替えられないことを伝える)
      epg: {
        tune: () => false,
      },
      ip: this.makeInternetAccess(),
      showErrorMessage: (title: string, message: string, code?: string) => {
        this.bridge.error(title, message, code)
        this.setState('error')
      },
    })
    this.browser = browser

    // フォントは先に読み込んでおく (画面のチラつき防止, Web 版と同じ)
    for (const font of (browser as unknown as { fonts?: FontFace[] }).fonts ?? []) {
      font.load().catch(() => {})
    }

    browser.addEventListener('load', (event) => {
      const resolution = event.detail.resolution
      this.bmlWidth = resolution.width
      this.bmlHeight = resolution.height
      this.applyScale()
      this.setState(this.isVisible ? 'ready' : 'invisible')
      this.reportVideoRect()
    })

    browser.addEventListener('invisible', (event) => {
      // BML のコンテンツ自身が表示/非表示を切り替えた
      this.isVisible = event.detail !== true
      if (this.container != null) {
        this.container.style.visibility = this.isVisible ? 'visible' : 'hidden'
      }
      this.setState(this.isVisible ? 'visible' : 'invisible')
      this.reportVideoRect()
    })

    browser.addEventListener('videochanged', () => {
      this.reportVideoRect()
    })

    browser.addEventListener('usedkeylistchanged', (event) => {
      this.bridge.usedKeys(event.detail.usedKeyList)
    })
  }

  /**
   * 双方向 (ネット接続) 機能。
   *
   * Web 版と同じく、実際の HTTP リクエストは KonomiTV サーバーの
   * プロキシ API (/api/data-broadcasting/...) 経由で送る。ページからは
   * カスタムスキームの同じ API を fetch するだけで、認証と中継はネイティブが
   * 行う。
   */
  private makeInternetAccess() {
    const apiBase = this.config.apiBase
    const enabled = (): boolean => this.config.internetAccess
    const request = async (method: 'GET' | 'POST', uri: string, body?: Uint8Array) => {
      const response = await fetch(`${apiBase}/data-broadcasting/request/${uri}`, {
        method,
        headers: body == null ? {} : { 'Content-Type': 'application/x-www-form-urlencoded' },
        body: body as BodyInit | undefined,
      })
      const responseBody = new Uint8Array(await response.arrayBuffer())
      return { statusCode: response.status, headers: response.headers, response: responseBody }
    }

    return {
      // ARIB STD-B24 第二分冊 (2/2) 第二編 付属3 5.6.5.2 表5-12: 403 = Ethernet (DHCP)
      getConnectionType(): number {
        return 403
      },
      // 表5-14: 1 = IP 接続は自動接続によって確立している / 0 = 確立していない
      isIPConnected(): number {
        return enabled() ? 1 : 0
      },
      async get(uri: string) {
        if (!enabled()) {
          return {}
        }
        try {
          const result = await request('GET', uri)
          return {
            statusCode: result.statusCode,
            headers: result.headers,
            response: result.response,
          }
        } catch {
          return {}
        }
      },
      async transmitTextDataOverIP(uri: string, body: Uint8Array) {
        if (!enabled()) {
          return { resultCode: NaN, statusCode: '', response: new Uint8Array(0) }
        }
        try {
          // Denbun というキー名でフォーム送信する (Web 版と同じ)
          const form = new URLSearchParams()
          form.set('Denbun', new TextDecoder().decode(body))
          const result = await request('POST', uri, new TextEncoder().encode(form.toString()))
          return {
            resultCode: 1,
            statusCode: result.statusCode.toString(),
            response: result.response,
          }
        } catch {
          return { resultCode: NaN, statusCode: '', response: new Uint8Array(0) }
        }
      },
      async confirmIPNetwork(destination: string, isICMP: boolean, timeoutMillis: number) {
        if (!enabled()) {
          return null
        }
        const query = new URLSearchParams({
          destination,
          is_icmp: isICMP ? 'true' : 'false',
          timeout_milliseconds: timeoutMillis.toString(),
        })
        try {
          const response = await fetch(`${apiBase}/data-broadcasting/internet-status?${query.toString()}`)
          if (!response.ok) {
            return null
          }
          const status = await response.json() as {
            success: boolean
            ip_address: string | null
            response_time_milliseconds: number | null
          }
          return {
            success: status.success,
            ipAddress: status.ip_address,
            responseTimeMillis: status.response_time_milliseconds,
          }
        } catch {
          return null
        }
      },
    }
  }

  // MARK: - レイアウト

  /**
   * BML 画面の拡大/縮小率を計算してコンテナに適用する。
   * 高さは BML ブラウザの高さに合わせ、横幅は常に 16:9 になるようにする
   * (Web 版 calculateBMLBrowserScaleFactor() と同じ)。
   */
  private applyScale(): void {
    const element = this.scaleElement
    if (element == null) {
      return
    }
    const scaleFactorWidth = this.pageSize.width / (this.bmlHeight * 16 / 9)
    const scaleFactorHeight = this.pageSize.height / this.bmlHeight
    const scaleFactor = Math.min(scaleFactorWidth, scaleFactorHeight)
    const magnification = (this.bmlHeight * 16 / 9) / this.bmlWidth

    element.style.width = `${this.bmlWidth}px`
    element.style.height = `${this.bmlHeight}px`
    element.style.transform = `translate(-50%, -50%) scale(${scaleFactor * magnification}, ${scaleFactor})`
  }

  /** 映像プレーンの矩形をネイティブに伝える (ページの CSS px)。 */
  private reportVideoRect(): void {
    const element = this.isVisible ? this.browser?.getVideoElement() ?? null : null
    if (element == null) {
      this.bridge.videoRect(null, this.pageSize)
      return
    }
    const rect = element.getBoundingClientRect()
    if (!(rect.width >= 1 && rect.height >= 1)) {
      this.bridge.videoRect(null, this.pageSize)
      return
    }
    this.bridge.videoRect(
      { left: rect.left, top: rect.top, width: rect.width, height: rect.height },
      this.pageSize,
    )
  }

  // MARK: - PSI/SI アーカイブデータ

  private startPSI(): void {
    const url = `${this.config.apiBase}/streams/live/${encodeURIComponent(this.config.channelId)}`
      + `/${encodeURIComponent(this.config.quality)}/psi-archived-data`
    const controller = new AbortController()
    this.psiRequest = controller

    const tsStream = decodeTS({
      sendCallback: (message) => this.onTSMessage(message),
      serviceId: this.config.serviceId,
      // ARIB 字幕はアプリ側 (libaribcaption) が描くので PES は解析しない
      parsePES: false,
    }) as unknown as TSReaderLike
    this.tsStream = tsStream
    tsStream.addEventListener('eit', ({ pid, section }) => {
      // PID 0x12 / table_id 0x4e (EIT[p/f]) のみ
      if (pid !== 0x12 || section.tableIdNumber !== 0x4e) {
        return
      }
      const result = buildProgramPF(section, {
        networkId: this.config.networkId,
        serviceId: this.config.serviceId,
      })
      if (result == null) {
        return
      }
      this.bridge.programPF(result.presentOrFollowing, result.program)
    })

    // ライブ PSI/SI アーカイブデータストリーミング API (エンドレス)
    fetch(url, { signal: controller.signal }).then(async (response) => {
      if (!response.ok || response.body == null) {
        this.bridge.error('データ放送', `PSI/SI アーカイブデータを取得できませんでした。(HTTP ${response.status})`, 'E300')
        this.setState('error')
        return
      }
      const reader = response.body.getReader()
      let lastPCR = -1
      for (;;) {
        const result = await reader.read()
        if (controller.signal.aborted) {
          return
        }
        if (result.done) {
          break
        }
        this.parser.push(result.value, (second, packets, pid) => {
          const pcr = Math.floor(second * 90000)
          if (lastPCR !== pcr) {
            this.browser?.emitMessage({ type: 'pcr', pcrBase: pcr, pcrExtension: 0 })
            lastPCR = pcr
          }
          this.packetWriter.setHeader(packets, pid)
          this.tsStream?.push(packets)
        })
      }
    }).catch(() => {
      // abort や通信断は何もしない
    }).finally(() => {
      if (this.tsStream === tsStream) {
        tsStream.close()
        this.tsStream = null
      }
    })
  }

  /** デコード結果を BML ブラウザに送る。 */
  private onTSMessage(message: { type: string, components?: { bxmlInfo?: unknown }[] }): void {
    if (this.browser == null) {
      return
    }
    if (message.type === 'pmt') {
      // AdditionalAribBXMLInfo を含むコンポーネントがあればデータ放送あり
      const available = (message.components ?? []).some((component) => component.bxmlInfo !== undefined)
      if (!available) {
        this.setState('unavailable')
      }
    }
    this.browser.emitMessage(message as never)
  }

  private setState(state: string): void {
    if (this.lastReportedState === state) {
      return
    }
    this.lastReportedState = state
    this.bridge.state(state as never)
  }
}
