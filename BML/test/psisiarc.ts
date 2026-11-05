/**
 * テスト用の psisiarc エンコーダ。
 *
 * MockServer/data_broadcasting_mock.py の PSIArchiveEncoder と同じく、
 * psisiarc (psiarchiver.cpp) の形式でチャンクを組み立てる。前回のチャンクの
 * 辞書にあるセクションは辞書 ID (4096 以上) で参照し、参照しなかった前回の
 * エントリは辞書ウィンドウに引き継ぐ。
 */

import { TIME_UNITS_PER_SECOND } from '../src/psi.ts'

export type SectionEntry = { pid: number, section: Uint8Array }

function sameEntry(a: SectionEntry, b: SectionEntry): boolean {
  return a.pid === b.pid
    && a.section.length === b.section.length
    && a.section.every((value, index) => value === b.section[index])
}

export class ArchiveEncoder {
  /** 前回のチャンクの辞書 (辞書 ID 4096 + index の順) */
  private window: SectionEntry[] = []

  /** (PID, セクション) の列を 1 チャンクにする。コードリストは渡された順。 */
  encode(sections: SectionEntry[], currentTimeSeconds: number): Uint8Array {
    const current: SectionEntry[] = []
    for (const entry of sections) {
      if (!current.some((other) => sameEntry(other, entry))) {
        current.push(entry)
      }
    }

    const dictionary: number[] = []
    const newEntries: SectionEntry[] = []
    const referenced = new Set<number>()
    for (const entry of current) {
      const index = this.window.findIndex((old, i) => !referenced.has(i) && sameEntry(old, entry))
      if (index < 0) {
        dictionary.push(entry.section.length - 1)
        newEntries.push(entry)
      } else {
        dictionary.push(4096 + index)
        referenced.add(index)
      }
    }
    const window = current.concat(this.window.filter((_, index) => !referenced.has(index)))

    // 辞書データサイズは PID リストとセクション集合のバイト数の和
    const dictionaryDataSize = newEntries.reduce((total, entry) => total + 2 + entry.section.length, 0)
    const dictionaryBufferSize = window.reduce((total, entry) => total + 2 + entry.section.length, 0)
    const timeListLen = 2
    const codeListLen = sections.length

    const out: number[] = []
    const u16 = (value: number) => out.push(value & 0xff, (value >> 8) & 0xff)
    const u32 = (value: number) => out.push(value & 0xff, (value >> 8) & 0xff, (value >> 16) & 0xff, (value >>> 24) & 0xff)

    u32(0x50737363)
    u32(0x0d0a9a0a)
    u16(0) // 予約
    u16(timeListLen)
    u16(dictionary.length)
    u16(window.length)
    u32(dictionaryDataSize)
    u32(dictionaryBufferSize)
    u32(codeListLen)
    u32(0) // 予約 (32 バイトのヘッダの残り)

    // タイムリスト: 絶対時刻 + (差分 0, コード数 - 1)
    u32(0x80000000 | (Math.floor(currentTimeSeconds * TIME_UNITS_PER_SECOND) & 0x3fffffff))
    u16(0)
    u16(codeListLen - 1)

    for (const value of dictionary) {
      u16(value)
    }
    for (const entry of newEntries) {
      u16(0xe000 | (entry.pid & 0x1fff))
    }
    for (const entry of newEntries) {
      out.push(...entry.section)
    }
    if (dictionaryDataSize % 2) {
      out.push(0xff)
    }
    for (const entry of sections) {
      u16(4096 + current.findIndex((other) => sameEntry(other, entry)))
    }
    // トレーラー: データ部分が 4 の倍数なら "====" 、それ以外は "=="
    const trailer = (out.length - 32) % 4 === 0 ? 4 : 2
    for (let index = 0; index < trailer; index++) {
      out.push(0x3d)
    }

    this.window = window
    return new Uint8Array(out)
  }
}

/** 前回の辞書のない 1 チャンク (すべてのセクションが新規エントリ)。 */
export function encodeChunk(sections: SectionEntry[], currentTimeSeconds: number): Uint8Array {
  return new ArchiveEncoder().encode(sections, currentTimeSeconds)
}
