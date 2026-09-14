# CommandCode → Hermes 接入手册（任意机器复制用）

> 目标：让另一台机器上的 Hermes 也能通过本地 bridge 使用同一个 CommandCode 订阅。
> 本手册是通用步骤，按当前已跑通的 macOS 实例整理（2026-09-02）。Windows / Linux 差异处已标注。
> **上游版本基线：1.53.0.a（2026-09-10 由 1.38.2.a 升级）**；本机 = 上游 main + 仓库 `patches/` 三个本地补丁
> （`0001-canonical-models-only.patch` 去别名 + 白名单唯一权威；`0002-stream-abort-error-handling.patch` 流式中断不再崩进程；
> `0003-cooldown-cleared-on-success.patch` 请求成功后清除残留冷却，见 §8）。
> 全程不需要把 CommandCode Studio key 发给任何人或贴进聊天；key 只写进本机文件。

## 0. 前置条件核对

```bash
node --version    # 需 ≥ 20（建议 22 LTS）
npm --version
git --version
hermes --version  # 目标机器已装 Hermes CLI
```

缺 node：macOS `brew install node`；Windows `winget install OpenJS.NodeJS.LTS`。

## 1. 安装 bridge（本地 OpenAI 兼容服务）

```bash
git clone https://github.com/yelixir-dev/commandcode-bridge ~/commandcode-bridge   # Windows: %USERPROFILE%\commandcode-bridge
cd ~/commandcode-bridge
npm install --include=dev
cp .env.example .env
npm run build
```

> 官方 `install.sh` 仅支持 Linux systemd；macOS / Windows 一律用上面的手动方式。

## 2. 配置 .env

编辑 `~/commandcode-bridge/.env`（Windows 用记事本/VS Code），只动这几行：

```bash
# (1) 你的 CommandCode Studio API key —— 账号级，两台机器可共用同一把
COMMANDCODE_API_KEY=<你的key>

# (2) 本地访问 key —— 自己生成一串随机数，仅本机 Hermes 用它访问 bridge
BRIDGE_API_KEY=<随机串，生成方法见下>

# (3) 白名单 = GOAT 套餐官方额度表（PDF）的 31 个模型 + 主动放行的 1 个（`deepseek/deepseek-v4.1-flash`，
#     共 32 个）。旧 deepseek v4-flash / -fast / -vision-exp 三个 ID 已由官方路由到 V4.1-Flash（-vision-exp
#     上游已无 provider），故移除、只留钉死版 v4.1-flash，其余一律不提供
COMMANDCODE_ALLOWED_MODELS=gpt-5.6-sol,gpt-5.6-luna,deepseek/deepseek-v4-pro,deepseek/deepseek-v4.1-flash,zai-org/GLM-5.2,zai-org/GLM-5.2-Fast,zai-org/GLM-5.3,z-ai/glm-5.3-flash,moonshotai/Kimi-K3,moonshotai/Kimi-K2.7-Code,moonshotai/Kimi-K2.7-Code-Highspeed,MiniMaxAI/MiniMax-M3,Qwen/Qwen3.6-Plus,Qwen/Qwen3.7-Plus,Qwen/Qwen3.7-Max,Qwen/Qwen3.8-Max,Qwen/Qwen3.8-27B,Qwen/Qwen3.8-Flash,xiaomi/mimo-v2.5,xiaomi/mimo-v2.5-pro,tencent/hy3-paid,tencent/hy4-preview,xai/grok-4.5,xai/grok-4.6,google/gemini-3.7-flash,stepfun/Step-3.5-Flash,stepfun/Step-3.7-Flash,nvidia/nemotron-3-ultra-550b-a55b,thinkingmachines/inkling,thinkingmachines/inkling-small,meta/muse-spark-1.2,meta/muse-spark-1.2-contributor

# (4) 本地补丁①开关：/v1/models 只列正式模型 ID，不混入别名（Hermes 列表才干净）
COMMANDCODE_PUBLIC_MODELS_CANONICAL_ONLY=true

# (5) 向上游上报的 CLI 版本 —— 与本机 bridge 版本保持一致（上游升级后同步改，当前 1.53.0）
COMMANDCODE_CLI_VERSION=1.53.0

# (6) 默认模型 —— 客户端未显式指定 model 时用它。V4.1-Flash 正式版（2026-09-11 起；旧默认 v4-pro
#     自 2026-09-14 12:00 起也会被官方路由到 V4.1-Flash，直接写 V4.1 的 ID 更明确）
COMMANDCODE_DEFAULT_MODEL=deepseek/deepseek-v4.1-flash
```

随机串生成（无需 openssl，node 即可）：

```bash
node -e "console.log(require('crypto').randomBytes(32).toString('hex'))"
```

改完 `chmod 600 .env`（Windows 跳过）。

