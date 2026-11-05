/**
 * モックサーバーが配信する PSI/SI アーカイブデータ (fixtures/psi-archived-data.bin)
 * を、このページと同じ手順 (psisiarc のパース → web-bml の decodeTS → EIT[p/f])
 * でデコードできることの確認。
 *
 * フィクスチャは MockServer/make_psi_fixture.py が生成したもので、3 周期
 * (1 周期 = 2 チャンク) ぶんの psisiarc を含む。PAT / PMT (データ放送の
 * コンポーネント入り) / SDT / EIT[p/f] / TOT に加えて、データカルーセル
 * (DII と DDB) と、その中の起動文書 startup.bml も入っている。2 周期目
 * 以降は前のチャンクの辞書を参照する (辞書 ID 4096 以上) ので、辞書の
 * 再利用もこのデータで確認できる。
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

type Message = {
  type: string
  components?: { componentId: number, pid: number, streamType: number, bxmlInfo?: unknown }[]
  componentId?: number
  moduleId?: number
  modules?: { id: number, version: number, size: number }[]
  dataEventId?: number
  files?: { contentLocation: string | null, contentType: { type: string, subtype: string }, dataBase64: string }[]
}

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
  return { messages, eits, parser }
}

test('the mock data decodes into PAT / PMT / EIT', () => {
  const { messages, eits } = decodeFixture()

  const pmt = messages.find((message) => message.type === 'pmt')
  assert.ok(pmt, 'PMT がデコードできない')
  // データ放送のコンポーネント (AdditionalAribBXMLInfo 付き) がある
  const dataComponent = pmt.components?.find((component) => component.bxmlInfo != null)
  assert.ok(dataComponent, 'データ放送のコンポーネントがない')
  // 地上波のエントリコンポーネント (component_tag 0x40) と DSM-CC のストリーム種別
  assert.equal(dataComponent.componentId, 0x40)
  assert.equal(dataComponent.streamType, 0x0d)

  // EIT[p/f] の Present / Following が 1 本ずつ (3 周期ぶん届く)
  assert.equal(eits.length, 6)
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

test('the archive starts with psisiarc\'s magic bytes', () => {
  // 実放送の書庫のマジックは ASCII の "Pssc" + 0x0D 0x0A 0x9A 0x0A で、公式の
  // 読み取りはこの 8 バイトだけをビッグエンディアンで読む (ほかのフィールドは
  // リトルエンディアン)。ここが入れ替わると、実サーバーの書庫はどのチャンクも
  // 読めなくなり、データ放送が loading のまま止まる。
  const data = new Uint8Array(readFileSync(resolve(here, 'fixtures', 'psi-archived-data.bin')))
  assert.deepEqual([...data.subarray(0, 8)], [0x50, 0x73, 0x73, 0x63, 0x0d, 0x0a, 0x9a, 0x0a])
  assert.equal(String.fromCharCode(...data.subarray(0, 4)), 'Pssc')
})

test('a chunk with the magic in the wrong byte order is rejected', () => {
  const data = new Uint8Array(readFileSync(resolve(here, 'fixtures', 'psi-archived-data.bin')))
  // 以前の（誤った）リトルエンディアンのマジックに書き換えた書庫は読めない
  const swapped = data.slice()
  swapped.set([0x63, 0x73, 0x73, 0x50, 0x0a, 0x9a, 0x0a, 0x0d], 0)
  const parser = new PSIArchivedDataParser()
  const pids: number[] = []
  parser.push(swapped, (_second, _packets, pid) => pids.push(pid))
  assert.deepEqual(pids, [])
})

test('the archive is read completely, with dictionary reuse and no dropped chunk', () => {
  const { parser } = decodeFixture()
  // 2 周期目以降のチャンクは前のチャンクの辞書 (ID 4096 以上) を参照する。
  // 読み飛ばしたチャンクがあれば、この値が 0 でなくなる。
  assert.equal(parser.droppedChunks, 0)
})

test('the carousel module carries the startup document', () => {
  const { messages } = decodeFixture()

  // web-bml はこの 2 つでエントリモジュール (component 0x40 / module 0x0000)
  // が揃ったことを知り、startup.bml を起動文書として開く。ページが state:
  // ready を返すのはそのあと。
  const listUpdated = messages.find((message) => message.type === 'moduleListUpdated')
  assert.ok(listUpdated, 'DII がデコードできない')
  assert.equal(listUpdated.componentId, 0x40)
  assert.deepEqual(
    listUpdated.modules?.map((module) => module.id),
    [0x0000],
  )
  assert.ok((listUpdated.modules?.[0].size ?? 0) > 4066, 'モジュールが 1 つの DDB ブロックに収まっている')

  const downloaded = messages.find((message) => message.type === 'moduleDownloaded')
  assert.ok(downloaded, 'DDB (モジュール) がデコードできない')
  assert.equal(downloaded.componentId, 0x40)
  assert.equal(downloaded.moduleId, 0x0000)
  const file = downloaded.files?.find((entry) => entry.contentLocation === 'startup.bml')
  assert.ok(file, 'モジュールに startup.bml がない')
  assert.equal(file.contentType.type, 'application')
  assert.equal(file.contentType.subtype, 'x-arib-bml')
  const document = Buffer.from(file.dataBase64, 'base64').toString('latin1')
  assert.match(document, /<html/)
  assert.match(document, /KonomiTV/)
})

test('the EIT of the mock data becomes a present / following program', () => {
  const { eits } = decodeFixture()
  const present = buildProgramPF(eits[0].section, { networkId: 32736, serviceId: 1024 })
  assert.ok(present)
  assert.equal(present.presentOrFollowing, 'Present')
  assert.equal(present.program.title, 'テスト放送　ニュース・情報')
  assert.equal(present.program.description, '放送中の番組です。')
  assert.equal(present.program.id, 'NID32736-SID1024-EID9000')

  const following = buildProgramPF(eits[1].section, { networkId: 32736, serviceId: 1024 })
  assert.ok(following)
  assert.equal(following.presentOrFollowing, 'Following')
  assert.equal(following.program.title, 'テスト放送　アニメ劇場')
})
