/**
 * EIT[p/f] (現在放送中 / 次の番組) から、UI 表示用の番組情報を作る。
 *
 * Web クライアントの LivePSIArchivedDataDecoder.generateIProgramFromEPG() の
 * うち、ライブ視聴画面の番組表示に必要な項目 (ID 系・番組名・概要・開始/終了
 * 時刻・番組長) だけを移植したもの。ジャンルや音声情報はサーバーの
 * `GET /api/channels` の値を使う。
 */

import { decodeSIText } from 'arib-mmt-tlv-ts/ts/si-text-decoder.js'

import type { ProgramPFProgram } from './bridge.ts'

/** EIT のイベント (arib-mmt-tlv-ts が返す形のうち、使う項目だけ) */
export type EITEvent = {
  eventId: number
  /** MJD + BCD 時刻 (40 ビット)。未定なら undefined */
  startTime?: number
  /** BCD 番組長 (24 ビット)。未定なら undefined */
  duration?: number
  freeCAMode?: boolean
  descriptors: EITDescriptor[]
}

export type EITDescriptor = {
  tag: string
  eventName?: Uint8Array
  text?: Uint8Array
}

/** EIT のセクション (arib-mmt-tlv-ts が返す形のうち、使う項目だけ) */
export type EITSection = {
  serviceId: number
  originalNetworkId: number
  currentNextIndicator: boolean
  sectionNumber: number
  events: EITEvent[]
}

export type ChannelIdentity = {
  networkId: number
  serviceId: number
}

/** MJD (修正ユリウス日) → UNIX 時刻 (秒) */
function mjdToUnixSeconds(mjd: number): number {
  return (mjd - 40587) * 86400
}

/** BCD 時刻 (24 ビット) → 0 時からの秒数 */
function bcdTimeToSeconds(bcd: number): number {
  const hour = ((bcd >> 20) & 0xf) * 10 + ((bcd >> 16) & 0xf)
  const minute = ((bcd >> 12) & 0xf) * 10 + ((bcd >> 8) & 0xf)
  const second = ((bcd >> 4) & 0xf) * 10 + (bcd & 0xf)
  return hour * 3600 + minute * 60 + second
}

/** MJD + BCD 時刻 (40 ビット) → UNIX 時刻 (秒, JST の時刻として解釈) */
export function mjdBCDToUnixSeconds(value: number): number {
  const mjd = Math.floor(value / (1 << 24))
  return mjdToUnixSeconds(mjd) + bcdTimeToSeconds(value) - 3600 * 9
}

/**
 * EIT[p/f] から番組情報を作る。対象外の EIT (他局・スケジュール・
 * current_next_indicator=0 など) は null を返す。
 */
export function buildProgramPF(
  section: EITSection,
  channel: ChannelIdentity,
): { presentOrFollowing: 'Present' | 'Following', program: ProgramPFProgram } | null {
  // 有効でない EIT を除外する (EIT[p/f] のイベントは 1 つだけ)
  if (!section.currentNextIndicator || section.events.length !== 1) {
    return null
  }
  if (section.originalNetworkId !== channel.networkId || section.serviceId !== channel.serviceId) {
    return null
  }

  const event = section.events[0]
  // section_number が 0 なら現在放送中、1 なら次の番組
  const presentOrFollowing: 'Present' | 'Following' = section.sectionNumber === 0 ? 'Present' : 'Following'

  let startTimeUnix: number | null = null
  let duration: number | null = null
  if (event.startTime !== undefined) {
    startTimeUnix = mjdBCDToUnixSeconds(event.startTime)
  }
  if (event.duration !== undefined) {
    duration = bcdTimeToSeconds(event.duration)
  }

  // 開始時刻が未定のときは IProgramDefault と同じ初期値
  const startSeconds = startTimeUnix ?? Date.parse('2000-01-01T00:00:00+09:00') / 1000
  // 番組長が未定のときは終了時刻を開始時刻と同じにする (Web 版と同じ)
  const endSeconds = duration === null ? startSeconds : startSeconds + duration

  const shortEvent = event.descriptors.find((descriptor) => descriptor.tag === 'shortEvent')
  const title = shortEvent?.eventName ? decodeSIText(shortEvent.eventName) : '番組情報がありません'
  const description = shortEvent?.text ? decodeSIText(shortEvent.text) : ''

  const networkId = section.originalNetworkId
  const serviceId = section.serviceId
  return {
    presentOrFollowing,
    program: {
      id: `NID${networkId}-SID${serviceId}-EID${event.eventId}`,
      channel_id: `NID${networkId}-SID${serviceId}`,
      network_id: networkId,
      service_id: serviceId,
      event_id: event.eventId,
      title,
      description,
      start_time: new Date(startSeconds * 1000).toISOString(),
      end_time: new Date(endSeconds * 1000).toISOString(),
      duration,
      is_free: event.freeCAMode !== true,
    },
  }
}