## 3. 启动 bridge + 开机自启

**macOS（launchd，本机已配好，模板见本文件末尾）**：

```bash
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.commandcode.bridge.plist
launchctl kickstart -k gui/$(id -u)/com.commandcode.bridge   # 改配置后重启
```

**Windows（登录自启，最简方案）**：把下面存成
`%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\commandcode-bridge.cmd`：

```bat
@echo off
cd /d %USERPROFILE%\commandcode-bridge
npm start
```

想立刻跑一次：双击上面这个文件，或 `cd /d %USERPROFILE%\commandcode-bridge && npm start`。

**Linux**：官方 `install.sh`（systemd）或手动 `nohup npm start &`。

**验证**（任选其一，`/health` 无需鉴权）：

```bash
curl -fsS http://127.0.0.1:9992/health
# 期望 {"status":"ok",...}；auth 里 commandcode_api_key_configured: true
```

> `upstream` 字段：`commandcode-provider-api` = 订阅支持官方 API（好）；`commandcode-alpha-generate` = 走了旧隧道（key 没生效或档位不支持，查日志）。

## 4. 在 Hermes 注册 provider（与操作系统无关，命令完全一致）

```bash
hermes config set providers.commandcode.name commandcode
hermes config set providers.commandcode.api "http://127.0.0.1:9992/v1"
hermes config set providers.commandcode.key_env COMMANDCODE_BRIDGE_API_KEY
hermes config set providers.commandcode.transport openai_chat
hermes config set providers.commandcode.default_model "deepseek/deepseek-v4.1-flash"
hermes config set providers.commandcode.models "[gpt-5.6-sol,gpt-5.6-luna,deepseek/deepseek-v4-pro,deepseek/deepseek-v4.1-flash,zai-org/GLM-5.2,zai-org/GLM-5.2-Fast,zai-org/GLM-5.3,z-ai/glm-5.3-flash,moonshotai/Kimi-K3,moonshotai/Kimi-K2.7-Code,moonshotai/Kimi-K2.7-Code-Highspeed,MiniMaxAI/MiniMax-M3,Qwen/Qwen3.6-Plus,Qwen/Qwen3.7-Plus,Qwen/Qwen3.7-Max,Qwen/Qwen3.8-Max,Qwen/Qwen3.8-27B,Qwen/Qwen3.8-Flash,xiaomi/mimo-v2.5,xiaomi/mimo-v2.5-pro,tencent/hy3-paid,tencent/hy4-preview,xai/grok-4.5,xai/grok-4.6,google/gemini-3.7-flash,stepfun/Step-3.5-Flash,stepfun/Step-3.7-Flash,nvidia/nemotron-3-ultra-550b-a55b,thinkingmachines/inkling,thinkingmachines/inkling-small,meta/muse-spark-1.2,meta/muse-spark-1.2-contributor]"
```

把第 2 步的 `BRIDGE_API_KEY` 追加进 Hermes 的私有 env（路径用命令查，别硬编码）：

```bash
HERMES_ENV="$(hermes config env-path)"
echo "COMMANDCODE_BRIDGE_API_KEY=<你的BRIDGE_API_KEY>" >> "$HERMES_ENV"   # Windows PowerShell: Add-Content $env:USERPROFILE\.hermes\.env "..."
```

不修改现有默认模型；想切换默认再执行（可选）：

```bash
hermes config set model.provider custom:commandcode
hermes config set model.default deepseek/deepseek-v4.1-flash
```

> ⚠️ **改 `default_model` 只影响新建会话。** Hermes 会话在**创建时**把模型钉死（落库到 `sessions.model`），
> 已存在的会话/正在进行的对话继续用它创建时那个模型，改配置**不会追溯**。
> 想让某个已有会话换模型：在桌面端模型选择器里切，或新开一个会话（CLI 没有"改已有会话模型"的子命令）。
> 查证：`sqlite3 ~/.hermes/state.db "select id, model from sessions order by started_at desc limit 5;"`。

## 5. 冒烟测试

```bash
hermes chat -Q --provider custom:commandcode -m gpt-5.6-luna -q 'Reply exactly COMMANDCODE_HERMES_OK'
hermes chat -Q --provider custom:commandcode -m zai-org/GLM-5.2 -q 'Reply exactly GLM_OK'
hermes chat -Q --provider custom:commandcode -m Qwen/Qwen3.8-Max -q 'Reply exactly GOAT_OK'
hermes chat -Q --provider custom:commandcode -m deepseek/deepseek-v4.1-flash -q 'Reply exactly DS41_OK'
```

都原样返回即成功。

## 5.1 模型列表为空、重复或出现不该有的模型

先确认 bridge 的真实目录，不要先修改 Hermes：

```bash
curl -fsS http://127.0.0.1:9992/health
```

