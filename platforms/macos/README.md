# macOS 平台资产

本目录由 **mac 上的 Hermes** 维护。内容：macOS 上跑通 CommandCode bridge 所需的全部自产资产。

## 文件清单

| 文件 | 用途 |
|---|---|
| `com.commandcode.bridge.plist` | launchd 自启配置（开机自动跑 bridge）。安装：复制到 `~/Library/LaunchAgents/`，改里面的用户路径，然后 `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.commandcode.bridge.plist` |
| `env.macos.example` | macOS 实际使用的 `.env` 脱敏模板（含 GOAT-31 + V4.1-Flash 共 32 个模型的白名单、本地补丁开关）。复制到 `~/commandcode-bridge/.env`，填入 `<填入你的值>` 处 |

## 路径约定（macOS）

- bridge 源码：`~/commandcode-bridge`（上游 clone，本地打了仓库 `patches/` 下三个补丁文件、共四处定制）
- 自启：`~/Library/LaunchAgents/com.commandcode.bridge.plist`
- 日志：`~/commandcode-bridge/bridge.stdout.log` / `bridge.stderr.log`
- Hermes provider 注册名：`custom:commandcode`（`providers.commandcode.api = http://127.0.0.1:9992/v1`）
- ⚠️ `~/commandcode-bridge/SETUP-NEW-MACHINE.md` 是**仓库手册的本地镜像副本**（非上游文件，未被 bridge 仓库跟踪）。
  用途：在现场改 bridge 时手边就有一份手册，不必切目录。**改动仓库版后必须同步此副本**（`cp docs/SETUP-NEW-MACHINE.md ~/commandcode-bridge/`），
  否则它会悄悄过期（2026-09-14 曾落后 56 行，仍写着旧的「35 个模型 / 两个补丁」）。
  该副本已在 bridge 的 `.prettierignore` 里排除——它是本地定制文档、与仓库版保持逐字节一致，**不应被 Prettier 重排**，
  否则 `npm run verify` 的 `format:check` 会卡在这里（这是 2026-09-14 之前 verify 一直跑不绿的原因）。

## 维护记录

