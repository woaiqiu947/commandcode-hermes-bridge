#!/usr/bin/env bash
# CommandCode bridge 一键自检（macOS / Linux）
#
# 用法:
#   bash scripts/doctor.sh [bridge目录]      # 默认 ~/commandcode-bridge
#   BASE=http://127.0.0.1:9992 bash scripts/doctor.sh
#
# 逐层检查 bridge 是否可用，并在结尾给出结论。配套文档:
#   docs/TROUBLESHOOTING-CONNECTION.md
#
# 安全: 只打印 key 的“有值/长度”，绝不打印 key 本身。

set -u

BASE="${BASE:-http://127.0.0.1:9992}"
BRIDGE_DIR="${1:-$HOME/commandcode-bridge}"
ENV_FILE="$BRIDGE_DIR/.env"

if [ -t 1 ]; then
  G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; B=$'\033[1m'; N=$'\033[0m'
else
  G=''; R=''; Y=''; B=''; N=''
fi
ok()   { printf '  %s✓%s %s\n' "$G" "$N" "$1"; }
bad()  { printf '  %s✗%s %s\n' "$R" "$N" "$1"; }
warn() { printf '  %s!%s %s\n' "$Y" "$N" "$1"; }
hr()   { printf '%s\n' "------------------------------------------------------------"; }

# 从 .env 读一个键的值（不存在则空）。不打印值，只给长度。
env_val() { [ -f "$ENV_FILE" ] && sed -n "s/^$1=\(.*\)\$/\1/p" "$ENV_FILE" | head -n 1 || true; }
shot_len() { # $1=value $2=label
  if [ -n "${1:-}" ]; then ok "$2 已设置（长度 ${#1}）"; else bad "$2 缺失/为空"; fi
}

PROBLEMS=0

printf '%sCommandCode bridge 自检%s\n' "$B" "$N"
printf 'bridge 接口: %s\n' "$BASE"
printf 'bridge 目录: %s\n' "$BRIDGE_DIR"
printf 'env  文件  : %s\n' "$ENV_FILE"
hr

# ---------- ① bridge 活着吗 ----------
printf '[①] bridge 是否在监听\n'
HEALTH=""
HEALTH_ERR=""
if HEALTH_OUT="$(curl -fsS -m 10 "$BASE/health" 2>&1)"; then
  HEALTH="$HEALTH_OUT"
else
  HEALTH_ERR="$HEALTH_OUT"