`/health` 应返回 `status: ok`，并且 `models` 应为白名单中的 32 个正式模型 ID（GOAT 额度表 31 个 + 主动放行的 `deepseek/deepseek-v4.1-flash`；旧 v4-flash/-fast/-vision-exp 已移除）。
如果 bridge 返回正常，问题通常在 Hermes 的 provider 配置格式，而不是上游账号或 bridge。

### 修复 Hermes 端的错误模型列表配置

某些 Hermes 版本会把下面这种写法保存成**字符串**，而不是列表：

```yaml
models: '[gpt-5.6-sol,...]'
```

这会导致模型选择器显示空列表、解析异常，或者把整段字符串当成一个模型。不要继续重复执行
`hermes config set providers.commandcode.models "[... ]"`。

先删除错误的 `models` 键，再启用动态发现：

```bash
hermes config unset providers.commandcode.models
hermes config set providers.commandcode.discover_models true
```

> 版本注记（2026-09-08，Hermes v0.18.2 实测）：`hermes config unset` / `hermes
> config get` 在该版本**不存在**（`config_command` 只处理 show/edit/set/path/
> env-path/migrate，未知子命令静默 no-op，不会报错）。等效做法：直接编辑
> `$(hermes config path)` 删掉 `providers.commandcode` 下的整段 `models:` 块
> （逐行替换，勿用 PyYAML 整文件往返以免丢注释），再执行上面的
> `discover_models` 设置。`discover_models` 字段本身 v0.18.2 已支持。

然后完全退出并重新打开 Hermes Desktop（或重启当前 Hermes CLI 会话）。再次检查：

```bash
hermes config get providers.commandcode
hermes model
```

正常结果应满足：

- provider API 仍是 `http://127.0.0.1:9992/v1`
- `discover_models: true`
- 不再有形如 `models: '[...]'` 的字符串配置
- 模型列表中的数量与 `curl http://127.0.0.1:9992/v1/models` 返回的 32 个正式 ID 一致

### 如果列表仍为空

先确认 Hermes 版本和 bridge 接口：

```bash
hermes --version
curl -fsS http://127.0.0.1:9992/v1/models \\
  -H "Authorization: Bearer $COMMANDCODE_BRIDGE_API_KEY"
```

如果 `/v1/models` 返回 401，说明当前 shell 没有加载 `COMMANDCODE_BRIDGE_API_KEY`；不要把 key 粘贴到聊天或日志中，直接重新执行第 3、4 步的本机配置。
如果 `/v1/models` 返回 32 个模型但 `hermes model` 仍显示 0 个，说明是该 Hermes 版本的自定义 provider 动态发现兼容性问题；此时不要手工把 JSON/CSV 拼进 `providers.commandcode.models`，应升级 Hermes 后重新执行本节，或把该现象和 `hermes --version` 提交给 Hermes 维护者。

> 版本注记（2026-09-08，Hermes v0.18.2 实测）：该版本的动态发现**正常**。
> 无头复现 picker 同款路径（`list_authenticated_providers`，经
> `hermes_cli.model_switch`）实测返回 `total_models=34`、`source=user-config`，
> 与 `/v1/models` 一致。若在 v0.18.2 上看到 0 个模型，先重查 bridge health
> 与 shell 环境变量（401 陷阱），不要直接归因于版本兼容性。

> 关键原则：bridge 的 `/v1/models` 是模型目录的唯一权威来源；Hermes 配置只负责 provider 地址和认证，不要在两处维护两份容易漂移的模型白名单。

## 6. 白名单可用模型（32 个正式 ID：GOAT 官方额度表 31 个 + 主动放行 1 个）

