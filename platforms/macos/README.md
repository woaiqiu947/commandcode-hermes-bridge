# macOS 平台资产

本目录由 **mac 上的 Hermes** 维护。内容：macOS 上跑通 CommandCode bridge 所需的全部自产资产。

## 文件清单

| 文件 | 用途 |
|---|---|
| `com.commandcode.bridge.plist` | launchd 自启配置（开机自动跑 bridge）。安装：复制到 `~/Library/LaunchAgents/`，改里面的用户路径，然后 `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.commandcode.bridge.plist` |
| `env.macos.example` | macOS 实际使用的 `.env` 脱敏模板（含 GOAT-34 白名单、本地补丁开关）。复制到 `~/commandcode-bridge/.env`，填入 `<填入你的值>` 处 |

## 路径约定（macOS）

- bridge 源码：`~/commandcode-bridge`（上游 clone，本地打了两处补丁，见仓库 `patches/`）
- 自启：`~/Library/LaunchAgents/com.commandcode.bridge.plist`
- 日志：`~/commandcode-bridge/bridge.stdout.log` / `bridge.stderr.log`
- Hermes provider 注册名：`custom:commandcode`（`providers.commandcode.api = http://127.0.0.1:9992/v1`）

## 维护记录

- 2026-09-02：本机跑通。两处本地补丁（去别名 + 白名单唯一权威）已导出到仓库 `patches/0001-canonical-models-only.patch`，上游 `git pull` 后需重打。
- 2026-09-08：资产整理进仓库，本目录创建。
- 2026-09-08（第二台 mac 装机后对齐）：① 补丁改为 `git apply patches/0001-canonical-models-only.patch` 一键重打（patch 内字段为可选 `?: boolean`，测试零改动）；② Hermes 端不再维护静态 models 列表，改 `discover_models: true`（bridge `/v1/models` 唯一权威，手册 §5.1）；③ 本机实测 `gpt-5.6-luna` 报 region not available（`gpt-5.6-sol` 正常），provider `default_model` 定为 `deepseek/deepseek-v4-flash`；④ plist 用本目录模板（含 PATH + ProcessType）。
