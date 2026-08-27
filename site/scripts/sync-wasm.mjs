// 演示 WASM 同步：构建 zig 核心并复制到 site/public/（astro build 直接服务）
// 需要 PATH 上有 zig（或 ZIG 环境变量指向 zig 可执行文件）
import { execFileSync } from 'node:child_process'
import { copyFileSync, existsSync, mkdirSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const siteDir = dirname(fileURLToPath(new URL('.', import.meta.url)))
const zigDir = join(siteDir, '..', 'zig')
const zigBin = process.env.ZIG ?? 'zig'

const destDir = join(siteDir, 'public')
const dest = join(destDir, 'apeiron-demo.wasm')

console.log('[sync-wasm] building wasm demo...')
try {
  execFileSync(zigBin, ['build', 'wasm-demo'], { cwd: zigDir, stdio: 'pipe' })
  const src = join(zigDir, 'zig-out', 'bin', 'apeiron-demo.wasm')
  mkdirSync(destDir, { recursive: true })
  copyFileSync(src, dest)
  console.log('[sync-wasm] copied apeiron-demo.wasm -> site/public/')
} catch (err) {
  // 回退：使用已提交的 site/public/apeiron-demo.wasm（CI 无 zig 或构建失败时）
  if (existsSync(dest)) {
    console.warn(`[sync-wasm] zig build 失败（${err.message?.split('\n')[0] ?? err}）；沿用已提交的 wasm`)
  } else {
    console.error('[sync-wasm] zig 构建失败且无已提交的 wasm')
    process.exit(1)
  }
}
