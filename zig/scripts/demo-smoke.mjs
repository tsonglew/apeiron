// apeiron-demo.wasm 端到端冒烟测试（Node >= 18）
// 用法：node zig/scripts/demo-smoke.mjs [wasm 路径]
// 验证：demo_init -> 写入输入 -> demo_prompt -> 校验 entries/events/messages
//      -> demo_resume -> 校验恢复后的消息重建。
import { readFileSync } from 'node:fs'

const wasmPath = process.argv[2] ?? new URL('../../zig-out/bin/apeiron-demo.wasm', import.meta.url)
const bytes = readFileSync(wasmPath)
const { instance } = await WebAssembly.instantiate(bytes, {})
const ex = instance.exports
const memory = ex.memory

if (!(ex.demo_init && ex.demo_prompt && ex.demo_resume && ex.demo_result_len && ex.demo_result_ptr)) {
  console.error('SMOKE FAIL: missing exported demo API')
  process.exit(1)
}

const utf8 = new TextEncoder()
const readResult = () => {
  const len = ex.demo_result_len()
  const ptr = ex.demo_result_ptr()
  return new TextDecoder().decode(new Uint8Array(memory.buffer, ptr, len))
}

ex.demo_init()

// 写入消息 "hi wasm" 到输入缓冲区
const msg = 'hi wasm'
const inputPtr = ex.demo_input_ptr()
new Uint8Array(memory.buffer, inputPtr, msg.length).set(utf8.encode(msg))
ex.demo_set_input(msg.length)

if (ex.demo_prompt() !== 0) {
  console.error('SMOKE FAIL: demo_prompt returned error')
  process.exit(1)
}
const result = JSON.parse(readResult())

const kindSeq = result.entries.map((e) => `${e.kind}@${e.seq}`)
const expectEntries = ['user@1', 'tool_call@2', 'tool_result@3', 'assistant@4']
if (JSON.stringify(kindSeq) !== JSON.stringify(expectEntries)) {
  console.error('SMOKE FAIL: entries mismatch', kindSeq)
  process.exit(1)
}

const eventNames = result.events.map((e) => e.event)
const expectEvents = ['turn_start', 'tool_call', 'tool_result', 'message_end', 'turn_end']
if (JSON.stringify(eventNames) !== JSON.stringify(expectEvents)) {
  console.error('SMOKE FAIL: events mismatch', eventNames)
  process.exit(1)
}

const lastMsg = result.messages[result.messages.length - 1]
if (lastMsg.role !== 'assistant' || lastMsg.content !== 'done: hi wasm') {
  console.error('SMOKE FAIL: final message mismatch', lastMsg)
  process.exit(1)
}

// 恢复语义：新会话同 id 从存储重建消息
if (ex.demo_resume() !== 0) {
  console.error('SMOKE FAIL: demo_resume returned error')
  process.exit(1)
}
const resumed = JSON.parse(readResult())
const roles = resumed.messages.map((m) => m.role)
const expectRoles = ['user', 'assistant', 'tool', 'assistant']
if (JSON.stringify(roles) !== JSON.stringify(expectRoles)) {
  console.error('SMOKE FAIL: resume roles mismatch', roles)
  process.exit(1)
}

console.log(`SMOKE OK: 4 entries, 5 events, resume -> ${roles.join('->')} (wasm ${bytes.length} bytes)`)