| 厂商 | 模型 ID（调用用这个） | 额度表显示名 |
|---|---|---|
| OpenAI 系 | `gpt-5.6-sol` | GPT-5.6 Sol |
| OpenAI 系 | `gpt-5.6-luna` | GPT-5.6 Luna |
| DeepSeek | `deepseek/deepseek-v4-pro` | DeepSeek V4 Pro (latest) |
| DeepSeek | `deepseek/deepseek-v4.1-flash` | DeepSeek V4.1 Flash ⚠️ 不在额度表内，2026-09-11 主动放行 |
| 智谱 | `zai-org/GLM-5.2` | GLM-5.2 |
| 智谱 | `zai-org/GLM-5.2-Fast` | GLM-5.2 Fast |
| 智谱 | `zai-org/GLM-5.3` | GLM-5.3 |
| 智谱 | `z-ai/glm-5.3-flash` | GLM-5.3 Flash |
| Moonshot | `moonshotai/Kimi-K3` | Kimi K3 |
| Moonshot | `moonshotai/Kimi-K2.7-Code` | Kimi K2.7 Code |
| Moonshot | `moonshotai/Kimi-K2.7-Code-Highspeed` | Kimi K2.7 Code HighSpeed |
| MiniMax | `MiniMaxAI/MiniMax-M3` | MiniMax M3 |
| 阿里 | `Qwen/Qwen3.6-Plus` | Qwen 3.6 Plus |
| 阿里 | `Qwen/Qwen3.7-Plus` | Qwen 3.7 Plus |
| 阿里 | `Qwen/Qwen3.7-Max` | Qwen 3.7 Max |
| 阿里 | `Qwen/Qwen3.8-Max` | Qwen 3.8 Max |
| 阿里 | `Qwen/Qwen3.8-27B` | Qwen 3.8 27B |
| 阿里 | `Qwen/Qwen3.8-Flash` | Qwen 3.8 Flash |
| 小米 | `xiaomi/mimo-v2.5` | MiMo V2.5 |
| 小米 | `xiaomi/mimo-v2.5-pro` | MiMo V2.5 Pro |
| 腾讯 | `tencent/hy3-paid` | Tencent Hy3 |
| 腾讯 | `tencent/hy4-preview` | Tencent Hy4 Preview |
| xAI | `xai/grok-4.5` | Grok 4.5 |
| xAI | `xai/grok-4.6` | Grok 4.6 |
| Google | `google/gemini-3.7-flash` | Gemini 3.7 Flash |
| StepFun | `stepfun/Step-3.5-Flash` | Step 3.5 Flash |
| StepFun | `stepfun/Step-3.7-Flash` | Step 3.7 Flash |
| NVIDIA | `nvidia/nemotron-3-ultra-550b-a55b` | Nemotron 3 Ultra |
| Thinking Machines | `thinkingmachines/inkling` | Inkling |
| Thinking Machines | `thinkingmachines/inkling-small` | Inkling Small |
| Meta | `meta/muse-spark-1.2` | Muse Spark 1.2 |
| Meta | `meta/muse-spark-1.2-contributor` | Muse Spark 1.2 Contributor |

**⚠️ 唯一例外**：`deepseek/deepseek-v4.1-flash`（DeepSeek V4.1 Flash 正式版，2026-09-11 发布）**不在 GOAT 额度表 PDF 内**，
但实测订阅的 Provider API 通道可用（`/v1/chat/completions` 返回 200，按 Flash 同价计费），故主动加入白名单。

**V4.1-Flash 的 ID 选择：滚动别名 vs 钉版（2026-09-11 实测）**

CommandCode 目录里同一个模型今天有**两个**可用 ID：

| ID | 上游显示名 | 价格（目录 notes） | 性质 |
|---|---|---|---|
| `deepseek/deepseek-v4.1-flash` | DeepSeek V4.1 Flash | $0.15/M in · $0.6/M out | **版本钉死**（新版发布后会变旧） |
| `deepseek/deepseek-v4-flash` | DeepSeek V4 Flash **(latest)** | $0.15/M in · $0.6/M out | **滚动别名**（跟随最新 Flash） |

判据：**价格与上下文完全一致** ＋ 上游把 v4-flash 标为 **"(latest)"** ＋ 实测两者都能读图
（视觉属 V4.1-Flash 能力；旧的视觉 ID `deepseek/deepseek-v4-flash-vision-exp` 上游已无可用 provider，
报 400 `No available providers match the 'only' filter: deepseek`）。
⚠️ 强度：**强证据但非证明**——CommandCode 的 `system_fingerprint` **每次请求都随机变**
（同模型 4 次得 4 个不同值），不能当模型标识。

**本机口径**：默认模型取**钉死版** `deepseek/deepseek-v4.1-flash`——名字即实际模型、可复现；
代价是将来新版发布要手动跟。2026-09-11 起滚动别名 `deepseek/deepseek-v4-flash`（及 -fast、-vision-exp）已从白名单移除，
模型选择器只显示 `v4-pro` + `v4.1-flash`；要恢复"自动跟随最新"需把滚动别名 ID 加回 `.env` 白名单并重启。

**两个渠道务必区分（同一模型、名字不同）**：

| 渠道 | V4.1-Flash 的正式名 | 另一个可用名 | 说明 |
|---|---|---|---|
| CommandCode（本 bridge） | `deepseek/deepseek-v4.1-flash`（本机默认，钉死） | `deepseek/deepseek-v4-flash` | 后者是**滚动别名 "(latest)"**，**不是**退役名 |
| DeepSeek 官方 API | **`deepseek-flash`** | `deepseek-v4-flash` | 后者是**退役旧名**。官方判据（**确定**）：① 文档明写旧名退役、请求由 V4.1-Flash 承接；② 正式名与旧名返回**相同** `system_fingerprint`（`aeb56401ca74e127821c4f9126dcb669`）且都能读图；③ 官方**不接受** `deepseek-v4.1-flash`（400：仅支持 `deepseek-flash` / `deepseek-v4-pro`） |

