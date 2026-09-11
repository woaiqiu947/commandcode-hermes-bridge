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

- bridge 源码：`C:\Users\<user>\commandcode-bridge`（上游 clone，本地打了两处补丁，见仓库 `patches/`；`run-with-guard.mjs` 与 `.env` 为本地未跟踪新增）
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
- 上游 `git pull` 后需重打：`git apply patches/0001-canonical-models-only.patch patches/0002-stream-abort-error-handling.patch`，然后 `npm run build`（若上游已合入则跳过）。

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
- 2026-09-11：新增 `doctor.ps1`（连接错误一键自检），配套平台无关文档 `docs/TROUBLESHOOTING-CONNECTION.md`。
  说明：本机用 `run-with-guard.mjs` 在**运行时**吞掉上游 AbortError（见上「文件清单」），而 mac 侧是在
  **源码**层用 `patches/0002-stream-abort-error-handling.patch` 修同一缺陷——两种修法等价，PC 维持现有守卫方案即可。
