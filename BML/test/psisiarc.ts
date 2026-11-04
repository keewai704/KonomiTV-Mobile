/**
 * テスト用の psisiarc エンコーダ。
 *
 * MockServer/data_broadcasting_mock.py の encode_psi_archived_data() と
 * 同じ形式で 1 チャンクを組み立てる (すべてのセクションを新規エントリとして
 * 辞書に載せ、コードリストで全部を送出する)。
 */

import { TIME_UNITS_PER_SECOND } from '../src/psi.ts'

export type SectionEntry = { pid: number, section: Uint8Array }

export function encodeChunk(sections: SectionEntry[], currentTimeSeconds: number): Uint8Array {
  const count = sections.length
  const dictionaryDataSize = sections.reduce((total, entry) => total + entry.section.length, 0)
  const paddedDataSize = dictionaryDataSize + (dictionaryDataSize % 2)
  const timeListLen = 2
  const dictionaryLen = count
  const codeListLen = count
  const chunkSize = 32 + timeListLen * 4 + dictionaryLen * 2 + paddedDataSize + codeListLen * 2
  const trailerSize = 2 + (2 + chunkSize) % 4

  const out: number[] = []
  const u16 = (value: number) => out.push(value & 0xff, (value >> 8) & 0xff)
  const u32 = (value: number) => out.push(value & 0xff, (value >> 8) & 0xff, (value >> 16) & 0xff, (value >> 24) & 0xff)

  u32(0x50737363)
  u32(0x0d0a9a0a)
  u16(0) // 予約
  u16(timeListLen)
  u16(dictionaryLen)
  u16(dictionaryLen)
  u32(dictionaryDataSize)
  u32(dictionaryDataSize)
  u32(codeListLen)
  u32(0) // 予約 (32 バイトのヘッダの残り)

  // タイムリスト: 絶対時刻 + (差分 0, コード数 - 1)
  u32(0x80000000 | (Math.floor(currentTimeSeconds * TIME_UNITS_PER_SECOND) & 0x3fffffff))
  u16(0)
  u16(count - 1)

  for (const entry of sections) {
    u16(entry.section.length - 1)
  }
  for (const entry of sections) {
    u16(entry.pid & 0x1fff)
  }
  for (const entry of sections) {
    out.push(...entry.section)
  }
  if (dictionaryDataSize % 2) {
    out.push(0)
  }
  for (let index = 0; index < count; index++) {
    u16(4096 + index)
  }
  for (let index = 0; index < trailerSize; index++) {
    out.push(0)
  }
  return new Uint8Array(out)
}
