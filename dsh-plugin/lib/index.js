/**
 * dsh-client-sales-coach —— 把「客户聊天教练」注册成 DSH 技能。
 *
 * 只依赖 cordis 运行时和 skills 服务：
 *   ctx.skills.register({ name, description, content, resourceBase, ... })
 *
 * 技能正文从包内 skills/client-sales-coach/SKILL.md 读取，references/ 目录
 * 作为 resourceBase 暴露给模型按需读取，因此改正文不需要改插件代码。
 */
import { readFileSync, existsSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

/** 稳定的 Cordis 插件名（同时作为 roster 行 id）。 */
export const name = 'client-sales-coach'

/** skills 注册表必须先就绪。 */
export const inject = ['skills']

const HERE = dirname(fileURLToPath(import.meta.url))
const SKILL_DIR = join(HERE, '..', 'skills', 'client-sales-coach')
const SKILL_FILE = join(SKILL_DIR, 'SKILL.md')

const FALLBACK = {
  name: 'client-sales-coach',
  description:
    'B2B 客户销售教练：分析客户聊天/邮件/纪要，判断采购阶段与真实意向，识别信号，给出可复制回复与止损建议。'
}

/**
 * 解析 SKILL.md 的 YAML frontmatter，返回 { data, body }。
 * 只覆盖本技能实际用到的写法（单行值、`>-` 折叠块），不做通用 YAML。
 * @param {string} raw 原始文件内容
 */
function parseFrontmatter(raw) {
  const match = /^---\r?\n([\s\S]*?)\r?\n---[ \t]*\r?\n?/.exec(raw)
  if (!match) return { data: {}, body: raw }

  const data = {}
  let key = null
  let fold = false
  let buffer = []

  const commit = () => {
    if (key === null) return
    const text = (fold ? buffer.join(' ') : buffer.join('\n')).replace(/[ \t]+/g, ' ').trim()
    if (text.length > 0) data[key] = text
    key = null
    fold = false
    buffer = []
  }

  for (const line of match[1].split(/\r?\n/)) {
    const kv = /^([A-Za-z][\w-]*):[ \t]*(.*)$/.exec(line)
    if (kv) {
      commit()
      key = kv[1]
      const value = kv[2].trim()
      if (value === '>-' || value === '>' || value === '|' || value === '|-') {
        fold = true
      } else {
        buffer = [value]
        commit()
      }
    } else if (key !== null) {
      buffer.push(line.trim())
    }
  }
  commit()

  return { data, body: raw.slice(match[0].length) }
}

/**
 * 挂载插件：注册技能，并在插件卸载时释放注册。
 * @param ctx 携带 skills 服务的 Host 插件上下文
 * @param config 行配置（enabled 可关闭）
 */
export function apply(ctx, config) {
  const enabled = config?.enabled !== false

  ctx.effect(() => {
    if (!enabled) return undefined

    if (!existsSync(SKILL_FILE)) {
      ctx.logger?.warn?.(`dsh-client-sales-coach: 找不到技能文件 ${SKILL_FILE}`)
      return undefined
    }

    let skill
    try {
      const raw = readFileSync(SKILL_FILE, 'utf8')
      const { data, body } = parseFrontmatter(raw)
      skill = {
        name: data.name || FALLBACK.name,
        description: data.description || FALLBACK.description,
        whenToUse: data.whenToUse || undefined,
        content: body.trim(),
        path: SKILL_FILE,
        resourceBase: { kind: 'directory', path: SKILL_DIR },
        invocation: { modelInvocable: true, userInvocable: true },
        source: 'custom'
      }
    } catch (error) {
      ctx.logger?.warn?.(
        `dsh-client-sales-coach: 读取技能失败 ${error instanceof Error ? error.message : String(error)}`
      )
      return undefined
    }

    try {
      return ctx.skills.register(skill)
    } catch (error) {
      ctx.logger?.warn?.(
        `dsh-client-sales-coach: 注册技能失败 ${error instanceof Error ? error.message : String(error)}`
      )
      return undefined
    }
  }, 'dsh-client-sales-coach: register skill')
}
