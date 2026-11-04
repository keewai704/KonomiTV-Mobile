import assert from 'node:assert/strict'
import test from 'node:test'

import { Bridge, enabledKeys, REMOTE_KEYS } from '../src/bridge.ts'
import type { BridgeMessage } from '../src/bridge.ts'

test('the data button is always available and groups map to keys', () => {
  assert.deepEqual(enabledKeys([]), ['d'])
  assert.deepEqual(
    enabledKeys(['basic']),
    ['d', 'up', 'down', 'left', 'right', 'enter', 'back'],
  )
  assert.deepEqual(
    enabledKeys(['data-button']),
    ['d', 'blue', 'red', 'green', 'yellow'],
  )
  assert.equal(enabledKeys(['numeric-tuning']).length, 13)
  // 未知のキー種別は無視する
  assert.deepEqual(enabledKeys(['other-tuning']), ['d'])
})

test('remote keys are the ones the native remote shows', () => {
  assert.deepEqual(REMOTE_KEYS, [
    'up', 'down', 'left', 'right', 'enter', 'back',
    'blue', 'red', 'green', 'yellow',
    '1', '2', '3', '4', '5', '6', '7', '8', '9', '10', '11', '12',
  ])
})

test('bridge messages are plain objects the native side can read', () => {
  const messages: BridgeMessage[] = []
  const bridge = new Bridge((message) => messages.push(message))

  bridge.state('loading')
  bridge.usedKeys(['basic'])
  bridge.videoRect({ left: 10, top: 20, width: 300, height: 200 }, { width: 390, height: 844 })
  bridge.videoRect(null, { width: 390, height: 844 })
  bridge.error('ネットワークエラー', '文書の取得に失敗しました', 'E400')
  bridge.programPF('Present', {
    id: 'NID32736-SID1024-EID1',
    channel_id: 'NID32736-SID1024',
    network_id: 32736,
    service_id: 1024,
    event_id: 1,
    title: '番組',
    description: '',
    start_time: '2026-01-01T03:00:00.000Z',
    end_time: '2026-01-01T04:00:00.000Z',
    duration: 3600,
    is_free: true,
  })

  assert.deepEqual(messages[0], { type: 'state', state: 'loading' })
  assert.deepEqual(messages[1], { type: 'usedKeys', keys: ['d', 'up', 'down', 'left', 'right', 'enter', 'back'] })
  assert.deepEqual(messages[2], {
    type: 'videoRect',
    rect: { left: 10, top: 20, width: 300, height: 200 },
    pageSize: { width: 390, height: 844 },
  })
  assert.deepEqual(messages[3].type, 'videoRect')
  assert.equal((messages[3] as { rect: unknown }).rect, null)
  assert.deepEqual(messages[4], {
    type: 'error',
    title: 'ネットワークエラー',
    message: '文書の取得に失敗しました',
    code: 'E400',
  })
  assert.equal(messages[5].type, 'programPF')
  // JSON にできること (WKScriptMessage.body は辞書として渡る)
  for (const message of messages) {
    assert.deepEqual(JSON.parse(JSON.stringify(message)), message)
  }
})

test('the bridge falls back to the console without a message handler', () => {
  const bridge = new Bridge()
  // 例外にならなければよい
  bridge.log('hello')
})
