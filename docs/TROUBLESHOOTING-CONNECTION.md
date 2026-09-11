# 连接错误排查手册 —— “另一台机器连不上 / 模型不能用”

> **适用症状**：Hermes 里用 `custom:commandcode` 时，模型列表为空、选不了模型、对话报
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

脚本会把下面第 2 节的五层检查**全部跑一遍并给出结论**（哪一层断了一目了然）。
如果想手动逐条查，照第 2 节做即可。

---

## 2. 五层定位法（手动版）

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

## 3. 症状 → 病因速查表

| 症状 | 最可能原因 | 看哪一节 |
|---|---|---|
| 连不上 `127.0.0.1:9992` / ECONNREFUSED | bridge 没运行 | ① |
| `/health` 通，但每次对话都失败 | `.env` 缺 `COMMANDCODE_API_KEY` | ② |
| 每次请求 **401 Unauthorized** | 客户端 key ≠ `.env` 的 `BRIDGE_API_KEY` | ③ |
| 模型列表**为空** | bridge 没起(①)；或 Hermes 端 `models` 被存成字符串 | ① / 手册 §5.1 |
| 模型列表**重复**出现同一模型 | 上游把别名混入 `/v1/models` | 手册 §8 补丁 0001 |
| 某些模型报 `model_not_found` / 403 | 不在白名单 | 手册 §7 |
| **时好时坏**、间歇性超时 | 多机共用凭证的并发上限 | ⑤ |
| 对话中途断开、bridge 频繁重启 | 客户端取消流式请求触发的上游 `AbortError` 缺陷 | macOS：`patches/0002`（源码层修）；Windows：`run-with-guard.mjs` 运行时守卫。详见手册 §7 / §8 |
| 选某个模型报 *region not available* | 该模型在你所在区域不可用（如 `gpt-5.6-luna` 在大陆网络） | 换模型（如 `gpt-5.6-sol`） |

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

*本文由 mac 侧 Hermes 于 2026-09-11 依据一次实机排查整理。若你在自己的机器上按本文定位到了
新的一层原因，欢迎补进本文件并更新维护记录。*
