/**
 * モックサーバーが配信する PSI/SI アーカイブデータ (fixtures/psi-archived-data.bin)
 * を、このページと同じ手順 (psisiarc のパース → web-bml の decodeTS → EIT[p/f])
 * でデコードできることの確認。
 *
 * フィクスチャは MockServer/data_broadcasting_mock.py が生成したもので、
 * PAT / PMT (データ放送のコンポーネント入り) / SDT / EIT[p/f] / TOT を含む。
 */

import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, resolve } from 'node:path'
import test from 'node:test'
import { fileURLToPath } from 'node:url'

import { decodeTS } from 'web-bml/ts'

import { buildProgramPF } from '../src/program.ts'
import type { EITSection } from '../src/program.ts'
import { PSIArchivedDataParser, TSPacketWriter } from '../src/psi.ts'

const here = dirname(fileURLToPath(import.meta.url))

type Message = { type: string, components?: { bxmlInfo?: unknown }[] }

function decodeFixture() {
  const data = new Uint8Array(readFileSync(resolve(here, 'fixtures', 'psi-archived-data.bin')))
  const messages: Message[] = []
  const eits: { pid: number, section: EITSection & { tableIdNumber: number } }[] = []

  const stream = decodeTS({
    sendCallback: (message: Message) => messages.push(message),
    serviceId: 1024,
    parsePES: false,
  })
  stream.addEventListener('eit', (event: { pid: number, section: EITSection & { tableIdNumber: number } }) => {
    eits.push(event)
  })

  const parser = new PSIArchivedDataParser()
  const writer = new TSPacketWriter()
  parser.push(data, (_second, packets, pid) => {
    writer.setHeader(packets, pid)
    stream.push(packets)
  })
  stream.close()
  return { messages, eits }
}

test('the mock data decodes into PAT / PMT / EIT', () => {
  const { messages, eits } = decodeFixture()

  const pmt = messages.find((message) => message.type === 'pmt')
  assert.ok(pmt, 'PMT がデコードできない')
  // データ放送のコンポーネント (AdditionalAribBXMLInfo 付き) がある
  const dataComponent = pmt.components?.find((component) => component.bxmlInfo != null)
  assert.ok(dataComponent, 'データ放送のコンポーネントがない')

  // EIT[p/f] の Present / Following が 1 本ずつ
  assert.equal(eits.length, 2)
  assert.equal(eits[0].pid, 0x12)
  assert.equal(eits[0].section.tableIdNumber, 0x4e)
  assert.equal(eits[0].section.sectionNumber, 0)
  assert.equal(eits[1].section.sectionNumber, 1)
  for (const eit of eits) {
    assert.equal(eit.section.serviceId, 1024)
    assert.equal(eit.section.originalNetworkId, 32736)
    assert.equal(eit.section.events.length, 1)
  }
})

test('the EIT of the mock data becomes a present / following program', () => {
  const { eits } = decodeFixture()
  const present = buildProgramPF(eits[0].section, { networkId: 32736, serviceId: 1024 })
  assert.ok(present)
  assert.equal(present.presentOrFollowing, 'Present')
  assert.equal(present.program.title, 'モックの番組')
  assert.equal(present.program.description, 'データ放送のテストです。')
  assert.equal(present.program.id, 'NID32736-SID1024-EID100')

  const following = buildProgramPF(eits[1].section, { networkId: 32736, serviceId: 1024 })
  assert.ok(following)
  assert.equal(following.presentOrFollowing, 'Following')
  assert.equal(following.program.title, '次の番組')
})
