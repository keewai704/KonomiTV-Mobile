import assert from 'node:assert/strict'
import test from 'node:test'

import { buildProgramPF, mjdBCDToUnixSeconds } from '../src/program.ts'
import type { EITSection } from '../src/program.ts'

const CHANNEL = { networkId: 32736, serviceId: 1024 }

/** 2026-01-01T12:00:00+09:00 */
const START_UNIX = 1767236400

function mjdBCD(unixSeconds: number): number {
  const jst = new Date((unixSeconds + 9 * 3600) * 1000)
  const mjd = Math.floor((unixSeconds + 9 * 3600) / 86400) + 40587
  const hour = jst.getUTCHours()
  const minute = jst.getUTCMinutes()
  const second = jst.getUTCSeconds()
  const bcd = ((hour / 10 | 0) << 20) | ((hour % 10) << 16)
    | ((minute / 10 | 0) << 12) | ((minute % 10) << 8)
    | ((second / 10 | 0) << 4) | (second % 10)
  return mjd * 0x1000000 + bcd
}

function section(overrides: Partial<EITSection> = {}): EITSection {
  return {
    serviceId: 1024,
    originalNetworkId: 32736,
    currentNextIndicator: true,
    sectionNumber: 0,
    events: [{
      eventId: 100,
      startTime: mjdBCD(START_UNIX),
      duration: (1 << 16), // 01:00:00 (BCD: 時 0-1, 分 0-0, 秒 0-0)
      freeCAMode: false,
      // ARIB の漢字集合 (7 ビット) で「モ」
      descriptors: [{ tag: 'shortEvent', eventName: new Uint8Array([0x25, 0x62]) }],
    }],
    ...overrides,
  }
}

test('MJDBcdToUnixSeconds decodes the JST start time', () => {
  assert.equal(mjdBCDToUnixSeconds(mjdBCD(START_UNIX)), START_UNIX)
})

test('builds the present program from EIT[p/f]', () => {
  const result = buildProgramPF(section(), CHANNEL)
  assert.ok(result)
  assert.equal(result.presentOrFollowing, 'Present')
  assert.equal(result.program.id, 'NID32736-SID1024-EID100')
  assert.equal(result.program.channel_id, 'NID32736-SID1024')
  assert.equal(result.program.event_id, 100)
  assert.equal(result.program.title, 'モ')
  assert.equal(result.program.start_time, new Date(START_UNIX * 1000).toISOString())
  assert.equal(result.program.duration, 3600)
  assert.equal(result.program.end_time, new Date((START_UNIX + 3600) * 1000).toISOString())
  assert.equal(result.program.is_free, true)
})

test('the following program comes from section number 1', () => {
  const result = buildProgramPF(section({ sectionNumber: 1 }), CHANNEL)
  assert.ok(result)
  assert.equal(result.presentOrFollowing, 'Following')
})

test('ignores other channels, invalid EITs and other sections', () => {
  assert.equal(buildProgramPF(section({ serviceId: 1025 }), CHANNEL), null)
  assert.equal(buildProgramPF(section({ originalNetworkId: 1 }), CHANNEL), null)
  assert.equal(buildProgramPF(section({ currentNextIndicator: false }), CHANNEL), null)
  assert.equal(buildProgramPF(section({ events: [] }), CHANNEL), null)
})

test('an unknown start time or duration falls back to the defaults', () => {
  const unknown = section({
    events: [{ eventId: 5, descriptors: [] }],
  })
  const result = buildProgramPF(unknown, CHANNEL)
  assert.ok(result)
  assert.equal(result.program.start_time, new Date(Date.parse('2000-01-01T00:00:00+09:00')).toISOString())
  assert.equal(result.program.end_time, result.program.start_time)
  assert.equal(result.program.duration, null)
  assert.equal(result.program.title, '番組情報がありません')
})
