# 连接错误排查手册 —— “另一台机器连不上 / 模型不能用”

> **适用症状**：Hermes 里用 `custom:commandcode-bridge` 时，模型列表为空、选不了模型、对话报
> **connection error / 连接失败 / 401 / 连不上 127.0.0.1:9992**。
> **面向对象**：新装的机器（尤其是**另一台电脑**）。本文以 **Windows** 为主，macOS 命令见
> [附录 A](#附录-a-macos-命令)。
> **来源**：2026-09-11 一次实机排查整理（mac 上一台跑通、另一台报错）。

---

## 0. 先懂一件事：bridge 是“每台机器自己的本地服务”

bridge 只监听 **`127.0.0.1:9992`** —— `127.0.0.1` 是**本机回环地址**，意思是：

- 它**不是**云端服务，**不能**被另一台电脑连过去。
- **每台电脑都要各自装一套 bridge**，各自用自己的 `.env`。
- 所以“我这边好好的、她那台不行”是**正常现象** —— 两台是完全独立的两个环境。

> **一句话**：第二台机器出问题，几乎永远是**那台机器自己的某一层没搭好**，跟“你这边正常”
> 没有任何关系。别怀疑第一台，直接查第二台。

---

## 1. 一键自检（先跑这个，30 秒定位）

本仓库自带自检脚本，**哪台机器出问题就在哪台机器上跑**：

**Windows（PowerShell）** —— 用 `platforms/pc/doctor.ps1`：

```powershell
# 在仓库目录内执行；默认 bridge 目录 %USERPROFILE%\commandcode-bridge
powershell -ExecutionPolicy Bypass -File platforms\pc\doctor.ps1
```

**macOS / Linux**：

```bash
bash scripts/doctor.sh
```

脚本会把下面第 2 节的**七层**检查**全部跑一遍并给出结论**（哪一层断了一目了然）。
如果想手动逐条查，照第 2 节做即可。

> 2026-09-18 起增加到七层：新增 **⑥ 进程是否跑着最新构建**（"修了还是坏"的常见原因）
> 与 **⑦ 传输上限 / 旧 ID 兜底开关**（413 与 `model_not_allowed` 两大高频故障）。
> Windows 的 `platforms/pc/doctor.ps1` 目前仍是五层，待 PC 侧同步。

---

## 2. 七层定位法（手动版）

> 原则：**从下往上查，哪一层先断，问题就在那一层。**

### 第 ① 层：bridge 到底有没有在跑？

**Windows：**
```powershell
# 端口在听吗？（通=有服务在 9992）
Test-NetConnection 127.0.0.1 -Port 9992 -InformationLevel Quiet
# 健康检查（无需鉴权，能返回 JSON 就说明 bridge 活着）
Invoke-RestMethod http://127.0.0.1:9992/health | ConvertTo-Json -Depth 5
# 任务计划在不在、上次跑的结果
Get-ScheduledTask -TaskName CommandCodeBridgeWatchdog | Get-ScheduledTaskInfo
# node 进程在不在
Get-Process node -ErrorAction SilentlyContinue | Select-Object Id,StartTime,Path
```

**判定**：`/health` 连不上 / 端口没监听 → **就是这层**（bridge 没起来）。

**修法**：见 `platforms/pc/README.md` 的「自启方案」——
① 确认 `%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\commandcode-bridge.cmd`
存在且能双击跑通；或 ② 确认任务计划 `CommandCodeBridgeWatchdog` 已创建、脚本里的
`NODE` / `BRIDGE_DIR` 路径**已把 `your-user` 换成真实用户名**。

---

### 第 ② 层：`.env` 里的上游 key 填了吗？

bridge 能启动、但**每次对话都失败**，日志里出现
`CommandCode API key is missing. Set COMMANDCODE_API_KEY or provide ~/.commandcode/auth.json.`
—— 这一层的问题。

**查：**
```powershell
# /health 里 auth.commandcode_api_key_configured 必须是 true
(Invoke-RestMethod http://127.0.0.1:9992/health).auth | ConvertTo-Json -Depth 5
```

```powershell
# 直接看 .env 有没有值（不会打印出 key 本身）
$env_file = "$env:USERPROFILE\commandcode-bridge\.env"
foreach ($k in 'COMMANDCODE_API_KEY','BRIDGE_API_KEY') {
  $line = (Select-String -Path $env_file -Pattern "^$k=" -ErrorAction SilentlyContinue).Line
  $val  = if ($line) { $line.Substring($line.IndexOf('=') + 1).Trim() } else { '' }
  "{0} = {1}" -f $k, $(if ($val) { '<有值>' } else { '<空/缺失>' })
}
```

**判定**：`commandcode_api_key_configured = false`，或上面显示 `<空/缺失>` → **就是这层**。

**修法**：编辑 `%USERPROFILE%\commandcode-bridge\.env`，把
`COMMANDCODE_API_KEY=<你的key>` 填上（key 来自 CommandCode Studio，**账号级，多台机器可共用同一把**），
保存后重启 bridge。

> ⚠️ `.env` 被 `.gitignore` 排除，**`git clone` 拿不到它** —— 新机器必须手动从
> `env.windows.example` 复制一份再填。这是“照仓库做却仍失败”的头号原因。

---

### 第 ③ 层：本地访问 key 对得上吗？（401）

bridge 用 `.env` 里的 `BRIDGE_API_KEY` 校验本地请求；Hermes 用
`COMMANDCODE_BRIDGE_API_KEY` 去访问 bridge。**两者必须字面完全一致**，否则每次请求都回 **401 Unauthorized**。

**查：**
```powershell
# 1) bridge 侧：.env 里的 BRIDGE_API_KEY
$bridgeKey = (Select-String -Path "$env:USERPROFILE\commandcode-bridge\.env" -Pattern '^BRIDGE_API_KEY=(.+)').Matches.Groups[1].Value.Trim()

# 2) 客户端侧：Hermes 私有 env 里的 COMMANDCODE_BRIDGE_API_KEY
$hermesEnv = (hermes config env-path)
$clientKey = (Select-String -Path $hermesEnv -Pattern '^COMMANDCODE_BRIDGE_API_KEY=(.+)').Matches.Groups[1].Value.Trim()

# 3) 只比长度与是否相等，不打印 key 本身
"bridge key 长度 = {0}；client key 长度 = {1}；一致 = {2}" -f $bridgeKey.Length, $clientKey.Length, ($bridgeKey -eq $clientKey)
```

**判定**：`一致 = False`（或任一为空）→ **就是这层**。

**修法**：把 Hermes 私有 env 里的 `COMMANDCODE_BRIDGE_API_KEY` 改成与 `.env` 的
`BRIDGE_API_KEY` **完全相同**，然后**完全重开 Hermes**（改环境变量后旧进程读不到）。

---

### 第 ④ 层：版本号漂移

bridge 会向上游上报 `COMMANDCODE_CLI_VERSION`（见手册 §2）。多台机器版本不一致本身是常见隐患，
排查时**先把它对齐再谈其它**。

**查（Windows）：**
```powershell
# bridge 实际版本
(Invoke-RestMethod http://127.0.0.1:9992/health).version
# .env 里上报的 CLI 版本
(Select-String -Path "$env:USERPROFILE\commandcode-bridge\.env" -Pattern '^COMMANDCODE_CLI_VERSION=').Line
```

**判定**：两处版本号应当**一致**（例如都是 `1.53.0` / `1.53.0.a`）。若不一致，或 Windows
精简版 `.env` 里**根本没有** `COMMANDCODE_CLI_VERSION` 这一项，建议补上：

```
COMMANDCODE_CLI_VERSION=1.53.0
```

> Windows 的 `env.windows.example` 是**单 key 精简版**，早期版本不含这一项。仓库基线已升到
> `1.53.0`，**以手册 §2 为准**顺手补齐。

---

### 第 ⑤ 层：共用同一把 key 的并发限制（只会“时好时坏”）

多台机器共用同一个 CommandCode 账号时，上游对**每个凭证有并发上限**（本机实测
`max_in_flight_per_credential = 4`）。一边打满，另一边的请求就会超时/被拒。

**判定**：`/health` 里的 `auth` 段：
```powershell
(Invoke-RestMethod http://127.0.0.1:9992/health).auth | ConvertTo-Json -Depth 5
# 关注 commandcode_credential_count / commandcode_max_in_flight_per_credential
```

> ⚠️ **这一层的特征：间歇性（有时通、有时断）**。如果你的现象是**“总是”连不上**，
> 直接**排除这一层**，回到 ①②③④ 去找。

---

### 第 ⑥ 层：跑着的进程，是不是最新的那份构建？（2026-09-18 新增）

**这一层的价值：它专门解释“我明明修了 / 明明照文档改了，问题照旧”。**

launchd（macOS）与任务计划（Windows）的 `KeepAlive`/看门狗**只在进程退出时才重启**。
`npm run build` 或改 `.env` 都**不会**触发重启 —— 于是磁盘上是新代码，内存里跑的是旧代码。
本机 2026-09-14 就是这样：`patches/0003` 已构建进 `dist/`，但 09-14 09:53 起的进程一直用到
09-18，期间 503 照旧复现，看上去像“补丁没用”。

> 补充（2026-09-30）：`KeepAlive` 同样检测不到「进程活着但 chat 路径僵死」的 **wedge** 状态
> （`/health` 秒回、chat 永久挂起，见速查表）。macOS 侧已加 `bridge_watchdog.sh` +
> `com.commandcode.bridge-watchdog.plist`（每 5 分钟主动探测 chat 路径，僵死自动 `kickstart`）。
> 注意它测的是 **chat 死活**，不是**构建新鲜度**——build 后没重启，仍要按本层 ⑥ 自查。
>
> 补充（2026-10-09）：**看门狗自己也会成为"服务有问题"的来源**——探针超时并不等于 bridge 僵死。
> macOS 侧实测：宿主机卡顿时（`fseventsd` 失控占 12 GB 内存 +100% CPU，load 22~27），旧的紧判据
> （`/health` 5s、chat 30s×2）把卡顿一路读成 wedge，10-09 一天重启 22 次、10-08 41 次，**全是误判**；
> 每次重启反而造成 10 秒~几分钟不可用并掐断在飞行中的请求。现行判据已改为分层：**端口无人监听 →
> 才立即拉起；端口在监听而 `/health` 超时 → 按"宿主机卡顿"记账，连续 3 轮才兜底；`/health` 正常而
> chat 连续 3 次超时（60s/次）→ 才判 wedge**；重启后轮询 90 秒再下结论（实测重启→就绪中位数 22 秒）。
> 因此遇到"服务有问题"时：**先量宿主机，再量 bridge** —— `uptime` / `top -l 3` 看 load 与 `fseventsd`、
> 可用内存、开机天数；bridge 进程本身 CPU 只有 ~1% 却响应很慢，通常说明它只是受害者。

```bash
# macOS：进程启动时间 vs dist 构建时间（dist 更新 → 说明改动没生效）
ls -lT ~/commandcode-bridge/dist/*.js | tail -3
ps -o pid,lstart,etime -p "$(lsof -ti :9992)"
launchctl print gui/$(id -u)/com.commandcode.bridge | grep -E "state|pid|runs"
```

**判定**：`dist` 里任一文件的 mtime **晚于**进程启动时间 → 就是这层。
**修法**：重载进程，别只 build。

```bash
launchctl kickstart -k gui/$(id -u)/com.commandcode.bridge   # macOS
# Windows：重启任务计划 / 结束 node 进程后让看门狗拉起
```

`scripts/doctor.sh` 的 ⑥ 会自动比对这两者并在不一致时报 `✗`。

---

### 第 ⑦ 层：传输上限与旧模型 ID 兜底（2026-09-18 新增）

两个**与配置是否“正确”无关**的高频故障，看 `.env` 两个键即可：

| 键 | 建议值 | 不设/设小会怎样 |
|---|---|---|
| `REQUEST_BODY_LIMIT_BYTES` | `16777216`（16 MiB） | 上游默认 **1 MiB**。长会话（历史累积）会被 Fastify 直接拒：`413 FST_ERR_CTP_BODY_TOO_LARGE`，Hermes 侧显示 `413 payload too large. Cannot compress further.`，用户以为“bridge 坏了”。模型上下文是 1M token（约 2~4 MB 请求体），不该由传输层先拒。 |
| `COMMANDCODE_LEGACY_MODEL_ALIAS` | `true` | 不开时，任何**还记得旧模型 ID** 的客户端会拿到 `400 Model "deepseek/deepseek-v4-flash" is not allowed`。旧 ID 的来源不是配置错误，而是客户端侧持久化：桌面端记住上次选的模型、**会话在创建时把模型名钉死**（旧会话改不回来）、另一台机器、cron 任务。开了之后旧 ID 在**请求侧**归一化到正式 ID，且不会重新出现在 `/v1/models` 里。 |

```bash
grep -E '^REQUEST_BODY_LIMIT_BYTES=|^COMMANDCODE_LEGACY_MODEL_ALIAS=' ~/commandcode-bridge/.env
```

**判定**：报 413 → 看上表第一行；报 `... is not allowed` → 看第二行。
**修法**：改 `.env` 后**必须重载进程**（见 ⑥），否则不生效。

> 取舍：`COMMANDCODE_LEGACY_MODEL_ALIAS=true` 时，若某台机器仍把旧 ID 放进
> `COMMANDCODE_ALLOWED_MODELS`，它的请求也会被改道到正式 ID。这正是预期（旧 ID 已退役），
> 但属于有意的行为改变，所以该开关**默认关闭、按机器显式打开**（上游代码零影响）。

---

## 3. 症状 → 病因速查表

| 症状 | 最可能原因 | 看哪一节 |
|---|---|---|
| 连不上 `127.0.0.1:9992` / ECONNREFUSED | bridge 没运行 | ① |
| `/health` 通，但每次对话都失败 | `.env` 缺 `COMMANDCODE_API_KEY` | ② |
| 每次请求 **401 Unauthorized** | 客户端 key ≠ `.env` 的 `BRIDGE_API_KEY` | ③ |
| 模型列表**为空** | bridge 没起(①)；或 Hermes 端 `models` 被存成字符串 | ① / 手册 §5.1 |
| 模型列表**重复**出现同一模型 | 上游把别名混入 `/v1/models` | 手册 §8 补丁 0001 |
| 某些模型报 `model_not_found` / 403 | 不在白名单 | 手册 §7 |
| 长会话突然报 **413 `Payload Too Large`** | `.env` 的 `REQUEST_BODY_LIMIT_BYTES` 太小（默认 1 MiB） | ⑦ |
| 选某个模型报 **400 `... is not allowed`**，但列表里明明有同类模型 | 客户端残留旧模型 ID（桌面端记住的选择 / 旧会话钉死 / 另一台机器） | ⑦ |
| 补丁/配置**改完没效果**、老问题照旧复现 | 进程跑的仍是旧构建（build 不触发 KeepAlive 重启） | ⑥ |
| **时好时坏**、间歇性超时 | 多机共用凭证的并发上限 | ⑤ |
| 对话中途断开、bridge 频繁重启 | 客户端取消流式请求触发的上游 `AbortError` 缺陷 | macOS：`patches/0002`（源码层修）；Windows：`run-with-guard.mjs` 运行时守卫。详见手册 §7 / §8 |
| 选某个模型报 *region not available* | 该模型在你所在区域不可用（如 `gpt-5.6-luna` 在大陆网络） | 换模型（如 `gpt-5.6-sol`） |
| 计划任务整轮失败、报 *provider unresponsive / no response received* | 上游长时间零响应，Hermes 看门狗放弃；先按 ⑥⑦ 排除本机因素，再查上游/额度 | ⑥ ⑦ + `/admin/commandcode/credentials` |
| 聊天**一直转圈**、无流式输出，但 `/health` 与 `/v1/models` 都正常 | bridge 进程「活着但 chat 路径僵死（wedge）」：chat 请求被接受却永不完成、无上游连接（运行数天后出现，2026-09-23 / 09-30 两次实测）。macOS 已有看门狗自动检测重启（`com.commandcode.bridge-watchdog`）；手动重启 `launchctl kickstart -k gui/$(id -u)/com.commandcode.bridge` | 看门狗 + 附录 A |
| bridge **反复重启** / 「服务有问题」但自检七层全绿 | **宿主机卡顿被误判成 bridge 故障**：`/health` 与 chat 探测超时（本机健康请求常态就有 24~28 秒），看门狗据此重启。先量宿主机：`uptime`（load vs 核数）、`top -l 3`（`fseventsd` 失控 / `kernel_task`）、可用内存与 pageout、开机天数。bridge 进程 CPU ~1% 却响应慢 ⇒ 它是受害者 | 附录 A ⑥ 的 2026-10-09 补充 + `~/commandcode-bridge/watchdog.log` |
| **每次重启 Hermes 后**弹 `agent init failed: No usable credentials found for provider 'commandcode'. Set COMMANDCODE_API_KEY.`（同一会话运行中却正常） | provider 名与 Hermes **内置**同名 provider 撞名：内置遮蔽用户条目（与该内置是否有凭据无关）；会话把旧名钉在 `state.db` 的 `model_config.provider`，重启恢复会话时解析失败 | 附录 C |

---

## 4. 为什么“完全照仓库做”仍可能失败（仓库复制不到的四类东西）

这不是操作失误，而是本地服务天然无法靠 clone 还原：

1. **机器专属绝对路径**：Windows 的 watchdog 脚本 / 任务计划、macOS 的 launchd plist 里都有
   占位符（`your-user` / `<user>`），**不替换就启动失败**。
2. **被 `.gitignore` 排除的 `.env`**：两把 key 都在里面，clone 拿不到；必须从 `*.example` 复制再填。
3. **客户端 key 的所在**：`COMMANDCODE_BRIDGE_API_KEY` 存在 **Hermes 私有 env** 里，**不在本仓库**，
   需要按手册 §4 单独写。
4. **模板会滞后**：`*.example` 模板可能与“某台已跑通的机器”之间存在**版本号漂移**（本文第 ④ 层）。

> 记住这条：**bridge `/v1/models` 是模型目录的唯一权威来源；Hermes 端不要再维护第二份白名单。**

---

## 附录 A：macOS 命令

macOS 用 **launchd** 自启（区别于 Windows 的任务计划）。对应五层：

```bash
BASE=http://127.0.0.1:9992
ENV_FILE=~/commandcode-bridge/.env

# ① bridge 在跑吗
launchctl print gui/$(id -u)/com.commandcode.bridge 2>&1 | grep -E "state|pid|last exit"
curl -fsS -m 5 "$BASE/health" || echo "✗ 连不上 $BASE"

# ② 上游 key 配置了吗
curl -fsS -m 5 "$BASE/health" | grep -o 'commandcode_api_key_configured":[a-z]*'
grep -E '^COMMANDCODE_API_KEY=' "$ENV_FILE" | sed 's/=.*/= <有值>/'

# ③ 客户端 key 与 bridge key 是否一致
grep -E '^BRIDGE_API_KEY=' "$ENV_FILE" | sed 's/=.*/= <有值>/'
echo "client key 长度: ${#COMMANDCODE_BRIDGE_API_KEY}"   # 与上面对照长度

# ④ 版本一致性
curl -fsS -m 5 "$BASE/health" | grep -o '"version":"[^"]*"'
grep -E '^COMMANDCODE_CLI_VERSION=' "$ENV_FILE"

# ⑤ 凭证与并发
curl -fsS -m 5 "$BASE/health" | grep -o 'commandcode_credential_count":[0-9]*'
```

macOS 的桥接资产在 `platforms/macos/`（plist 模板 + env 模板），安装见其 README。

---

## 附录 B：本节与主手册的关系

- 安装 / `.env` 配置 / 打补丁 / 模型目录 → **[SETUP-NEW-MACHINE.md](SETUP-NEW-MACHINE.md)**
  （§2 配 `.env`、§3 启动、§4 注册 provider、§5.1 模型列表问题、§7 故障表、§8 本地补丁）
- 为什么要 bridge（原理）→ **[WHY-BRIDGE.md](WHY-BRIDGE.md)**
- 本文只聚焦“**连接不上 / 模型不能用**”这一类问题的**分层定位**。

---

## 附录 C：provider 名撞内置 → 重启后报缺 `COMMANDCODE_API_KEY`（2026-10-12）

**症状**：每次重启 Hermes 后弹
`── Hermes error details ── agent init failed: No usable credentials found for provider 'commandcode'. Set COMMANDCODE_API_KEY.`
—— 但同一条会话在重启前用得好好的，bridge 七层自检全绿，也没有任何东西用过 `COMMANDCODE_API_KEY`。

**为什么**：`commandcode` 是 Hermes **内置模型 provider** 的正式名（安装树
`hermes-agent/plugins/model-providers/commandcode/`，直连 `api.commandcode.ai`，凭据变量就叫
`COMMANDCODE_API_KEY`）。解析规则在 `hermes_cli/runtime_provider_custom.py::_shadowed_by_builtin`：

```python
if requested_norm == "custom" or requested_norm.startswith("custom:"):
    return False                              # custom: 前缀 → 强制用你定义的条目
canonical = rp.auth_mod.resolve_provider(requested_norm)
return (canonical or "").lower() == requested_norm   # 请求名 == 内置正式名 → 遮蔽你的条目
```

**关键点：遮蔽只看名字，与内置插件有没有凭据无关**（所以“把 key 删掉就会回落到我的条目”是错的）。
内置 profile 也不归 `hermes plugins` 管（`plugins list` 里看不到，`plugins disable` 报 not found），
没有开关能关掉它 → **只能给自己的条目换个不撞名的名字**。

**为什么偏偏“重启后”才报**：会话创建时会把 provider 名钉进 `state.db` 的
`sessions.model_config.provider`；桌面端启动恢复会话时按名字解析 → 命中内置 → 认证失败 → 弹框。
运行中的会话带着自己钉死的 `base_url`，不走名字解析，所以看起来“重启前一切正常”。
更麻烦的是**桌面选择器对用户自定义 provider 输出的就是裸 slug**（`{"slug":"commandcode","is_user_defined":true}`，
用 `build_model_options_payload(...)` 可核实），因此从选择器新建的会话会继续存裸名，改名之前会不断复发。

**修法（mac 侧 2026-10-12 已执行，任一台机器照做）**：

```bash
# ① 改名（配置文件受保护，agent 不能直接改，必须走 hermes config；先 set 新名再 unset 旧名）
hermes config set providers.commandcode-bridge.name commandcode-bridge
hermes config set providers.commandcode-bridge.api "http://127.0.0.1:9992/v1"
hermes config set providers.commandcode-bridge.key_env COMMANDCODE_BRIDGE_API_KEY
hermes config set providers.commandcode-bridge.transport openai_chat
hermes config set providers.commandcode-bridge.default_model "deepseek/deepseek-v4.1-flash"
hermes config set providers.commandcode-bridge.discover_models true
hermes config unset providers.commandcode

# ② 把库里存了旧名的会话改过来（只有 model_config.provider 是功能位；
#    billing_provider、消息正文、cwd、标题里的同名串都是历史记录，别动）
sqlite3 ~/.hermes/state.db "update sessions set model_config=replace(model_config,'"provider": "commandcode"','"provider": "commandcode-bridge"') where json_extract(model_config,'$.provider')='commandcode';"
sqlite3 ~/.hermes/state.db "update sessions set model_config=replace(model_config,'"provider": "custom:commandcode"','"provider": "commandcode-bridge"') where json_extract(model_config,'$.provider')='custom:commandcode';"

# ③ 定时任务
hermes cron list                       # 取 job id
hermes cron edit <job_id> --provider custom:commandcode-bridge

# ④ 验证
hermes config get providers            # 只剩 commandcode-bridge
hermes chat -Q --provider commandcode-bridge -m deepseek/deepseek-v4.1-flash -q 'Reply exactly OK'
hermes chat -Q --provider custom:commandcode-bridge -m deepseek/deepseek-v4.1-flash -q 'Reply exactly OK'
```

⚠️ 别用 `commandcode` 当自己的 provider 名：`--provider commandcode` 永远走内置那条，必然失败
（实测：裸名报 `No usable credentials found ... Set COMMANDCODE_API_KEY`，`custom:` 前缀正常）。
新机器照 `SETUP-NEW-MACHINE.md` §4 的 `commandcode-bridge` 写法即可。

---

*本文由 mac 侧 Hermes 于 2026-09-11 依据一次实机排查整理。若你在自己的机器上按本文定位到了
新的一层原因，欢迎补进本文件并更新维护记录。*
