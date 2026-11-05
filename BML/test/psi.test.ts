import assert from 'node:assert/strict'
import test from 'node:test'

import { PSIArchivedDataParser, TSPacketWriter } from '../src/psi.ts'
import { ArchiveEncoder, encodeChunk } from './psisiarc.ts'

/** 18 バイトのダミーセクション (中身は問わない) */
function section(length: number, seed: number): Uint8Array {
  const value = new Uint8Array(length)
  for (let index = 0; index < length; index++) {
    value[index] = (seed + index) & 0xff
  }
  return value
}

function readSections(data: Uint8Array): { second: number, pid: number, packets: Uint8Array }[] {
  const parser = new PSIArchivedDataParser()
  const writer = new TSPacketWriter()
  const result: { second: number, pid: number, packets: Uint8Array }[] = []
  parser.push(data, (second, packets, pid) => {
    writer.setHeader(packets, pid)
    result.push({ second, pid, packets: packets.slice() })
  })
  return result
}

test('parses one chunk of new sections', () => {
  const sections = [
    { pid: 0x0000, section: section(16, 1) },
    { pid: 0x1000, section: section(52, 2) },
    { pid: 0x0012, section: section(78, 3) },
  ]
  const decoded = readSections(encodeChunk(sections, 0))
  assert.equal(decoded.length, 3)
  assert.deepEqual(decoded.map((entry) => entry.pid), [0x0000, 0x1000, 0x0012])
  // セクションは TS パケットのペイロード (ポインタフィールドの後ろ) に入る
  for (const [index, entry] of decoded.entries()) {
    const packets = entry.packets
    assert.equal(packets.length % 188, 0)
    assert.equal(packets[0], 0x47)
    assert.equal(((packets[1] & 0x1f) << 8) | packets[2], sections[index].pid)
    assert.equal(packets[1] & 0x40, 0x40)
    assert.equal(packets[4], 0) // ポインタフィールド
    assert.deepEqual(
      packets.slice(5, 5 + sections[index].section.length),
      sections[index].section,
    )
  }
})

test('splits a long section over multiple TS packets', () => {
  const long = section(300, 9)
  const decoded = readSections(encodeChunk([{ pid: 0x0120, section: long }], 0))
  assert.equal(decoded.length, 1)
  assert.equal(decoded[0].packets.length, 2 * 188)
  // 1 パケット目はヘッダ (4 バイト) とポインタフィールド (1 バイト) の後ろ、
  // 2 パケット目はヘッダの後ろがそのままセクションの続きになる
  const payload = new Uint8Array(184 * 2)
  payload.set(decoded[0].packets.slice(5, 188), 0)
  payload.set(decoded[0].packets.slice(188 + 4, 188 + 4 + (long.length - 183)), 183)
  assert.deepEqual(payload.slice(0, long.length), long)
})

test('carries the second counter', () => {
  const decoded = readSections(encodeChunk([{ pid: 0x0011, section: section(20, 1) }], 0))
  assert.equal(decoded[0].packets[3] & 0x0f, 0)
})

test('parses several chunks in one push and reports the stream time', () => {
  const sections = [
    { pid: 0x0000, section: section(16, 1) },
    { pid: 0x0014, section: section(14, 2) },
  ]
  const data = new Uint8Array(encodeChunk(sections, 10).length * 3)
  data.set(encodeChunk(sections, 10), 0)
  data.set(encodeChunk(sections, 11), encodeChunk(sections, 10).length)
  data.set(encodeChunk(sections, 12), encodeChunk(sections, 10).length * 2)
  const decoded = readSections(data)
  assert.equal(decoded.length, 6)
  // 最初のチャンクが基準時刻 (0 秒) になり、以降は経過秒になる
  assert.deepEqual([...new Set(decoded.map((entry) => entry.second))], [0, 1, 2])
})

