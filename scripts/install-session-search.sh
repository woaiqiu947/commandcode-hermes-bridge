#!/usr/bin/env bash
#
# 会话全文搜索 — Hermes 桌面插件安装脚本
#
# 用法（在任意一台装了 Hermes 的机器上）：
#   bash install-session-search.sh
#
# 装完按 ⌘K → 输入 "Reload desktop plugins" → 回车，
# 侧边栏底部会出现「会话搜索」入口。
#
# 为什么用脚本而不是拷 plugin.js：
#   自包含。插件源码内嵌在脚本里，只需这一个文件就能在别的机器上重建，
#   不用担心忘记带目录、路径不对、权限丢失。
#
# 为什么插件里要给中文加引号（见下方插件注释）：
#   Hermes 后端 /api/sessions/search 会给每个搜索词加 `*` 做前缀匹配。
#   英文走 unicode61 分词器，`foo*` 是真前缀，没问题；中文走 CJK 路径，
#   星号会被当成字面字符，导致「孙红雷」只剩 1 条命中（实际 2 条）、
#   三字词可能 0 条。插件发请求前给中文词包一层双引号即可绕开。

set -euo pipefail

# Hermes home：优先用环境变量（profile 场景），否则 ~/.hermes
HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
DEST="$HERMES_HOME/desktop-plugins/session-search"

if [ ! -d "$HERMES_HOME" ]; then
  echo "❌ 找不到 Hermes 目录：$HERMES_HOME" >&2
  echo "   如果用的是命名 profile，请先 export HERMES_HOME=~/.hermes/profiles/<名字>" >&2
  exit 1
fi

mkdir -p "$DEST"

cat > "$DEST/plugin.js" <<'PLUGIN_JS'
/**
 * 会话全文搜索 — Hermes 桌面插件
 *
 * 为什么有这个插件：
 *   桌面端侧边栏那个「搜索会话」框走的是 /api/sessions/search，但它对中文有 bug——
 *   服务端会给每个词加 `*` 做前缀匹配（为了 nimb → nimbus），中文字符串被包成
 *   "孙红雷*" 后变成在找字面上带星号的六个字符，结果漏搜严重（"孙红雷" 只回 1 条，
 *   实际有 2 条；"景甜" 只回 1 条，实际有 3 条）。英文走 unicode61 分词器，前缀匹配
 *   正常，所以只有中文遭殃。
 *
 * 规避办法：本插件在发请求前把中文搜索词用双引号包住（`孙红雷` → `"孙红雷"`）。
 *   服务端看到 tok.startswith('"') 就保持原样，星号不会被加上，走 CJK 路由后结果正确。
 *
 * 依赖的通道：
 *   - window.hermesDesktop.api()  —— Electron 主进程代发 REST 并处理鉴权凭据，
 *     插件不需要自己拿 token（也就不会把 token 写进前端代码里）
 *   - host.openSession(storedId)  —— SDK 官方跳转门，负责切 profile / 水合历史
 *
 * 安装位置：<HERMES_HOME>/desktop-plugins/session-search/（文件夹名 == 插件 id）
 */
import {
  host,
  PALETTE_AREA,
  ROUTES_AREA,
  SIDEBAR_NAV_AREA,
  EmptyState,
  ScrollArea,
  SearchField,
  cn
} from '@hermes/plugin-sdk'
import React from 'react'
import { jsx, jsxs } from 'react/jsx-runtime'

const ID = 'session-search'
const PATH = '/session-search'

/** 搜索防抖：跟侧边栏一致用 200ms，既不卡输入也不会每敲一个字就打一次库。 */
const DEBOUNCE_MS = 200

/**
 * 判断字符串里有没有中日韩字符。
 *
 * 为什么需要它：只有 CJK 查询才需要加引号规避那个前缀星号 bug。英文加引号会把
 * 前缀匹配也关掉——搜 `nimbus` 就搜不到 `nimbusx`，反而让英文退化了。
 */
function hasCJK(text) {
  return /[\u3040-\u30ff\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff\uac00-\ud7af]/.test(text)
}

/**
 * 把用户输入变成能安全穿过服务端 prefix_query 的查询串。
 *
 * 规则：
 *   - 已经带引号的片段原样保留（用户想精确匹配词组时自己加）
 *   - 含 CJK 的词加双引号 —— 这是绕开前缀星号 bug 的关键
 *   - 纯 ASCII 词原样传，让服务端的前缀匹配继续生效（rom → romantic）
 */
function buildQuery(raw) {
  return raw
    .trim()
    .split(/\s+/)
    .filter(Boolean)
    .map(token => {
      if (token.startsWith('"') && token.endsWith('"')) {
        return token
      }

      return hasCJK(token) ? `"${token}"` : token
    })
    .join(' ')
}

