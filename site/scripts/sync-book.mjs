// 书稿同步：仓库根 ../book/*.md → src/content/docs/（frontmatter 归一化：date → publishDate）
// 单一源真：改 ../book 即改站点；由 npm prebuild 自动执行（本地与 Actions 均生效）。
import { mkdirSync, readdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'

const siteDir = fileURLToPath(new URL('..', import.meta.url))
const bookDir = join(siteDir, '..', 'book')
const docsDir = join(siteDir, 'src', 'content', 'docs')
const blogDir = join(siteDir, 'src', 'content', 'blog')

// 主题自带的示例内容全部清掉（书稿是这个站点的唯一内容）
rmSync(docsDir, { recursive: true, force: true })
rmSync(blogDir, { recursive: true, force: true })
mkdirSync(docsDir, { recursive: true })
mkdirSync(blogDir, { recursive: true })

// 00-index.md 是仓库内的目录页，站点首页由 /docs/ 列表承担，跳过
const files = readdirSync(bookDir)
  .filter((f) => f.endsWith('.md') && f !== '00-index.md')
  .sort()

for (const file of files) {
  const content = readFileSync(join(bookDir, file), 'utf8').replace(
    /^date: .*$/m,
    (line) => line.replace(/^date:/, 'publishDate:'),
  )
  writeFileSync(join(docsDir, file), content)
}

console.log(`[sync-book] ${files.length} chapters → src/content/docs/`)