⚠️ 不要把官方那条"旧名退役"结论套到 CommandCode 目录上——bridge 走的是 CommandCode Provider API，
那边 v4-flash 是滚动别名而非退役名（本手册早期版本曾写错，已更正）。
另：官方 `deepseek-v4-pro` 自 **2026-09-14 12:00（北京时间）** 起也路由到 V4.1-Flash；截至 2026-09-11 其官方指纹
（`a307abda487cd1b463329ccb945ce396`）仍与 flash 不同，即尚未切换。

不在上表的（含全部 `claude-*`、Kimi-K2.6/K2.5、GLM-5.1、MiniMax-M2.7、Qwen3.7-Flash 等）不在 GOAT 内，bridge 已收紧不放行。目录里出现过的 `deepseek-v4-pro` / `GLM-5.2` / `openai/gpt-5.6-luna` 等是别名变体，Hermes 里调用统一用上表带厂商前缀的 ID。

## 7. 故障排查

> **“连接不上 / 模型不能用”这类问题**有一份专门的**分层定位手册**：
> **[TROUBLESHOOTING-CONNECTION.md](TROUBLESHOOTING-CONNECTION.md)** —— 按 5 层从下往上查，
> 含 **Windows PowerShell** 与 **macOS** 的一键自检脚本（`platforms/pc/doctor.ps1` / `scripts/doctor.sh`）。
> 下表演是速查表，覆盖面更广；连接类问题优先用那份分层手册。

| 症状 | 处理 |
|---|---|
| `hermes chat` 报连不上 127.0.0.1:9992 | bridge 没起：macOS `launchctl print gui/$(id -u)/com.commandcode.bridge`；Windows 看 Startup 文件夹的 cmd 是否被执行（双击试跑） |
| health 里 `commandcode_api_key_configured: false` | `.env` 的 `COMMANDCODE_API_KEY` 没填/没保存，改完重启 bridge |
| 模型请求 403 / model_not_found | 该模型不在白名单；改 `COMMANDCODE_ALLOWED_MODELS` 后重启 |
| 返回上游余额/权限错误 | 安装本身健康，是订阅档位/额度问题；看日志：macOS `tail -50 ~/commandcode-bridge/bridge.stdout.log`，Windows 在启动窗口里直接可见 |
| 想更新 bridge | `git -C ~/commandcode-bridge pull && cd ~/commandcode-bridge && npm install --include=dev && npm run build`，再重启服务 |
| 改了 `default_model` 但当前对话/新会话还是旧模型 | 会话在**创建时**钉死模型（`sessions.model`），改配置**不追溯**已存在的会话。新开会话，或在客户端模型选择器里切。查证：`sqlite3 ~/.hermes/state.db "select id, model from sessions order by started_at desc limit 5;"` |
| bridge 反复重启 / 日志出现 `AbortError` + `Emitted 'error' event on Readable instance` | 客户端取消流式请求导致进程退出的上游缺陷；本机已由 `patches/0002-stream-abort-error-handling.patch` 修掉（§8 ③）。若仍复现，说明补丁没打上或没重新 `npm run build`。计数：`grep -c AbortError ~/commandcode-bridge/bridge.stderr.log` |
| 直接 curl 调 `/v1/chat/completions` 报 502 `commandcode_empty_visible_response` | 推理模型会先把 token 预算花在思考上，可见文本还没出来预算就没了。把 `max_tokens` 调到 **≥ 32**（上游 `.env.example` 的 `COMMANDCODE_EMPTY_VISIBLE_*` 注释即写明此点）。`hermes chat` 自己设够了 token，走它不受影响 |

## 8. 本地定制补丁（⚠️ git pull 升级后需重打）

对应仓库 `patches/` 三个文件：**`0001-canonical-models-only.patch`**（① + ②，改 `src/config.ts` / `src/types.ts`）、
**`0002-stream-abort-error-handling.patch`**（③，改 `src/provider-chat.ts` + 新增 `tests/provider-chat.test.ts`）、
**`0003-cooldown-cleared-on-success.patch`**（④，改 `src/credential-router.ts` + `tests/credential-router.test.ts` / `tests/provider.test.ts`）。
打完 `npm run build` 并重启服务；一键重打三个：

```bash
cd ~/commandcode-bridge && git apply patches/0001-*.patch patches/0002-*.patch patches/0003-*.patch && npm run build
```

**① 去别名开关**（2026-09-02）：上游 `publicModelList()` 把 `MODEL_ALIASES` 别名混进 `/v1/models` 输出，
导致 Hermes 客户端列表同一模型出现多行（`gpt-5.6-luna` / `openai/gpt-5.6-luna` / `GPT-5.6-Luna`）。
本机加了一个默认关闭的开关，开启后只返回正式 ID；请求侧别名解析不受影响：

