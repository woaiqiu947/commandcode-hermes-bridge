# PC 平台资产（Windows）

本目录由 **PC 上的 Hermes** 维护。内容：这台 Windows PC 上跑通 CommandCode bridge 所需的全部自产资产，含自启方案（区别于 mac 的 launchd）。

## 文件清单

| 文件 | 用途 |
|---|---|
| `env.windows.example` | PC 实际使用的 `.env` 脱敏模板（单 key 精简版，9 项）。复制到 `<bridge目录>/.env`，填入 `<填入你的值>` 处 |
| `doctor.ps1` | **连接错误一键自检**（5 层定位：bridge 是否在跑 / 上游 key / 本地 key 一致 / 版本一致 / 凭证并发）。`powershell -ExecutionPolicy Bypass -File doctor.ps1`，配套 `docs/TROUBLESHOOTING-CONNECTION.md` |
| `CommandCodeBridgeWatchdog.xml` | 任务计划程序 XML：每 1 分钟跑一次 watchdog。导入见下方「自启方案」 |
| `watchdog_commandcode_bridge.py` | 健康检查 + 自动拉起脚本。**使用前把顶部 `NODE` / `BRIDGE_DIR` 路径中的 `your-user` 换成你的 Windows 用户名** |
| `run-with-guard.mjs` | 启动守卫：吞上游流式断连 AbortError（上游 bug，node 直启 `dist/index.js` 会被打崩），真错误才退出交给 watchdog 拉起。复制到 bridge 仓库根目录使用 |

## 路径约定（Windows）

- bridge 源码：`C:\Users\<user>\commandcode-bridge`（上游 clone，本地打了仓库 `patches/` 三个补丁，见仓库 `patches/`；`run-with-guard.mjs` 与 `.env` 为本地未跟踪新增）
- Node：`C:\Users\<user>\AppData\Local\hermes\node\node.exe`（Hermes 自带 node，版本满足 bridge 要求）
- 自启：任务计划程序 `CommandCodeBridgeWatchdog`（每分钟，pythonw 无窗口）
- watchdog 脚本：`C:\Users\<user>\AppData\Local\hermes\scripts\watchdog_commandcode_bridge.py`
- 日志：bridge 目录内 `bridge.log`（主）/ `bridge.err.log` / `bridge.guard.log`（guard 自身）
- Hermes provider 注册名：`custom:commandcode`（`base_url = http://127.0.0.1:9992/v1`，`key_env = COMMANDCODE_BRIDGE_API_KEY`，见 `~/AppData/Local/hermes/config.yaml`）
- Hermes model_aliases：`cc-ds` → deepseek/deepseek-v4-pro、`cc-gpt` → gpt-5.6-sol、`cc-glm` → zai-org/GLM-5.2、`cc-qwen` → Qwen/Qwen3.8-Max（均走 `custom:commandcode`）

## 自启方案（任务计划，替代 mac 的 launchd）

`CommandCodeBridgeWatchdog.xml` 是当前机器导出的任务定义，要点：

- **触发**：TimeTrigger，每 1 分钟重复一次（`PT1M`），`MultipleInstancesPolicy=IgnoreNew`
- **动作**：`pythonw.exe C:\Users\<user>\AppData\Local\hermes\scripts\watchdog_commandcode_bridge.py`
- **逻辑**（watchdog 脚本内）：`/health` 通 → 无事退出；不通但有 bridge node 进程 → 等下一轮；都不满足 → `node run-with-guard.mjs` 拉起（`CREATE_NO_WINDOW`），6 秒后复查
- **注意**：任务与脚本中的 `<user>` 均为占位符（本机实测用户名），**使用前必须替换**：改 watchdog 顶部 `NODE`/`BRIDGE_DIR` 常量 → 放脚本到 hermes scripts 目录 → `schtasks /Create /TN CommandCodeBridgeWatchdog /XML CommandCodeBridgeWatchdog.xml /F`

## 补丁状态

