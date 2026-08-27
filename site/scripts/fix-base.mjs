// postbuild：修正 dist 中残留的根路径链接
// astro-pure 包内组件（如 Header 的 Brand 链接）硬编码 href="/" 等根路径，
// 在 GitHub Pages 子路径部署（base=/apeiron/）下必须补前缀；node_modules 无法持久修改，
// 故在 build 产物上做精确修正（仅替换已知字面量，不做泛化正则，避免误伤）。
import { readdirSync, readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'

const distDir = join(fileURLToPath(new URL('.', import.meta.url)), '..', 'dist')
const base = '/apeiron' // 与 astro.config 的 base 保持一致
const replacements = [
  ['href="/"', 'href="/apeiron/"'], // Header Brand（包内组件）
  ['href="/search"', 'href="/apeiron/search"'],
  ['href="/icons/code.svg', 'href="/apeiron/icons/code.svg'],
  ['"/scripts/pretty-feed-v3.xsl"', '"/apeiron/scripts/pretty-feed-v3.xsl"'],
  ['/PATH-TO-YOUR-STYLES/pretty-feed-v3.xsl', '/apeiron/scripts/pretty-feed-v3.xsl'],
]

function* walk(dir) {
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const p = join(dir, entry.name)
    if (entry.isDirectory()) yield* walk(p)
    else if (/\.(html|xml)$/.test(entry.name)) yield p
  }
}

let fixed = 0
for (const file of walk(distDir)) {
  let content = readFileSync(file, 'utf8')
  let changed = false
  for (const [from, to] of replacements) {
    if (content.includes(from)) {
      content = content.replaceAll(from, to)
      changed = true
    }
  }
  if (changed) {
    writeFileSync(file, content)
    fixed++
  }
}

console.log(`[fix-base] patched ${fixed} file(s) with base=${base}`)
