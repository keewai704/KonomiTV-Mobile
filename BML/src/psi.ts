/**
 * PSI/SI アーカイブデータ (psisiarc) の読み取り。
 *
 * KonomiTV のライブ PSI/SI アーカイブデータストリーミング API は、PSI/SI の
 * セクションを EDCB の psisiarc 形式で流し続ける。ここでは Web クライアントの
 * LivePSIArchivedDataDecoder.ts (EDCB Legacy WebUI の util.lua / script.js の
 * 移植) と同じ手順で、届いたチャンクからヘッダなしの TS パケット列を作る。
 *
 * 形式:
 *   32 バイトのヘッダ (マジック "Pssc\r\n\x9a\n"、各リストの長さ)
 *   タイムリスト (4 バイト × time_list_len): 絶対時刻 + (差分, コード数 - 1)
 *   辞書 (新規セクションは 4 バイト、再利用は 2 バイト)
 *   セクション本体 (偶数バイト境界までパディング)
 *   コードリスト (辞書のインデックス + 4096)
 *   4 バイト境界までのトレーラー
 */

/**
 * チャンクの先頭のマジック "Pssc\r\n\x9a\n" (psisiarc の Readme の
 * 「マジックナンバー: Pssc\x0d\x0a\x9a\x0a」)。
 *
 * ここだけはバイト列をそのまま比べる。psisiarc はこの 8 バイトをそのまま
 * 書く (ASCII の "Pssc" と 0x0d 0x0a 0x9a 0x0a) のに対し、公式の読み取り
 * (EDCB の script.js、KonomiTV の LivePSIArchivedDataDecoder.ts) は他の
 * フィールドと違ってこの 8 バイトだけビッグエンディアンで読んで
 * 0x50737363 / 0x0d0a9a0a と比べている。リトルエンディアンで読むと実放送の
 * 書庫はマジックが一致せず、どのチャンクも読めなくなる。
 */
const MAGIC_BYTES = [0x50, 0x73, 0x73, 0x63, 0x0d, 0x0a, 0x9a, 0x0a]
/** タイムリストの 1 秒あたりの単位 */
export const TIME_UNITS_PER_SECOND = 11250

type ParserContext = {
  pids: number[]
  /** セクションを並べた TS パケット列 (辞書のエントリごと) */
  sections: (Uint8Array | null)[]
  position: number
  trailerSize: number
  timeListCount: number
  codeListPosition: number
  codeCount: number
  initTime: number
  currTime: number
}

function createContext(): ParserContext {
  return {
    pids: [],
    sections: [],
    position: 0,
    trailerSize: 0,
    timeListCount: -1,
    codeListPosition: 0,
    codeCount: 0,
    initTime: -1,
    currTime: -1,
  }
}

/** チャンクがまだ途中で切れている (続きの到着を待つ) */
class IncompleteDataError extends Error {}

export type PSISectionCallback = (second: number, packets: Uint8Array, pid: number) => void

/**
 * psisiarc のストリームを読み、届いた順にセクションの TS パケット列を返す。
 *
 * 1 回の push で複数のチャンク・不完全なチャンクのどちらが来てもよい。
 */
export class PSIArchivedDataParser {
  private context: ParserContext = createContext()
  private pending: Uint8Array<ArrayBufferLike> = new Uint8Array(0)
  private droppedChunkCount = 0

  /**
   * 壊れたチャンクを捨てた回数。
   *
   * 実放送のアーカイブは psisiarc のプロセスが入れ替わったり (API リクエストの
   * 都度起動される)、配信が途切れたりして、チャンクの繋ぎ目が壊れることがある。
   * その場合は次のマジックまで読み飛ばして読み続ける (捨てたまま何も届かないと
   * ページは loading のまま止まってしまう)。
   */
  get droppedChunks(): number {
    return this.droppedChunkCount
  }

  /** 受信済みのデータをすべて捨てる。 */
  reset(): void {
    this.context = createContext()
    this.pending = new Uint8Array(0)
    this.droppedChunkCount = 0
  }

  /** 受信したチャンクを読み、完成したセクションを callback に渡す。 */
  push(chunk: Uint8Array, callback: PSISectionCallback): void {
    if (chunk.length === 0) {
      return
    }
    const data = new Uint8Array(this.pending.length + chunk.length)
    data.set(this.pending)
    data.set(chunk, this.pending.length)
    this.pending = this.read(data, callback)
  }

