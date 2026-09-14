# 为什么 CommandCode 需要一个本地 bridge？——架构说明

> 面向：想搞懂"Hermes 为什么不能像支持 opencode 那样直接支持 commandcode"的人。
> 一句话答案：**opencode 是开源的、有 CLI 的 agent，能被子进程驱动；commandcode 是闭源的订阅制 LLM 服务，只能走 provider 通道。后者缺的不是接入意愿，而是 CommandCode 官方没有一个公开的、稳定的 agent 接入接口。**
> 本文是 [SETUP-NEW-MACHINE.md](SETUP-NEW-MACHINE.md)（怎么装）的姊妹篇——讲为什么需要 bridge、为什么不"原生"。

## 1. 两类"支持"不是一回事

| | OpenCode（开源产品） | CommandCode（闭源订阅服务） |
|---|---|---|
| 本体 | 开源 CLI，Hermes 可直接当子进程调用 | 闭源，只有官方 Studio 客户端 + 一把账号级 API key |
| Hermes 接入方式 | `opencode run '...'` 子进程（有 skill 教程） | 只能走 OpenAI 兼容 provider 通道 |
| 凭据形态 | 用户自己的 API key | **订阅额度**（如 GOAT 31 模型），单把共享 key |
| Hermes "支持"的本质 | **skill + 子进程编排**，不是 provider 注册表条目 | **`custom:<name>` provider + 本地 bridge** |

关键认知：Hermes 对 opencode 的"支持"从来不是第一类公民式的 provider——它是把一个**开源的、可编程的 agent CLI** 当工人派活（`opencode run`）。而 commandcode 没有这样的 CLI 给你调；它只给你一把 key 和一个 OpenAI 兼容端点。这两者的接入姿势天然不同。

## 2. 为什么 Hermes 没有"原生" provider 支持 commandcode

Hermes 的 provider 注册表（`auth.py` 的 `PROVIDER_REGISTRY`）里有很多家的条目，但 commandcode 不在其中。原因不是"没意愿"，而是结构性：

1. **它不是开放 provider，是订阅服务。**
   CommandCode 没有公开的、可自助注册的 API 平台。用户拿到的不是"自己的 key + 官方 API 文档"，而是"一份订阅额度 + 官方客户端"。把某个订阅产品的私有端点写死进 agent 核心，违背 Hermes 的设计原则——核心只做窄腰，第三方产品不集成进核心树。

2. **模型列表是动态的、随订阅而变。**
   上游目录实际有 60+ 模型，但你的套餐只覆盖其中一部分（GOAT = 31 个）。Hermes 内置 provider 的模型列表是静态的（或从 models.dev 拉），commandcode 的可用列表**因人而异**，没法写死在核心。必须靠 `GET /v1/models` 动态发现——这正是 bridge 里那两处本地补丁（只列正式 ID、白名单唯一权威）存在的原因。

3. **凭据形态是"订阅路由"而非"单 key"。**
   `provider.ts` 里有完整的 `credential-router`、cooldown、retry-backoff、余额告警——这是把一把共享 key 当多路负载均衡用。这是订阅类产品的专属逻辑，不属于 agent 核心要内置的东西。

4. **Hermes 官方给的接入姿势，就是"本地 bridge + custom provider"。**
   你 Mac 上搭的 `custom:commandcode` → `http://127.0.0.1:9992/v1` → `https://api.commandcode.ai` 不是变通方案，**这就是 Hermes 设计上支持的接入方式**——`custom:<name>` provider 体系就是为了接这类本地代理/网关设计的。

## 3. 架构图

```
┌─────────────┐   OpenAI 兼容    ┌──────────────────┐   upstream API    ┌─────────────────────┐
│   Hermes    │ ───────────────▶ │ commandcode-      │ ────────────────▶ │  api.commandcode.ai  │
│  (agent)    │  http://127.0.0.1│ bridge (本地服务) │   订阅额度        │   (闭源订阅服务)      │
└─────────────┘  :9992/v1        └──────────────────┘                   └─────────────────────┘
        │                                │
  读 providers.<name>                .env 里两把 key:
  (custom:commandcode)                · COMMANDCODE_API_KEY  (上游订阅 key)
                                      · BRIDGE_API_KEY       (本地访问 key)
```

- **上游 key**（账号级，可多机器共用）只写在 bridge 自己的 `.env`，chmod 600。
- **本地 key**（随机 hex）同时出现在 bridge `.env` 和 Hermes 私有环境文件（`hermes config env-path`），Hermes 靠它跟 127.0.0.1 鉴权。
- 全程没有把上游 key 发进任何聊天/网络；bridge 只监听 `127.0.0.1`。

## 4. 那 "opencode 支持得好" 又是因为什么

因为 opencode **开源、有 CLI、可编程**。Hermes 的 opencode skill 本质上写的是"如何把 opencode CLI 当工人调"：`opencode run '...'`、`-f` 附文件、`--model` 指定模型、`--format json` 拿机器输出、后台 TUI + 进度轮询。这套是**进程编排**，和"原生 provider 支持"是两码事。

反过来，如果哪天 CommandCode 开源一个 CLI（或发布正式的 agent SDK / 稳定公开 API），Hermes 也可以像支持 opencode 一样出一个 skill 去调它。在那之前，bridge 就是最优解。

## 5. 真想要"更原生"，差什么

1. **CommandCode 官方发布公开、稳定的 provider 接入文档**：注册流程、API 契约、模型目录 API、订阅额度查询接口。没有这个，任何 agent 都无法"原生"接。
2. 在那之前，**本地 bridge 是最正确的做法**：凭据不出机器、模型列表动态同步、Hermes 侧零补丁。

## 6. 相关链接

- 安装与配置手册：[SETUP-NEW-MACHINE.md](SETUP-NEW-MACHINE.md)
- bridge 源码：https://github.com/yelixir-dev/commandcode-bridge
- Hermes 自定义 provider 文档：https://hermes-agent.nousresearch.com/docs/