test('waits for the rest of a chunk and decodes it after the next push', () => {
  const sections = [
    { pid: 0x0000, section: section(16, 1) },
    { pid: 0x0011, section: section(48, 2) },
  ]
  const chunk = encodeChunk(sections, 0)
  const parser = new PSIArchivedDataParser()
  const decoded: number[] = []
  // 1 バイトずつ流しても、最後にちょうど 2 セクションになる
  for (const byte of chunk) {
    parser.push(new Uint8Array([byte]), (_second, _packets, pid) => decoded.push(pid))
  }
  assert.deepEqual(decoded, [0x0000, 0x0011])
})

test('reads chunks that reuse the previous dictionary', () => {
  // psisiarc refers to sections of the previous chunk by their dictionary ID
  // and carries the ones it did not refer to on, as a live archive does from
  // its second chunk on.
  const pat = { pid: 0x0000, section: section(16, 1) }
  const pmt = { pid: 0x1000, section: section(52, 2) }
  const tot = { pid: 0x0014, section: section(9, 3) }
  const encoder = new ArchiveEncoder()
  const first = encoder.encode([pat, pmt], 0)
  const second = encoder.encode([tot], 1)
  // pat and pmt are carried at window IDs 1 and 2 now
  const third = encoder.encode([pmt, pat, tot], 2)

  const decoded = readSections(new Uint8Array([...first, ...second, ...third]))
  assert.deepEqual(decoded.map((entry) => entry.pid), [0x0000, 0x1000, 0x0014, 0x1000, 0x0000, 0x0014])
  // The reused entries still hold their own sections (payload after the
  // 4 byte header and the pointer field).
  assert.deepEqual(decoded[3].packets.subarray(5, 5 + 52), pmt.section)
  assert.deepEqual(decoded[4].packets.subarray(5, 5 + 16), pat.section)
  assert.deepEqual(decoded[5].packets.subarray(5, 5 + 9), tot.section)
})

test('reads a reused dictionary across pushes', () => {
  const pat = { pid: 0x0000, section: section(16, 1) }
  const sdt = { pid: 0x0011, section: section(40, 4) }
  const encoder = new ArchiveEncoder()
  const data = new Uint8Array([
    ...encoder.encode([pat, sdt], 0),
    ...encoder.encode([sdt, pat], 1),
    ...encoder.encode([pat], 2),
  ])
  const parser = new PSIArchivedDataParser()
  const decoded: number[] = []
  for (let offset = 0; offset < data.length; offset += 7) {
    parser.push(data.subarray(offset, offset + 7), (_second, _packets, pid) => decoded.push(pid))
  }
  assert.deepEqual(decoded, [0x0000, 0x0011, 0x0011, 0x0000, 0x0000])
})

test('drops the stream when the magic is broken', () => {
  const broken = encodeChunk([{ pid: 0x0000, section: section(16, 1) }], 0)
  broken[0] = 0
  assert.deepEqual(readSections(broken), [])
})

test('TS packet writer sets PID, payload unit start and continuity counter', () => {
  const writer = new TSPacketWriter()
  const packets = new Uint8Array(188 * 3)
  writer.setHeader(packets, 0x0120)
  assert.equal(packets[0], 0x47)
  assert.equal(((packets[1] & 0x1f) << 8) | packets[2], 0x0120)
  assert.equal(packets[1] & 0x40, 0x40)
  assert.equal(packets[3] & 0x0f, 0)
  assert.equal(packets[3] & 0x30, 0x10)
  assert.equal(packets[188 + 1] & 0x40, 0)
  assert.equal(packets[188 + 3] & 0x0f, 1)
  assert.equal(packets[376 + 3] & 0x0f, 2)
  // 次の呼び出しでは続きのカウンタ
  writer.setHeader(packets, 0x0120)
  assert.equal(packets[3] & 0x0f, 3)
  // 別の PID は独立したカウンタ
  writer.setHeader(packets, 0x0011)
  assert.equal(packets[3] & 0x0f, 0)
})
