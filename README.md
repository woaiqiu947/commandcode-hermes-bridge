# CommandCode Hermes Bridge

CommandCode 与 Hermes Agent 的本地桥接服务、安装配置、模型目录及故障排查文档。

## 简介 / Introduction

**中文**：面向 Hermes Agent 的 CommandCode 本地桥接与配置指南，包含安装步骤、GOAT 模型目录、模型列表故障排查，以及多语言说明。

**English**: Local CommandCode bridge and setup guide for Hermes Agent, including installation, GOAT model catalog, model-list troubleshooting, and multilingual documentation.

**Français** : Guide de configuration du bridge local CommandCode pour Hermes Agent, avec le catalogue des modèles GOAT et le dépannage.

**Deutsch**: Anleitung für die lokale CommandCode-Bridge mit Hermes Agent, einschließlich Installation, GOAT-Modellkatalog und Fehlerbehebung.

**Русский**: Руководство по локальному мосту CommandCode для Hermes Agent, включая установку, каталог моделей GOAT и устранение неполадок.

**日本語**: Hermes Agent 用 CommandCode ローカルブリッジのセットアップ、GOAT モデル一覧、トラブルシューティングガイドです。

**한국어**: Hermes Agent용 CommandCode 로컬 브리지 설치, GOAT 모델 목록 및 문제 해결 안내입니다.

## 文档 / Documentation

- [安装与配置手册 / Setup Guide](docs/SETUP-NEW-MACHINE.md)
- [连接错误排查手册 / Connection Troubleshooting](docs/TROUBLESHOOTING-CONNECTION.md)
- [为什么需要 bridge / Why a bridge?](docs/WHY-BRIDGE.md)

## 仓库结构（操作包 / Runbook）

本仓库不只是手册——它是 **mac 与 pc 两台机器的 Hermes 共同维护的"操作包"**：手册 + 可复用脚本/配置/补丁。平台无关资产放根目录，平台专属资产按平台分区（各平台由该机器的 Hermes 整理）。

```
commandcode-hermes-bridge/
├── docs/                  # 手册：SETUP（怎么装）+ TROUBLESHOOTING（连不上/模型不能用）+ WHY
├── config/
│   └── env.example        # 上游 .env 模板（平台无关）
├── patches/
│   ├── 0001-canonical-models-only.patch        # /v1/models 只列正式 ID + 白名单唯一权威
│   └── 0002-stream-abort-error-handling.patch  # 客户端中断流式请求不再崩 bridge 进程
├── scripts/
│   ├── probe_bridge_models.py   # 单飞探测模型可用性（跨平台）
│   └── doctor.sh                # 一键自检（macOS / Linux）
└── platforms/             # ★ 按平台分区的自产资产
    ├── macos/             # ← mac 的 Hermes 维护
    │   ├── README.md
    │   ├── com.commandcode.bridge.plist   # launchd 自启
    │   └── env.macos.example              # mac 实际 .env 脱敏模板
    └── pc/                # ← PC 的 Hermes 维护（Windows）
        ├── README.md
        ├── doctor.ps1                     # 一键自检（Windows）
        ├── env.windows.example            # PC 实际 .env 脱敏模板
        ├── CommandCodeBridgeWatchdog.xml  # 任务计划自启
        ├── watchdog_commandcode_bridge.py # 健康检查 + 自动拉起
        └── run-with-guard.mjs             # 启动守卫（吞上游 AbortError）
```

## 仓库用途

本仓库用于保存可复用的 CommandCode ↔ Hermes Agent 集成文档与配置说明，不包含任何 API key、密码或个人凭据。

## 安全提醒

- 不要把 `COMMANDCODE_API_KEY`、`BRIDGE_API_KEY` 或 `COMMANDCODE_BRIDGE_API_KEY` 提交到 Git。
- 认证信息只应保存在本机的 `.env` 或 Hermes 私有环境文件中。
- bridge 默认只监听 `127.0.0.1`。

## License

Documentation and configuration examples are provided under the MIT License. See [LICENSE](LICENSE).

---

CommandCode · Hermes Agent · OpenAI-compatible local bridge