  private read(data: Uint8Array, callback: PSISectionCallback): Uint8Array<ArrayBufferLike> {
    const view = new DataView(data.buffer, data.byteOffset, data.byteLength)

    while (data.byteLength - this.context.position >= this.context.trailerSize + 32) {
      // 途中で切れたチャンクは何も反映せずに持ち越す
      const context = this.context
      const snapshot: ParserContext = {
        ...context,
        pids: context.pids.slice(),
        sections: context.sections.slice(),
      }
      try {
        if (!this.readChunk(view, data, callback)) {
          // 壊れたチャンク: 辞書ごと捨てて、次のチャンクの先頭まで読み飛ばす
          // (必ず 1 バイト以上進む。同じ位置で失敗し続けると止まらない)
          this.resynchronize(data, context.position + context.trailerSize + 1)
          if (this.context.position >= data.byteLength) {
            break
          }
        }
      } catch (error) {
        this.context = snapshot
        if (error instanceof IncompleteDataError) {
          break
        }
        throw error
      }
    }

    // まだ読めていない末尾 (前のチャンクのトレーラーを含む) は次回に持ち越す
    const rest = new Uint8Array(data.subarray(this.context.position))
    this.context.position = 0
    return rest
  }

  /**
   * 壊れたチャンクを捨て、次のチャンクの先頭 (マジック) まで進める。
   *
   * 見つからなければ残りをすべて捨てる (次の push で継ぎ足して探し直す)。
   */
  private resynchronize(data: Uint8Array, from: number): void {
    this.context = createContext()
    for (let index = Math.max(from, 1); index + MAGIC_BYTES.length <= data.byteLength; index++) {
      let matched = true
      for (let offset = 0; offset < MAGIC_BYTES.length; offset++) {
        if (data[index + offset] !== MAGIC_BYTES[offset]) {
          matched = false
          break
        }
      }
      if (matched) {
        // 次のチャンクの先頭が見つかった: そこまでを捨てたことにする
        this.droppedChunkCount += 1
        this.context.position = index
        return
      }
    }
    // まだ見つからない: ここまでのデータを捨てて、次の push で探し直す
    this.context.position = data.byteLength
  }