```diff
 export function publicModelList(config: BridgeConfig): string[] {
   const canonicalModels = uniq([config.defaultModel, ...config.allowedModels]);
+  if (config.publicModelsCanonicalOnly) return canonicalModels;  // 开关见下
   const aliasModels = ...
```

配套改动：`BridgeConfig`（`src/types.ts`）加字段 `publicModelsCanonicalOnly: boolean;`，
`loadBridgeConfig` 解析 `env.COMMANDCODE_PUBLIC_MODELS_CANONICAL_ONLY`（默认 false）。
`.env` 里置 `COMMANDCODE_PUBLIC_MODELS_CANONICAL_ONLY=true` 生效。

**② 白名单唯一权威**（2026-09-02）：上游 `mergeModelCatalog()` 默认把内置定义里 enabled 的
7 个模型与 env **取并集**（第 4 参 `enableMissingDefinitions` 默认 true），导致
`COMMANDCODE_ALLOWED_MODELS` 只能增不能减——收紧白名单时被删模型仍出现在 `/v1/models`。
已把 env 分支的调用改为传 `false`：

```diff
       ? mergeModelCatalog(
           allowedFromEnv.map((model) => ({ id: model, enabled: true })),
           allowedFromEnv,
           normalizeModelName,
+          false,   // env 白名单是唯一权威，不并入内置默认 enabled
         )
```

**③ 流式中断错误处理**（2026-09-11）：上游 `handleProviderChat()` 里
`Readable.fromWeb(response.body).pipe(transform)` 的**来源流没有 `'error'` 监听者**，而 Node 的 `.pipe()`
**不把源流错误转给下游**。客户端一旦中断流式请求（`server.ts` 的 `reply.raw` `"close"` → `signal.abort()`），
上游 body 就以 `AbortError` 触发来源流的 `'error'`，随即升级成**未捕获的 error 事件 → 进程 exit 1**。
实测本机 2026-09-03 起 **67 次崩溃全部由此而来**：每天日常约 1:1 触发（点「停止」/任何取消流式请求即崩，
且崩掉会连带掐断该进程上所有在途请求）。
⚠️ 注意 `server.ts` 里那个 `AbortError` 优雅处理只覆盖「中断发生在上游响应体挂上之前」的情形
（错误被 throw 进 try/catch）；**SSE 一旦开始输出，错误走的是事件通道而非异常通道，必然绕过它**。

补法 = 显式接管来源流的 `'error'`：客户端已断开则静默销毁下游，只有真实上游故障才把错误转下去：

```diff
-    const stream = Readable.fromWeb(response.body as WebReadableStream<Uint8Array>).pipe(transform);
+    const source = Readable.fromWeb(response.body as WebReadableStream<Uint8Array>);
+    source.on("error", (error: unknown) => {
+      if (transform.destroyed) return;
+      const aborted = signal.aborted || (error instanceof Error && error.name === "AbortError");
+      if (aborted) transform.destroy();
+      else transform.destroy(error instanceof Error ? error : new Error(String(error)));
+    });
+    const stream = source.pipe(transform);
```

回归测试 `tests/provider-chat.test.ts` 两条：① 客户端中断不得产生未捕获异常；② 真实上游故障仍须把错误传给
下游（防止修过头把真错也一起吞掉）。**验证为 RED → GREEN**：还原补丁时两条用例均失败（Uncaught Exception），
打上补丁后通过；`npm run test` 从 226 → **228 passed**，`typecheck` / `lint` / `build` 全绿。

**④ 冷却在请求成功后未清除**（2026-09-14）：上游 `credential-router.ts` 的 `recordSuccess()` 只释放并发计数，
**不清冷却**。而 `recordFailure()` 遇 429 / 无状态码 / 5xx 会给凭证打上 `cooldownMs`（默认 60s）冷却。
两者叠加出的故障链：单凭证场景下，请求 A 内部先撞上游 5xx（打上 60s 冷却）→ A 内部重试成功、**对外返回 200**
→ 但冷却仍在，于是接下来整个冷却窗口内所有请求都在 `select()` 处筛不出候选，
被**秒拒 503** `No available CommandCode credentials for model ...`（响应时间仅 18~27ms，根本没发上游请求）。
实测本机 2026-09-14 09:10:17/19/24 连续三个 503 即此（Hermes 自动重试 3 次全撞上，之后自愈）。

特征（据此与「上游真故障」区分）：**前一个请求成功返回后，紧接着的请求立刻 503，且耗时极短（几十毫秒）**；
`/admin/commandcode/credentials` 看凭证 `disabledForMs` 非 0、`disabledReason` 为 `cooldown`。