fi
VER=''
if [ -n "$HEALTH" ]; then
  VER="$(printf '%s' "$HEALTH" | sed -n 's/.*"version": *"\([^"]*\)".*/\1/p')"
  ok "bridge 存活（version=${VER:-?}）"
  printf '      %s\n' "$HEALTH"
else
  if [ -n "$HEALTH_ERR" ]; then bad "连不上 $BASE —— bridge 没运行（${HEALTH_ERR}）"
  else bad "连不上 $BASE —— bridge 没运行"; fi
  warn "macOS: launchctl print gui/\$(id -u)/com.commandcode.bridge"
  warn "见 TROUBLESHOOTING-CONNECTION.md 第 ① 层"
  PROBLEMS=$((PROBLEMS + 1))
fi
hr

# ---------- ② 上游 key 配置了吗 ----------
printf '[②] .env 的上游 COMMANDCODE_API_KEY\n'
if [ -n "$HEALTH" ]; then
  CFG="$(printf '%s' "$HEALTH" | sed -n 's/.*"commandcode_api_key_configured": *\([a-z]*\).*/\1/p')"
  if [ "$CFG" = "true" ]; then ok "/health 报告 commandcode_api_key_configured=true"
  else bad "/health 报告 commandcode_api_key_configured=${CFG:-?} —— 上游 key 没被 bridge 读到"; PROBLEMS=$((PROBLEMS + 1)); fi
fi
shot_len "$(env_val COMMANDCODE_API_KEY)" "COMMANDCODE_API_KEY"
hr

# ---------- ③ 本地访问 key 是否两端一致 ----------
printf '[③] 本地访问 key（bridge 的 BRIDGE_API_KEY ↔ 客户端的 COMMANDCODE_BRIDGE_API_KEY）\n'
BKEY="$(env_val BRIDGE_API_KEY)"
shot_len "$BKEY" "bridge 侧 BRIDGE_API_KEY"
CKEY="${COMMANDCODE_BRIDGE_API_KEY:-}"
if [ -n "$CKEY" ]; then
  if [ -n "$BKEY" ] && [ "$CKEY" = "$BKEY" ]; then ok "客户端 COMMANDCODE_BRIDGE_API_KEY 与 bridge 一致"
  else bad "客户端 key 与 bridge 的 BRIDGE_API_KEY 不一致（会导致每次 401）"; PROBLEMS=$((PROBLEMS + 1)); fi
else
  warn "当前 shell 未加载 COMMANDCODE_BRIDGE_API_KEY（Hermes 运行时才有）——若 Hermes 报 401 查这里"
fi
hr

# ---------- ④ 版本一致性 ----------
printf '[④] 版本一致性（COMMANDCODE_CLI_VERSION ↔ bridge 版本）\n'
CLIVER="$(env_val COMMANDCODE_CLI_VERSION)"
if [ -n "$CLIVER" ]; then
  if [ -n "$VER" ] && [ "${VER%%.a}" = "${CLIVER%%.a}" ]; then ok "CLI_VERSION=$CLIVER 与 bridge=$VER 一致"
  else warn "CLI_VERSION=${CLIVER:-<空>} 与 bridge=${VER:-?} 不一致 —— 见文档第 ④ 层"; fi
else
  warn ".env 没有 COMMANDCODE_CLI_VERSION（可选，建议与 bridge 版本一致）"
fi
hr

# ---------- ⑤ 模型目录 + 凭证并发 ----------
printf '[⑤] 模型目录（/v1/models）与凭证\n'
if [ -n "$BKEY" ]; then
  MJ=""
  MERR=""
  if MJ_OUT="$(curl -fsS -m 15 "$BASE/v1/models" -H "Authorization: Bearer $BKEY" 2>&1)"; then
    MJ="$MJ_OUT"
  else
    MERR="$MJ_OUT"
  fi
  if [ -n "$MJ" ]; then
    CNT="$(printf '%s' "$MJ" | grep -o '"id"' | wc -l | tr -d ' ')"
    if [ "$CNT" -gt 0 ]; then ok "/v1/models 返回 $CNT 个模型"
    else warn "/v1/models 返回 0 个模型 —— 见手册 §5.1"; fi
  else
    if [ -n "$MERR" ]; then bad "/v1/models 拿不到数据（key 不对会 401）：$MERR"
    else bad "/v1/models 拿不到数据（key 不对会 401）"; fi
    PROBLEMS=$((PROBLEMS + 1))
  fi
fi
if [ -n "$HEALTH" ]; then
  printf '%s\n' "$HEALTH" | grep -o 'commandcode_credential_count": *[0-9]*' | sed 's/^/      /'
  printf '%s\n' "$HEALTH" | grep -o 'commandcode_max_in_flight_per_credential": *[0-9]*' | sed 's/^/      /'
  warn "多机共用同一凭证时，注意上面的并发上限（现象为“时好时坏”，见文档第 ⑤ 层）"
fi
hr

# ---------- ⑥ 运行中的进程是否真的跑着最新构建 ----------
# 2026-09-18 新增：本机出现过"补丁已构建、但 launchd 里的进程还是旧代码"的情况——
# 表现为"修了还是坏 / 天天出问题"。KeepAlive 只在进程退出时才重启，重新 build 不会触发。
printf '[⑥] 运行中的进程 vs 最新构建\n'
if [ -n "$VER" ]; then
  PORT_NUM="$(printf '%s' "$BASE" | sed -n 's#.*:\([0-9][0-9]*\).*#\1#p')"
  [ -n "$PORT_NUM" ] || PORT_NUM=9992
  PID="$(lsof -nP -tiTCP:"$PORT_NUM" -sTCP:LISTEN 2>/dev/null | head -n 1)"
  DIST_DIR="$BRIDGE_DIR/dist"
  if [ -n "$PID" ] && [ -d "$DIST_DIR" ]; then
    case "$(uname -s)" in
      Darwin)
        PROC_START="$(date -j -f '%a %b %d %T %Y' "$(ps -o lstart= -p "$PID" | sed 's/^ *//')" +%s 2>/dev/null || echo '')"
        NEWEST=0
        for f in "$DIST_DIR"/*.js; do [ -f "$f" ] || continue; m="$(stat -f %m "$f")"; [ "$m" -gt "$NEWEST" ] && NEWEST="$m"; done
        NEWEST_NAME="$(ls -t "$DIST_DIR"/*.js 2>/dev/null | head -n 1)"
        ;;
      *)
        PROC_START="$(date -d "$(ps -o lstart= -p "$PID")" +%s 2>/dev/null || echo '')"
        NEWEST=0
        for f in "$DIST_DIR"/*.js; do [ -f "$f" ] || continue; m="$(stat -c %Y "$f")"; [ "$m" -gt "$NEWEST" ] && NEWEST="$m"; done
        NEWEST_NAME="$(ls -t "$DIST_DIR"/*.js 2>/dev/null | head -n 1)"
        ;;
    esac
    printf '      pid=%s  进程启动=%s  dist 最新=%s\n' "$PID" "${PROC_START:-?}" "${NEWEST:-?}"
    if [ -n "${PROC_START:-}" ] && [ -n "${NEWEST:-}" ] && [ "$NEWEST" -gt "$PROC_START" ]; then
      bad "dist 比进程新 —— 当前进程跑的仍是旧构建，补丁/配置改动还没生效"
      warn "重载后端进程：launchctl kickstart -k gui/\$(id -u)/com.commandcode.bridge"
      warn "（build 不会触发 KeepAlive 重启，这是「修了还是坏」的常见原因）"
      PROBLEMS=$((PROBLEMS + 1))
    else
      ok "进程启动时间不早于 dist 构建时间 —— 跑的就是最新构建"
    fi
  else
    warn "拿不到监听进程或 $DIST_DIR —— 跳过（不影响其它层）"
  fi
fi
hr

# ---------- ⑦ 传输上限与旧 ID 兜底开关 ----------
printf '[⑦] 传输上限（REQUEST_BODY_LIMIT_BYTES）与旧 ID 兜底（COMMANDCODE_LEGACY_MODEL_ALIAS）\n'
BODY_LIMIT="$(env_val REQUEST_BODY_LIMIT_BYTES)"
if [ -n "$BODY_LIMIT" ]; then
  if [ "$BODY_LIMIT" -ge 4194304 ] 2>/dev/null; then
    ok "REQUEST_BODY_LIMIT_BYTES=${BODY_LIMIT}（$((BODY_LIMIT / 1048576)) MiB）"
  else
    bad "REQUEST_BODY_LIMIT_BYTES=$BODY_LIMIT 偏小 —— 长会话会被 413 Payload Too Large 拒掉"
    warn "建议 16777216（16 MiB）：模型上下文是 1M token，不该由传输层先拒。见文档 §413"
    PROBLEMS=$((PROBLEMS + 1))
  fi
else
  warn "未设置 REQUEST_BODY_LIMIT_BYTES —— 将使用上游默认 1048576（1 MiB），长会话会 413"
fi
LEGACY_ALIAS="$(env_val COMMANDCODE_LEGACY_MODEL_ALIAS)"
case "$(printf '%s' "${LEGACY_ALIAS:-}" | tr '[:upper:]' '[:lower:]')" in
  1|true|yes|on) ok "COMMANDCODE_LEGACY_MODEL_ALIAS 已开启（旧 ID 请求侧兜底到正式 ID）" ;;
  *) warn "COMMANDCODE_LEGACY_MODEL_ALIAS 未开启 —— 客户端残留的旧模型 ID 会 400 model_not_allowed" ;;
esac
hr

# ---------- 结论 ----------
if [ -z "$HEALTH" ]; then
  printf '%s结论: bridge 未运行 —— 先解决第 ① 层。%s\n' "$R$B" "$N"
elif [ "$PROBLEMS" -eq 0 ]; then
  printf '%s结论: 七层检查全部通过。%s\n' "$G$B" "$N"
else
  printf '%s结论: 发现 %d 处问题（见上面的 ✗）。%s\n' "$R$B" "$PROBLEMS" "$N"
fi

exit 0