  /**
   * 1 チャンクを読む。
   *
   * 途中で切れていれば IncompleteDataError を投げ、壊れていれば false を返す
   * (呼び出し側が次のチャンクまで読み飛ばす)。
   */
  private readChunk(view: DataView, data: Uint8Array, callback: PSISectionCallback): boolean {
    const context = this.context
    let position = context.position + context.trailerSize

    const timeListLen = readU16(view, data, position + 10)
    const dictionaryLen = readU16(view, data, position + 12)
    const dictionaryWindowLen = readU16(view, data, position + 14)
    const dictionaryDataSize = readU32(view, data, position + 16)
    const dictionaryBufferSize = readU32(view, data, position + 20)
    const codeListLen = readU32(view, data, position + 24)

    if (
      !hasMagic(data, position)
      || dictionaryWindowLen < dictionaryLen
      || dictionaryBufferSize < dictionaryDataSize
      || dictionaryWindowLen > 65536 - 4096
    ) {
      // 壊れたデータ: 呼び出し側が次のチャンクまで読み飛ばす
      return false
    }

    // 辞書と本体のぶん (新規エントリは PID の 2 バイトが増える)
    const chunkSize = 32 + timeListLen * 4 + dictionaryLen * 2
      + Math.ceil(dictionaryDataSize / 2) * 2 + codeListLen * 2
    if (data.byteLength - position < chunkSize) {
      throw new IncompleteDataError()
    }

    let timeListPosition = position + 32
    position += 32 + timeListLen * 4

    if (context.timeListCount < 0) {
      // 辞書。このチャンクの辞書は新しい配列に作る。値が 4096 以上の
      // エントリは前回の辞書 (previousPids) の ID を参照し、参照したものは
      // 前回の辞書に -1 で印を付ける。続けて前回の辞書のうち未参照のものを
      // 辞書ウィンドウ長まで引き継ぐ (psisiarc の Readme の「辞書」)。
      // 前回の辞書を書き換えながら読むと、再利用のあるチャンク (実際の
      // 放送では 2 チャンク目以降のほぼすべて) を読めない
      const previousPids = context.pids
      const previousSections = context.sections
      const pids: number[] = []
      const sections: (Uint8Array | null)[] = []
      let sectionListPosition = 0

      for (let index = 0; index < dictionaryLen; index++, position += 2) {
        const codeOrSize = readU16(view, data, position) - 4096
        if (codeOrSize >= 0) {
          if (codeOrSize >= previousPids.length || previousPids[codeOrSize] < 0) {
            // 前回の辞書にないエントリを参照している (psisiarc が入れ替わった)
            return false
          }
          pids[index] = previousPids[codeOrSize]
          sections[index] = previousSections[codeOrSize]
          previousPids[codeOrSize] = -1
        } else {
          pids[index] = codeOrSize
          sections[index] = null
          sectionListPosition += 2
        }
      }
      sectionListPosition += position

      for (let index = 0; index < dictionaryLen; index++) {
        if (pids[index] >= 0) {
          continue
        }
        const sectionLength = pids[index] + 4097
        if (sectionListPosition + sectionLength > data.byteLength) {
          throw new IncompleteDataError()
        }
        const section = data.subarray(sectionListPosition, sectionListPosition + sectionLength)
        // セクションを TS パケットのペイロードに詰める
        // (先頭パケットの最初のバイトはポインタフィールド 0)
        const packets = new Uint8Array(Math.ceil((section.length + 1) / 184) * 188)
        for (let j = 0, k = 0; k < section.length; j++, k++) {
          if (!(j % 188)) {
            j += 4
            if (!k) {
              packets[j++] = 0
            }
          }
          packets[j] = section[k]
        }
        sections[index] = packets
        sectionListPosition += sectionLength
        pids[index] = readU16(view, data, position) & 0x1fff
        position += 2
      }

      // 辞書ウィンドウの残りは前回の辞書の未参照のエントリを順に引き継ぐ
      for (let windowIndex = dictionaryLen, previous = 0; windowIndex < dictionaryWindowLen; previous++) {
        if (previous >= previousPids.length) {
          // 辞書ウィンドウを前回の辞書から復元できない
          return false
        }
        if (previousPids[previous] < 0) {
          continue
        }
        pids[windowIndex] = previousPids[previous]
        sections[windowIndex] = previousSections[previous]
        windowIndex++
      }

      context.pids = pids
      context.sections = sections
      context.timeListCount = 0
      position = sectionListPosition + (dictionaryDataSize % 2)
    } else {
      position += dictionaryLen * 2 + Math.ceil(dictionaryDataSize / 2) * 2
    }

    // コードリストまで届いていなければ、このチャンクはまだ処理しない
    if (position + codeListLen * 2 > data.byteLength) {
      throw new IncompleteDataError()
    }

    position += context.codeListPosition
    timeListPosition += context.timeListCount * 4
    for (; context.timeListCount < timeListLen; context.timeListCount++, timeListPosition += 4) {
      const absTime = readU32(view, data, timeListPosition)
      if (absTime === 0xffffffff) {
        context.currTime = -1
      } else if (absTime >= 0x80000000) {
        context.currTime = absTime & 0x3fffffff
        if (context.initTime < 0) {
          context.initTime = context.currTime
        }
      } else {
        const codeCount = readU16(view, data, timeListPosition + 2) + 1
        if (context.currTime >= 0) {
          context.currTime += readU16(view, data, timeListPosition)
          const second = ((context.currTime + 0x40000000 - context.initTime) & 0x3fffffff)
            / TIME_UNITS_PER_SECOND
          for (; context.codeCount < codeCount; context.codeCount++, position += 2, context.codeListPosition += 2) {
            const code = readU16(view, data, position) - 4096
            const packets = context.sections[code]
            const pid = context.pids[code]
            if (packets == null || pid == null) {
              // 辞書にないコード (壊れたコードリスト)
              return false
            }
            callback(second, packets, pid)
          }
          context.codeCount = 0
        } else {
          position += codeCount * 2
          context.codeListPosition += codeCount * 2
        }
      }
    }

    context.position = position
    context.trailerSize = 2 + (2 + chunkSize) % 4
    context.timeListCount = -1
    context.codeListPosition = 0
    context.currTime = -1
    return true
  }
}

/** position にチャンクのマジックがあるか。 */
function hasMagic(data: Uint8Array, position: number): boolean {
  if (position + MAGIC_BYTES.length > data.byteLength) {
    throw new IncompleteDataError()
  }
  for (let offset = 0; offset < MAGIC_BYTES.length; offset++) {
    if (data[position + offset] !== MAGIC_BYTES[offset]) {
      return false
    }
  }
  return true
}

function readU16(view: DataView, data: Uint8Array, position: number): number {
  if (position + 2 > data.byteLength) {
    throw new IncompleteDataError()
  }
  return view.getUint16(position, true)
}

function readU32(view: DataView, data: Uint8Array, position: number): number {
  if (position + 4 > data.byteLength) {
    throw new IncompleteDataError()
  }
  return view.getUint32(position, true)
}

/** ヘッダなしの TS パケットにヘッダ (PID と CC) を付ける。 */
export class TSPacketWriter {
  private counters: { [pid: number]: number } = {}

  reset(): void {
    this.counters = {}
  }

  /** packets をその場で書き換える。 */
  setHeader(packets: Uint8Array, pid: number): void {
    if (this.counters[pid] === undefined) {
      this.counters[pid] = 0
    }
    for (let index = 0; index < packets.length; index += 188) {
      packets[index] = 0x47
      packets[index + 1] = (index > 0 ? 0 : 0x40) | (pid >> 8)
      packets[index + 2] = pid & 0xff
      packets[index + 3] = 0x10 | this.counters[pid]
      this.counters[pid] = (this.counters[pid] + 1) & 0x0f
    }
  }
}