补法 = `recordSuccess()` 清掉**自己造成的**冷却，只清 `cooldown`（`auth` / `billing` / `expired` 反映凭证真实问题，
一次成功不足以推翻）：

```diff
 public recordSuccess(id: string): void {
-    this.release(id);
+    const state = this.stateById(id);
+    if (state && state.disabledReason === "cooldown") {
+      state.disabledUntil = 0;
+      state.disabledReason = undefined;
+    }
+    this.release(id);
 }
```

回归测试两条：`tests/credential-router.test.ts` ① 请求最终成功后不得残留冷却；② 成功的那次请求**只**清自己的冷却，
不能替别的凭证「洗白」。另有 `tests/provider.test.ts` 一条端到端用例（撞 500 → 重试成功 → 紧接着的请求必须仍可选中）。
**验证为 RED → GREEN**：还原补丁时该组用例精确复现线上报错（`NoAvailableCommandCodeCredentialError` at
`credential-router.ts:395`），打上后 `npm run test` 从 228 → **231 passed**，`typecheck` / `lint` / `build` 全绿；
生产实例重启后实测连续 5 次请求全部 200。

**白名单现状**：`COMMANDCODE_ALLOWED_MODELS` = GOAT 套餐官方额度表（PDF）的 **31 个正式模型 ID** + 主动放行的
`deepseek/deepseek-v4.1-flash`，共 **32 个**（旧 deepseek v4-flash / -fast / -vision-exp 三 ID 已由官方路由到 V4.1-Flash 而移除，见 §6）。
Claude 系列（`claude-*`）不在 GOAT 内，Provider API 通道实测 403；目录里其余未列模型（如
Kimi-K2.6/GLM-5.1/MiniMax-M2.7/Qwen3.7-Flash 等）也已随收紧移除。想加回某个模型：编辑 .env 该行追加 ID 后重启。

**升级记录（2026-09-10）**：上游 `1.38.2.a → 1.53.0.a`（模型目录 62 → 70；新增 gpt-6-astra、claude-fable-5-1、
muse-spark-1.3、gemini-3.8-flash、deepseek-v4.1-flash、LongCat-2.0 等，均不在 GOAT 内所以列表无变化）。
升级按：`git stash push -- src/config.ts src/types.ts` → `git pull --ff-only` → `git stash pop`
（`src/config.ts` 自动合并成功，当时的两处补丁**无需改动**，`patches/0001-*.patch` 与升级后工作区逐行一致；
`0002-stream-abort-error-handling.patch` 是 2026-09-11 才加的，同日另测）
→ `npm install` → `npm run typecheck` / `lint` / `test`（226 passed）/ `build` 全绿 → 重启服务。
⚠️ 升级后顺手把 `.env` 的 `COMMANDCODE_CLI_VERSION` 改成新版本号（1.53.0）再重启。

**白名单变更（2026-09-11）**：`deepseek/deepseek-v4.1-flash`（DeepSeek V4.1 Flash **正式版**）加入
`COMMANDCODE_ALLOWED_MODELS`（34 → **35**）。上游目录在 1.53.0 升级时就已出现该 ID，当时按"不在 GOAT 内"未放行；
本次实测订阅的 Provider API 通道可用后放行。改动面：`~/commandcode-bridge/.env`（改前已备份 `.env.bak-*`）、
本手册（§2 / §5.1 / §6 / §8）、`config/env.example`、`platforms/macos/env.macos.example`、`platforms/pc/env.windows.example`。
生效与验证：`launchctl kickstart -k gui/$(id -u)/com.commandcode.bridge` → `/health` 的 models 变 35 个 →
`hermes model --refresh`（选 `Leave unchanged` 退出，**不动**默认模型）→ `POST /v1/chat/completions` 返回 200
（`max_tokens` 需 ≥ 32）→ `hermes chat -Q --provider commandcode -m deepseek/deepseek-v4.1-flash -q '...'` 正常返回。
顺带修掉一条上游健壮性问题并记入 §8 ③：客户端中断流式响应时 bridge 会因未捕获 `AbortError` 直接 exit 1
（launchd `KeepAlive` 拉起），2026-09-03 起本机 67 次崩溃全由此而来；本次加 `patches/0002-stream-abort-error-handling.patch`
修掉并补了回归测试。生产实例已重启并验证：中断流式请求后进程存活、服务可继续响应。

**模型名对齐 V4.1-Flash（2026-09-11）**：确认两条渠道的 V4.1-Flash 名字后统一改名（命名对照与证据见 §6）。改动面：