- `patches/0001-canonical-models-only.patch` 两处本地定制（env 白名单唯一权威 + `/v1/models` 去别名只列正式 ID）**已在本地 `src/config.ts` / `src/types.ts` 应用**（2026-09-02）。
- `patches/0002-stream-abort-error-handling.patch`（2026-09-11，**mac 侧新增**）：修「客户端中断流式请求 → 未捕获 `AbortError` → bridge 进程退出」。**PC 若还没打，仍靠 `run-with-guard.mjs` 吞错误兜着**（见下表"启动方式"）——功能上不阻塞，但打上后可去掉那层 guard 兜底逻辑。
- 验证方法：`git apply --check patches/0001-canonical-models-only.patch` 报 `patch does not apply` = 已打；`src/config.ts` 内有 `// 本地定制（2026-09-02）` 注释；`src/provider-chat.ts` 内有 `source.on("error"` = 0002 已打。
- 上游 `git pull` 后需重打：`git apply patches/0001-canonical-models-only.patch patches/0002-stream-abort-error-handling.patch patches/0003-cooldown-cleared-on-success.patch`，然后 `npm run build`（若上游已合入则跳过）。

## 与 macOS 的差异

| 维度 | mac | PC（Windows） |
|---|---|---|
| 自启 | launchd plist（RunAtLoad + KeepAlive） | 任务计划 watchdog（每分钟健康检查，挂了才拉起） |
| 启动方式 | node 直启 `dist/index.js` | `run-with-guard.mjs`（吞 AbortError 防崩）→ dist/index.js |
| 日志 | `bridge.stdout.log` / `bridge.stderr.log` | `bridge.log` / `bridge.err.log` / `bridge.guard.log` |
| .env 模板 | 全量版（多 key / router 注释保留） | 精简版：单 key 模式 9 项，未启用多 key 与 commandcode-router |
| 网络 | 海外直连 | **大陆网络：gpt-5.6-luna 不可用**，客户端别名别选 luna（cc-gpt 默认已指向 gpt-5.6-sol） |

共同点：同一份 `.env` 语义、同一补丁、同一端口 `127.0.0.1:9992`、Hermes 侧同为 `custom:commandcode`。

## 维护记录

- 2026-09-04：watchdog + 任务计划自启跑通（进程拉起由 `run-with-guard.mjs` 守卫）。
- 2026-09-08：资产整理进仓库，本目录由占位改为实际内容。
- 2026-09-11（**待 PC 同步，mac 侧已改**）：① 白名单 34 → **35**，加 `deepseek/deepseek-v4.1-flash`；② 默认模型改 `deepseek/deepseek-v4.1-flash`（原 `deepseek/deepseek-v4-pro`）。命名对照与判定证据见手册 §6——**注意 CommandCode 与 DeepSeek 官方渠道的 V4.1 名字不同**（bridge 侧用 `deepseek/deepseek-v4.1-flash`，官方 API 用 `deepseek-flash`）。③ 可选：打 `patches/0002` 后去掉 `run-with-guard.mjs` 的 AbortError 兜底。
- 2026-09-11（白名单瘦身，**待 PC 同步，mac 侧已改**）：白名单移除旧 `deepseek/deepseek-v4-flash`（滚动别名 "(latest)"）、`-flash-fast`、`-flash-vision-exp` 三 ID（均路由到 V4.1-Flash，-vision-exp 上游无 provider），35 → **32**。PC 的 live `.env` 需同步删除这三个 ID 并重启（模板 `env.windows.example` 已更新为 32 个）。
- 2026-09-11：新增 `doctor.ps1`（连接错误一键自检），配套平台无关文档 `docs/TROUBLESHOOTING-CONNECTION.md`。
  说明：本机用 `run-with-guard.mjs` 在**运行时**吞掉上游 AbortError（见上「文件清单」），而 mac 侧是在
  **源码**层用 `patches/0002-stream-abort-error-handling.patch` 修同一缺陷——两种修法等价，PC 维持现有守卫方案即可。
