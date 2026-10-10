#!/bin/bash
# CommandCode bridge 看门狗：检测 chat 路径僵死（wedge）并自动重启。
#
# 为什么需要它：launchd 的 KeepAlive（以及 PC 侧现有的 watchdog）只在进程
# 「退出」时重启。bridge 存在一种「进程活着、/health 与 /v1/models 秒回、
# 但 /v1/chat/completions 永久挂起」的 wedge 状态——运行数天后出现，
# 2026-09-23 与 2026-09-30 两次实测都是它。KeepAlive 检测不到，用户只会
# 看到聊天一直转圈（/health 却是绿的，第一层自检永远「全通过」）。
#
# ── 2026-10-09 修订：判据必须能区分「bridge 僵死」和「宿主机卡顿」 ──────────
# 旧版判据在本机造成了 10-09 单日 22 次 / 10-08 单日 41 次重启，事后核对
# 全部是误判：当天宿主机（iMac，70 天未重启）上 fseventsd 失控占用 12GB 内存
# +100% CPU，整机只剩 657MB 可用内存、2098 万次 pageout，系统周期性卡顿几十秒。
# 结果链：卡顿 → 探针超时 → 旧版把超时一律读成 wedge → kickstart → 重启本身
# 又造成 10 秒~几分钟不可用、并掐断在飞行中的请求（用户感受就是「服务有问题」）。
# 四处改动（对应四处旧缺陷）：
#   1. 判据分层：先看端口有没有人监听。/health 是纯本地处理器（src/server.ts
#      里就是一个不碰网络的 async 对象），它超时基本只意味着操作系统调度不了
#      进程，即宿主机卡顿——这种「端口还在监听」的情况不再立刻重启（旧版会），
#      只记日志；连续 HOST_STALL_STRIKES 轮如此才兜底重启。
#      真 wedge 的特征相反：/health 正常、端口在监听，只有 chat 挂 → 才该重启。
#   2. 超时放宽：/health 5s→10s，chat 30s→60s。本机常态就有 24~28 秒的健康
#      请求（重载时），旧阈值落在正常抖动区间里，必然误报。chat 连续 3 次
#      超时（约 15 分钟）才判 wedge，不再「两次定罪」。
#   3. 重启后轮询 90 秒（旧版 sleep 5 + curl -m 5 = 10 秒就下结论，而实测
#      重启→listening 中位数 22 秒、最长 932 秒）→ 旧版每次重启都写一条
#      「重启后 /health 仍异常，需人工介入」的假警报（10-09 那天 22 条全是假的）。
#   4. 探针 max_tokens 32→128：32 会让上游回「空可见回复」→ 502（10-09 共 105 次），
#      既是日志噪声又白烧额度。
#
# 部署：launchd 定时任务 com.commandcode.bridge-watchdog，StartInterval=300（5 分钟）。
# 额度成本：每次探测 max_tokens=128 ≈ 180 token，5 分钟一次 ≈ 5 万 token/天，可忽略。
#
# 注意：只在「判定异常 / 重启 / 计数变化」时写日志，健康且无计数时静默退出。

set -u

ENV_FILE="$HOME/commandcode-bridge/.env"
BRIDGE_URL="http://127.0.0.1:9992"
PORT=9992
LOG_FILE="$HOME/commandcode-bridge/watchdog.log"
STATE_FILE="$HOME/commandcode-bridge/.watchdog_state"
LABEL="com.commandcode.bridge"

HEALTH_TIMEOUT=10        # /health 本地路径，10 秒还不回基本就是整机卡住
CHAT_TIMEOUT=60          # 实测健康请求常态 24~28 秒（重载时），60 秒留足余量
PROBE_MAX_TOKENS=128     # 32 会触发上游「空可见回复」502，纯噪声
WEDGE_STRIKES=3          # chat 连续 3 次超时才判 wedge（约 15 分钟）
HOST_STALL_STRIKES=3     # 端口在监听但 /health 不通：连续 3 轮才兜底重启

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG_FILE"
}

# 当前负载（写进异常日志，方便事后判断是桥的问题还是机器的问题）
load_now() {
  sysctl -n vm.loadavg 2>/dev/null | tr -d '{}' | tr -s ' '
}

# 计数落盘：跨轮次累计，避免单次抽风就重启
chat_strikes=0
host_strikes=0
read_state() {
  if [ -f "$STATE_FILE" ]; then
    v=$(grep -E '^chat_strikes=[0-9]+$' "$STATE_FILE" 2>/dev/null | cut -d= -f2)
    [ -n "$v" ] && chat_strikes=$v
    v=$(grep -E '^host_strikes=[0-9]+$' "$STATE_FILE" 2>/dev/null | cut -d= -f2)
    [ -n "$v" ] && host_strikes=$v
  fi
}
save_state() {
  printf 'chat_strikes=%s\nhost_strikes=%s\n' "$chat_strikes" "$host_strikes" > "$STATE_FILE"
}