/**
 * 把命中片段按高亮标记切成若干段，用来渲染真正的 <mark>。
 *
 * 服务端用 >>>…<<< 标出命中位置。插件拿到的 snippet 是纯字符串，只去掉标记的话
 * 用户看不出关键词落在哪；这里切成 [{text, hit}]，命中段套高亮样式。
 */
function splitHighlight(snippet) {
  const parts = []
  const text = snippet ?? ''
  const re = />>>([\s\S]*?)<<</g
  let last = 0
  let m

  while ((m = re.exec(text)) !== null) {
    if (m.index > last) {
      parts.push({ hit: false, text: text.slice(last, m.index) })
    }

    parts.push({ hit: true, text: m[1] })
    last = m.index + m[0].length
  }

  if (last < text.length) {
    parts.push({ hit: false, text: text.slice(last) })
  }

  return parts.length ? parts : [{ hit: false, text }]
}

/** 相对时间——列表里比绝对时间戳好扫读。 */
function relativeTime(ts) {
  if (!ts) {
    return ''
  }

  const seconds = Math.floor(Date.now() / 1000 - ts)

  if (seconds < 60) {
    return '刚刚'
  }

  if (seconds < 3600) {
    return `${Math.floor(seconds / 60)} 分钟前`
  }

  if (seconds < 86400) {
    return `${Math.floor(seconds / 3600)} 小时前`
  }

  if (seconds < 86400 * 30) {
    return `${Math.floor(seconds / 86400)} 天前`
  }

  const d = new Date(ts * 1000)

  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`
}

/**
 * 发一次搜索请求。
 *
 * 用 window.hermesDesktop.api 而不是 fetch：后者要自己拼 Authorization，而 token
 * 只存在于 Electron 进程里；前者由主进程补凭据并负责把请求路由到当前网关连接
 * （本地 / 远程 / 云端都对）。
 */
async function searchSessions(query, limit) {
  const bridge = window.hermesDesktop

  if (!bridge?.api) {
    throw new Error('桌面桥不可用：请确认在 Hermes 桌面端里运行')
  }

  return bridge.api({
    path: `/api/sessions/search?q=${encodeURIComponent(query)}&limit=${limit}`,
    method: 'GET'
  })
}

/** 单个结果行。单独抽出来，输入时只有列表重渲染，搜索框不跟着闪。 */
function ResultRow({ onOpen, result }) {
  const parts = splitHighlight(result.snippet)
  const title = result.title || '(未命名会话)'
  const meta = [result.source, relativeTime(result.last_active ?? result.session_started)]
    .filter(Boolean)
    .join(' · ')

  return jsxs('button', {
    className: cn(
      'group flex w-full flex-col gap-1 rounded-md px-2.5 py-2 text-left transition-colors',
      'hover:bg-(--ui-control-hover-background)'
    ),
    onClick: () => onOpen(result),
    type: 'button',
    children: [
      jsxs('div', {
        className: 'flex min-w-0 items-baseline gap-2',
        children: [
          jsx('span', {
            className: 'truncate text-[0.8125rem] font-medium text-(--ui-text-primary)',
            children: title
          }),
          typeof result.message_count === 'number' && result.message_count > 0
            ? jsx('span', {
                className: 'shrink-0 text-[0.6875rem] text-(--ui-text-quaternary)',
                children: `${result.message_count} 条`
              })
            : null
        ]
      }),
      jsx('div', {
        className: 'line-clamp-2 text-[0.75rem] leading-relaxed text-(--ui-text-tertiary)',
        children: parts.map((part, i) =>
          part.hit
            ? jsx(
                'mark',
                {
                  className: 'rounded-[2px] bg-(--ui-accent-alpha) px-0.5 text-(--ui-text-primary)',
                  children: part.text
                },
                i
              )
            : jsx('span', { children: part.text }, i)
        )
      }),
      meta ? jsx('div', { className: 'text-[0.6875rem] text-(--ui-text-quaternary)', children: meta }) : null
    ]
  })
}

/** 主页面：搜索框 + 结果列表。 */
function SessionSearchPage() {
  const [query, setQuery] = React.useState('')
  const [results, setResults] = React.useState([])
  const [pending, setPending] = React.useState(false)
  const [error, setError] = React.useState(null)
  // 用 ref 记住最后一次请求的序号：慢请求回来时如果已经有了更新的请求，就丢弃它的
  // 结果，避免「输入太快，旧结果盖掉新结果」。
  const requestSeq = React.useRef(0)
  const trimmed = query.trim()

  React.useEffect(() => {
    if (!trimmed) {
      setResults([])
      setError(null)
      setPending(false)

      return undefined
    }

    setPending(true)
    const seq = ++requestSeq.current
    const timer = window.setTimeout(() => {
      searchSessions(buildQuery(trimmed), 50)
        .then(res => {
          if (seq !== requestSeq.current) {
            return
          }

          setResults(Array.isArray(res?.results) ? res.results : [])
          setError(null)
        })
        .catch(err => {
          if (seq !== requestSeq.current) {
            return
          }

          setResults([])
          setError(err?.message ?? String(err))
        })
        .finally(() => {
          if (seq === requestSeq.current) {
            setPending(false)
          }
        })
    }, DEBOUNCE_MS)

    return () => window.clearTimeout(timer)
  }, [trimmed])

  const openResult = React.useCallback(result => {
    const storedId = result.session_id || result.id

    if (!storedId) {
      return
    }

    // intent: 'main' 是侧边栏点会话行用的意图——在当前主视图里打开，不会每点一次就
    // 堆一个新标签页。expectHistory 让 SDK 等历史水合完再交还，否则用户先看到空白。
    void host
      .openSession(storedId, { expectHistory: true, intent: 'main' })
      .catch(err => host.notifyError(err, '打开会话失败'))
  }, [])

  return jsxs('div', {
    className: 'flex h-full w-full flex-col gap-3 p-4',
    children: [
      jsxs('div', {
        className: 'flex shrink-0 flex-col gap-1',
        children: [
          jsx('h1', { className: 'text-sm font-medium text-(--ui-text-primary)', children: '会话全文搜索' }),
          jsx('p', {
            className: 'text-[0.75rem] text-(--ui-text-tertiary)',
            children: '在所有会话的消息正文里搜索，点击结果直接跳转'
          })
        ]
      }),
      jsx(SearchField, {
        'aria-label': '搜索所有会话',
        loading: pending,
        onChange: setQuery,
        placeholder: '搜索所有会话内容…（支持中英文、空格分词）',
        value: query
      }),
      jsxs('div', {
        className: 'flex min-h-0 flex-1 flex-col',
        children: [
          error
            ? jsx('div', {
                className: 'rounded-md border border-(--ui-stroke-secondary) p-3 text-[0.75rem] text-(--ui-text-secondary)',
                children: `搜索出错：${error}`
              })
            : null,
          !pending && !error && !trimmed
            ? jsx(EmptyState, { description: '输入关键词开始搜索', title: '搜索所有会话' })
            : null,
          !pending && !error && trimmed && results.length === 0
            ? jsx(EmptyState, { description: `没有会话包含「${trimmed}」`, title: '没有结果' })
            : null,
          results.length > 0
            ? jsxs(ScrollArea, {
                className: 'min-h-0 flex-1',
                children: [
                  jsx('div', {
                    className: 'pb-1 text-[0.6875rem] text-(--ui-text-quaternary)',
                    children: `${results.length} 个会话`
                  }),
                  results.map(result =>
                    jsx(ResultRow, { onOpen: openResult, result }, result.session_id || result.id)
                  )
                ]
              })
            : null
        ]
      })
    ]
  })
}

export default {
  id: ID,
  name: '会话全文搜索',
  register(ctx) {
    console.log('[session-search] 已加载，路由 ' + PATH)

    ctx.register({
      id: 'page',
      area: ROUTES_AREA,
      data: { path: PATH },
      render: () => jsx(SessionSearchPage, {})
    })

    ctx.register({
      id: 'nav',
      area: SIDEBAR_NAV_AREA,
      data: {
        path: PATH,
        label: '会话搜索',
        codicon: 'search'
      }
    })

    ctx.register({
      id: 'open',
      area: PALETTE_AREA,
      data: {
        id: 'session-search.open',
        label: '搜索所有会话内容'
      },
      run: () => host.navigate(PATH)
    })
  }
}
PLUGIN_JS

# 校验：能解析成 ESM 才算写对了（插件是未编译加载的，语法错会静默失败）
if command -v node >/dev/null 2>&1; then
  if node --check --input-type=module < "$DEST/plugin.js" 2>/dev/null; then
    echo "✅ 语法校验通过"
  else
    echo "⚠️  语法校验未通过，请检查 node 版本（需支持 --input-type=module）" >&2
  fi
fi

echo ""
echo "✅ 已安装到：$DEST"
echo ""
echo "下一步："
echo "  1. 打开 Hermes 桌面端"
echo "  2. 按 ⌘K（Windows/Linux 用 Ctrl+K）"
echo "  3. 输入：Reload desktop plugins  → 回车"
echo "  4. 侧边栏底部会出现「会话搜索」"
echo ""
echo "说明：插件已内置中文搜索的引号规避逻辑，即使后端有前缀星号 bug 也能搜全。"