- 2026-09-14（**待 PC 同步，mac 侧已改**）：新增 `patches/0003-cooldown-cleared-on-success.patch`——修「请求成功后残留冷却 → 之后 60s 内所有请求被秒拒 503 `No available CommandCode credentials for model ...`」（症状：前一个请求 200 后紧接着的请求立刻 503、耗时仅几十毫秒）。**PC 建议同步打上**（尤其多机共用一个凭证时命中概率更高）：`git apply patches/0003-*.patch && npm run build`，然后重启 bridge。重打命令见下方「本地补丁」一节。
- 2026-09-18（**待 PC 同步，mac 侧已改**；对应 mac 维护记录同日的三个故障）：三项，前两项建议照做——
  1. **`.env` 加两行**（模板已更新）：`REQUEST_BODY_LIMIT_BYTES=16777216`（原来是上游默认 1 MiB，长会话/history 累积到 1 MB 以上会被 Fastify 直接拒 `413 FST_ERR_CTP_BODY_TOO_LARGE`，Hermes 侧显示 `413 payload too large. Cannot compress further.`）与 `COMMANDCODE_LEGACY_MODEL_ALIAS=true`（旧 DeepSeek ID 在请求侧归一化到正式 ID，避免客户端残留旧 ID 拿 `400 ... is not allowed`）。**改完必须重启 bridge**（否则不生效）。
  2. **重打全部四个补丁**：`git apply patches/0001-*.patch patches/0002-*.patch patches/0003-*.patch patches/0004-*.patch && npm run build`（0004 是最新一个，**必须按序打**：其上下文依赖 0001 已应用），然后重启。⚠️ 只 build 不重启 = 改动不生效——这正是 mac 侧「补丁打了却一直没生效」的原因（launchd/任务计划的 KeepAlive 只在进程退出时才重启）。
  3. 可选：`doctor.ps1` 目前仍是五层；mac 侧 `doctor.sh` 已升到七层（新增 ⑥「运行进程 vs 最新构建」、⑦「传输上限 / 旧 ID 兜底开关」）。PC 若要对称，可照 `scripts/doctor.sh` 的 ⑥⑦ 两段补到 `doctor.ps1`（Windows 侧取时间戳用 `(Get-Item $f).LastWriteTime` 与 `(Get-Process -Id $pid).StartTime` 比较）。
- 2026-10-09（**待 PC 同步，mac 侧已改；新增第 6 项待办**）：mac 侧修了看门狗的**误判重启**，PC 侧需要对称。
  - **背景**：mac 的看门狗旧判据在 10-09 单日重启 22 次、10-08 单日 41 次，事后核对**全是误判**——根因是宿主机卡顿（`fseventsd` 失控占 12 GB 内存 +100% CPU，机器 70 天未重启，load 22~27），探针超时被一律读成 wedge。四处修法：先看端口有无监听（端口在监听 + `/health` 超时 → 按「宿主机卡顿」只记账，连续 3 轮才兜底）；超时放宽（`/health` 5s→10s、chat 30s→60s）；**重启后轮询 90 秒**再下结论（实测重启→listening 中位数 22 秒，旧版等 10 秒就报「需人工介入」= 每次重启都产生假警报）；探针 `max_tokens` 32→128（32 会触发上游空可见回复 502）。
  - **PC 现状（读 `watchdog_commandcode_bridge.py` 确认）**：它 `/health` 不通时**先看有没有 bridge 的 node 进程，有就等下一轮**——所以 PC **不会**像 mac 那样在宿主机卡顿时连环误判重启（这点比 mac 旧版安全）；代价是**它永远检测不到 wedge**（进程活着 + chat 僵死 = 一直「等下一轮」），即 09-30 记录的那个盲区在 PC 侧仍然存在。
  - **PC 要做的**：给 watchdog 加一条 chat 路径探测（`max_tokens ≥ 128`，超时 ≥ 60s），但**必须连同防误判的判据一起加**，否则会重演 mac 这次的问题：先查端口/进程存在（进程在 → 只记账，连续 3 轮才拉起）、`/health` 正常而 chat 连续 3 次超时才判 wedge、拉起后轮询 90 秒再下结论。实现与验证方式见 `platforms/macos/bridge_watchdog.sh`（脚本头部注释写了每条判据的理由）及其维护记录 2026-10-09 条。