| 位置 | 原值 | 新值 |
|---|---|---|
| Hermes `providers.commandcode.default_model` | `deepseek/deepseek-v4-flash` | `deepseek/deepseek-v4.1-flash` |
| bridge `.env` `COMMANDCODE_DEFAULT_MODEL` | `deepseek/deepseek-v4-pro` | `deepseek/deepseek-v4.1-flash` |
| Hermes MoA 聚合器（**DeepSeek 官方** provider）`moa.aggregator.model` + `moa.presets.default.aggregator.model` | `deepseek-v4-flash`（旧名） | `deepseek-flash`（V4.1 正式名） |
| cron 日报 `89ebfc3149f0` / 周报 `0d0aacfae6ef` 的 model | `deepseek/deepseek-v4-flash` | `deepseek/deepseek-v4.1-flash` |
| `config/env.example`、`platforms/macos/env.macos.example`、`platforms/pc/env.windows.example` 的 `COMMANDCODE_DEFAULT_MODEL` | `deepseek/deepseek-v4-pro` | `deepseek/deepseek-v4.1-flash` |

cron 的 model 是 user-owned 字段，`cronjob` 工具改不了，须用 `hermes cron edit <job_id> --model ...`。
生效验证：`launchctl kickstart -k` → `/health` 的 `default_model` 变 `deepseek/deepseek-v4.1-flash`；
`hermes config get providers.commandcode.default_model`、`hermes cron list` 复核。

补充记录（2026-09-11 同日复查）：

1. **顺带修掉仓库自身的内部不一致**：此前手册/macos README 记"Hermes 默认 `deepseek/deepseek-v4-flash`"，
   而三个 env 模板的 `COMMANDCODE_DEFAULT_MODEL` 却是 `deepseek/deepseek-v4-pro`——两处长期不符。
   本次统一为 `deepseek/deepseek-v4.1-flash`。
2. **默认为何取钉死版而非滚动别名**：CommandCode 目录里 `deepseek/deepseek-v4-flash` 是滚动别名
   （上游名带 "(latest)"），`deepseek/deepseek-v4.1-flash` 是版本钉死 SKU；今天两者同价同上下文。
   取钉死版是为了**名字即实际模型、可复现**；将来新版发布需手动跟（想自动跟随就换回别名，见 §6）。
3. **改 `default_model` 只影响新建会话**：Hermes 会话在创建时把模型写进 `sessions.model`，已存在的会话
   （含改名当时正在进行的对话）继续用旧模型，**改配置不会追溯**——这是当时"改了配置但对话里还是
   `deepseek-v4-flash`"的原因，不是配置没生效。要换已有会话：客户端模型选择器里切，或新开会话。

**白名单瘦身：移除旧 v4-flash 三个 ID（2026-09-11）**：用户反馈 CommandCode 模型选择器"还是显示 v4 flash"。
根因：`COMMANDCODE_ALLOWED_MODELS` 里除钉死版 `deepseek/deepseek-v4.1-flash` 外，还留着旧的
`deepseek/deepseek-v4-flash`（滚动别名 "(latest)"）、`-flash-fast`、`-flash-vision-exp` 三个 ID，选择器把它们
都列出来（显示为 "V4 Flash" 及变体）。三者现均由官方路由到 V4.1-Flash（-vision-exp 上游已无 provider），
功能上与 v4.1-flash 重叠，故从白名单移除：35 → **32**。改动面：`~/commandcode-bridge/.env`（已备份）、
本手册（§2 / §5.1 / §6 / §8）、`config/env.example`、`platforms/macos/env.macos.example`、`platforms/pc/env.windows.example`。
生效：`launchctl kickstart -k` → `/health` 的 models 变 32 个、deepseek 仅剩 `v4-pro` + `v4.1-flash`。
代价：失去"滚动别名自动跟随最新 Flash"的选项（恢复方法见 §6 本机口径）。

## 附：macOS launchd 模板（com.commandcode.bridge.plist）

放 `~/Library/LaunchAgents/`，路径按实际改（`node` 用 `which node` 查绝对路径）：

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.commandcode.bridge</string>
    <key>ProgramArguments</key>
    <array>
        <string>/Users/<你的用户名>/.hermes/node/bin/node</string>
        <string>/Users/<你的用户名>/commandcode-bridge/dist/index.js</string>
    </array>
    <key>WorkingDirectory</key><string>/Users/<你的用户名>/commandcode-bridge</string>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>StandardOutPath</key><string>/Users/<你的用户名>/commandcode-bridge/bridge.stdout.log</string>
    <key>StandardErrorPath</key><string>/Users/<你的用户名>/commandcode-bridge/bridge.stderr.log</string>
</dict>
</plist>
```

## 安全须知

- key 只进本机文件（.env / Hermes env，均 600）；bridge 默认只绑 `127.0.0.1`，不要开 `0.0.0.0` 除非在可信内网并配强 `BRIDGE_API_KEY`。
- 上游 bridge 是非官方项目（alpha 通道可能变化）；`npm audit` 有告警属上游依赖，与配置无关。