# 端口有没有人监听——这是「bridge 进程还在不在」最直接的证据
listener_pid() {
  lsof -ti :"$PORT" -sTCP:LISTEN 2>/dev/null | head -1
}

# 读配置（只取变量值，绝不把 key 打印到 stdout）
BRIDGE_KEY=$(grep -E '^BRIDGE_API_KEY=' "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '[:space:]')
MODEL=$(grep -E '^COMMANDCODE_DEFAULT_MODEL=' "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '[:space:]')
if [ -z "$MODEL" ]; then
  MODEL="deepseek/deepseek-v4.1-flash"
fi

restart_bridge() {
  log "执行 launchctl kickstart -k gui/$(id -u)/$LABEL"
  launchctl kickstart -k "gui/$(id -u)/$LABEL" >> "$LOG_FILE" 2>&1
  # 轮询而不是「睡 5 秒就下结论」：实测重启→listening 中位数 22 秒、最长 932 秒
  elapsed=0
  while [ "$elapsed" -lt 90 ]; do
    sleep 3
    elapsed=$((elapsed + 3))
    if curl -s -m 5 "$BRIDGE_URL/health" | grep -q '"status":"ok"'; then
      log "重启后 /health 恢复（第 ${elapsed} 秒）"
      chat_strikes=0
      host_strikes=0
      save_state
      return 0
    fi
  done
  log "重启后 90 秒内 /health 未恢复，需人工介入"
  chat_strikes=0
  host_strikes=0
  save_state
  return 1
}

read_state

# ── 1. 端口还有人监听吗？ ────────────────────────────────────
PID=$(listener_pid)
if [ -z "$PID" ]; then
  log "端口 ${PORT} 无人监听（bridge 进程已退出），kickstart 拉起"
  restart_bridge
  exit 0
fi

# ── 2. health 探测 ──────────────────────────────────────────
if ! curl -s -m "$HEALTH_TIMEOUT" "$BRIDGE_URL/health" | grep -q '"status":"ok"'; then
  # /health 不碰网络，端口又在监听 → 优先怀疑宿主机卡顿，而不是 bridge 僵死。
  # 这种情况重启 bridge 不解决问题，反而掐断在飞行中的请求，所以先只记账。
  host_strikes=$((host_strikes + 1))
  save_state
  log "端口 ${PORT} 在监听（pid=${PID}）但 /health 超时（${HEALTH_TIMEOUT}s），第 ${host_strikes}/${HOST_STALL_STRIKES} 次，疑似宿主机卡顿（load:$(load_now)），暂不重启"
  if [ "$host_strikes" -lt "$HOST_STALL_STRIKES" ]; then
    exit 0
  fi
  log "连续 ${HOST_STALL_STRIKES} 轮 /health 无响应，兜底 kickstart"
  restart_bridge
  exit 0
fi
host_strikes=0
save_state

# ── 3. chat 探测（max_tokens>=128，避免上游「空可见回复」） ──
PROBE_BODY="{\"model\":\"$MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"ping\"}],\"max_tokens\":$PROBE_MAX_TOKENS}"

chat_probe() {
  curl -s -o /dev/null -w '%{http_code}' -m "$CHAT_TIMEOUT" \
    -X POST "$BRIDGE_URL/v1/chat/completions" \
    -H 'Content-Type: application/json' \
    -H "Authorization: Bearer $BRIDGE_KEY" \
    -d "$PROBE_BODY" 2>/dev/null
}

CODE=$(chat_probe)
if [ "$CODE" = "200" ]; then
  if [ "$chat_strikes" != "0" ]; then
    chat_strikes=0
    save_state
  fi
  exit 0    # 健康
fi

# 有 HTTP 响应但非 200：bridge 有响应，非 wedge（额度/冷却/模型），重启无效
if [ -n "$CODE" ] && [ "$CODE" != "000" ]; then
  chat_strikes=0
  save_state
  log "chat 探测返回 HTTP ${CODE}（有响应、非超时），非 wedge，跳过重启"
  exit 0
fi

# 超时（http_code=000）→ 累计计数，连续 WEDGE_STRIKES 次才判定 wedge
chat_strikes=$((chat_strikes + 1))
save_state
log "chat 探测超时（${CHAT_TIMEOUT}s 无响应），第 ${chat_strikes}/${WEDGE_STRIKES} 次（load:$(load_now)）"
if [ "$chat_strikes" -lt "$WEDGE_STRIKES" ]; then
  exit 0
fi

log "chat 连续 ${WEDGE_STRIKES} 次超时且 /health 正常 → 判定 wedge，重启 bridge"
restart_bridge
exit 0