- 2026-09-02：本机跑通。两处本地补丁（去别名 + 白名单唯一权威）已导出到仓库 `patches/0001-canonical-models-only.patch`，上游 `git pull` 后需重打。
- 2026-09-08：资产整理进仓库，本目录创建。
- 2026-09-08（第二台 mac 装机后对齐）：① 补丁改为 `git apply patches/0001-canonical-models-only.patch` 一键重打（patch 内字段为可选 `?: boolean`，测试零改动）；② Hermes 端不再维护静态 models 列表，改 `discover_models: true`（bridge `/v1/models` 唯一权威，手册 §5.1）；③ 本机实测 `gpt-5.6-luna` 报 region not available（`gpt-5.6-sol` 正常），provider `default_model` 定为 `deepseek/deepseek-v4-flash`；④ plist 用本目录模板（含 PATH + ProcessType）。
- 2026-09-10：上游升级 **1.38.2.a → 1.53.0.a**（`git pull` 两个 commit：1.49.0 + 1.53.0，目录 62 → 70 个模型）。升级流程：`git stash push -- src/config.ts src/types.ts` → `git pull --ff-only` → `git stash pop`（`src/config.ts` 自动合并成功，补丁**无需改动**，`patches/0001-*.patch` 与升级后工作区逐行一致）→ `npm install` → `npm run typecheck` / `lint` / `test`（226 passed）/ `build` 全绿 → `launchctl kickstart -k gui/$(id -u)/com.commandcode.bridge`。另把 `.env` 的 `COMMANDCODE_CLI_VERSION` 由 1.38.2 改为 **1.53.0**（该值向上游上报 CLI 版本，应随 bridge 版本一起走）。验证：`/health` → `version: 1.53.0.a`、`/v1/models` 仍为 34 个正式 ID（无别名）、冒烟对话 200。⚠️ 直接 `curl` 调 `/v1/chat/completions` 时 `max_tokens` 必须 ≥ 32（推理模型会先消耗可见输出预算，否则 502 `commandcode_empty_visible_response`）。
- 2026-09-11：DeepSeek 发布 **V4.1 Flash 正式版**，白名单 34 → **35**（主动放行 `deepseek/deepseek-v4.1-flash`，理由与旧名路由关系见手册 §6）。改动：`~/commandcode-bridge/.env`（已备份 `.env.bak-*`）+ 手册 + `config/env.example` + 本目录 `env.macos.example` + `platforms/pc/env.windows.example`。生效：`launchctl kickstart -k` → `/health` 35 个模型 → `hermes model --refresh`（Leave unchanged，默认模型未动）。验证：`/v1/chat/completions` 200，`hermes chat -Q --provider commandcode -m deepseek/deepseek-v4.1-flash` 正常返回。附带发现并修掉一条上游健壮性问题：客户端中断流式响应时 bridge 因未捕获 `AbortError` 直接退出（launchd 拉起），2026-09-03 起本机 67 次崩溃全由此而来。修复导出为 `patches/0002-stream-abort-error-handling.patch`（`src/provider-chat.ts` 来源流加 `'error'` 接管 + 新增 `tests/provider-chat.test.ts` 两条回归用例），RED→GREEN 验证通过，`npm run test` 226 → 228 passed。生产实例已重启验证：中断后进程存活、服务继续可用。
- 2026-09-11（模型名对齐 V4.1-Flash）：确认两条渠道的 V4.1 名字后统一改名——Hermes `providers.commandcode.default_model` 与 bridge `.env` `COMMANDCODE_DEFAULT_MODEL` 均改为 `deepseek/deepseek-v4.1-flash`；Hermes MoA 聚合器（**DeepSeek 官方** provider）的旧名 `deepseek-v4-flash` 改为正式名 `deepseek-flash`；两个 cron（日报 `89ebfc3149f0` / 周报 `0d0aacfae6ef`）的 model 用 `hermes cron edit --model` 改为 `deepseek/deepseek-v4.1-flash`；三个 env 模板同步。命名对照与判定证据见手册 §6（官方=**确定**：指纹相同 + 能读图 + 文档；CommandCode=**强证据但非证明**：价格一致 + 上游标 "(latest)" + 能读图，但其 `system_fingerprint` 每次请求随机，不可作判据）。同日复查补充：① 顺带统一了仓库自身的内部不一致（文档记 Hermes 默认 `deepseek-v4-flash`，三个 env 模板却是 `deepseek-v4-pro`）；② 默认取**钉死版** `deepseek/deepseek-v4.1-flash` 而非滚动别名（`deepseek/deepseek-v4-flash` 上游名带 "(latest)"，是滚动别名，今天同价同上下文）；③ ⚠️ 改 `default_model` **只影响新建会话**——Hermes 会话创建时把模型钉进 `sessions.model`，已存在的会话（含改名当时正在进行的对话）继续用旧模型、不追溯（详见手册 §4/§7/§8）。
- 2026-09-11（白名单瘦身：移除旧 v4-flash 三 ID）：用户反馈 CommandCode 选择器"还是显示 v4 flash"。根因：白名单里除钉死版 `deepseek/deepseek-v4.1-flash` 还留着旧的 `deepseek/deepseek-v4-flash`（滚动别名 "(latest)"）、`-flash-fast`、`-flash-vision-exp` 三个 ID，选择器把它们都列出来。三者现均由官方路由到 V4.1-Flash（-vision-exp 上游已无 provider），功能重叠，故移除：35 → **32**。改动：`~/commandcode-bridge/.env`（已备份）+ 手册 + `config/env.example` + 本目录 `env.macos.example` + `platforms/pc/env.windows.example`。生效：`launchctl kickstart -k` → `/health` 32 个、deepseek 仅剩 `v4-pro` + `v4.1-flash`。代价：失去滚动别名"自动跟随最新 Flash"的选项。
- 2026-09-11（连接排查资产）：新增 `docs/TROUBLESHOOTING-CONNECTION.md`（“连不上 / 模型不能用”的 5 层分层定位，Windows 为主 + macOS 附录）与一键自检脚本 `scripts/doctor.sh`（macOS/Linux）、`platforms/pc/doctor.ps1`（Windows）。起因：另一台机器报 connection error，据此逐层整理。`doctor.sh` 已在本机实测跑通（五层全绿）。
- 2026-09-14（patch 0003：请求成功后残留冷却致连发 503）：用户报 provider=commandcode / model=`deepseek/deepseek-v4.1-flash` 返回 503「No available CommandCode credentials for model ...」。根因**不在配置**（白名单、默认模型、`enabled`、额度、凭证状态全部正常，实测请求 200）：`credential-router.ts` 的 `recordSuccess()` 只释放并发计数、**不清冷却**，而 `recordFailure()` 遇 429/无状态码/5xx 会打 60s 冷却——于是「请求 A 内部撞 5xx 打上冷却 → 内部重试成功对外 200 → 冷却残留 → 接下来 60s 内所有请求被 `select()` 秒拒 503」。本机 09:10:17/19/24 三个 503 响应耗时仅 18~27ms（未发上游请求），与其后自愈的现象吻合。修复导出为 `patches/0003-cooldown-cleared-on-success.patch`（`src/credential-router.ts` + 3 条回归用例，含 1 条端到端），RED→GREEN 验证通过，`npm run test` 228 → **231 passed**；生产实例重启后连发 5 次请求全部 200。手册 §8 ④ 记录了症状特征（**前一请求成功返回后、紧接着的请求立刻 503 且耗时极短**）与排查入口 `/admin/commandcode/credentials`。
- 2026-09-14（本地树卫生：mirror 同步 + prettierignore）：① 同步 `SETUP-NEW-MACHINE.md` 镜像副本到仓库最新版（此前落后 56 行）；② bridge 的 `.prettierignore` 末尾加一行 `SETUP-NEW-MACHINE.md`——该 md 是本地定制文档、须与仓库逐字节一致，**不能被 Prettier 重排**；③ 结果：`npm run verify` 首次**全程退出码 0**（typecheck / lint / format:check / 231 tests / build 全绿）。
  ⚠️ 注意 `.prettierignore` **是上游跟踪文件**（非本地文件），这一行改动属于本地定制，上游 `git pull` 若冲突需重打；它与 `patches/` 三个补丁一起构成 bridge 工作区的全部本地改动（`git status` 看到的 6 个 src/tests 改动 = 三个补丁的内容，两处新增 = 本 md 镜像与 prettierignore）。
