#!/system/bin/sh
# switch.sh —— 小柠檬门面金丝雀切换 v1.5.0（261111）
# 铁序（断链事故教训）：①备用通道先验活 → ②新版备用口预热自检 → ③替换 → ④自检 → 失败自动回滚
# 用法：sh switch.sh <新代理py文件名>     例：sh switch.sh slim_proxy_v132.py
# 环境覆盖（测试用）：SWITCH_HOME / SWITCH_PORT / SWITCH_PORT2 / SWITCH_MAINT_PORT / SWITCH_PY

set -u
HOME_DIR=${SWITCH_HOME:-/data/lemonbrain/slimproxy}
PORT=${SWITCH_PORT:-8791}
PORT2=${SWITCH_PORT2:-8792}
MAINT_PORT=${SWITCH_MAINT_PORT:-8795}
PY=${SWITCH_PY:-/data/data/com.termux/files/usr/bin/python3}
LOG=${SWITCH_LOG:-/data/lemonbrain/logs/switch.log}
export LEMON_HOME=${LEMON_HOME:-/data/lemonbrain}
NEW_FILE="$1"

[ -f "$HOME_DIR/$NEW_FILE" ] || { echo "缺少 $HOME_DIR/$NEW_FILE"; exit 1; }

# 备用通道令牌（健康检查也要鉴权——备用通道对未授权请求一律 404）
TOK_DIR=${SWITCH_TOKEN_DIR:-$HOME_DIR}
MTOK=""
[ -f "$TOK_DIR/.token_maint" ] && MTOK=$(cat "$TOK_DIR/.token_maint" 2>/dev/null)
[ -z "$MTOK" ] && [ -f "$TOK_DIR/.token" ] && MTOK=$(cat "$TOK_DIR/.token" 2>/dev/null)

say() { echo "$*"; echo "[$(date '+%m-%d %H:%M:%S')] $*" >> "$LOG" 2>/dev/null; }

hexport() { printf "%X" "$1"; }
port_up() {
  HEX=$(hexport "$1")
  awk -v h=":$HEX" '$2 ~ h"$" && $4 == "0A" {f=1} END {exit !f}' /proc/net/tcp 2>/dev/null
}

health() {  # $1=port $2=期望版本(可空) $3=令牌(可空，Bearer header)
  if [ -n "${3:-}" ]; then
    V=$(curl -s --max-time 5 -H "Authorization: Bearer $3" "http://127.0.0.1:$1/" 2>/dev/null | sed -n 's/.*"version": *"\([^"]*\)".*/\1/p')
  else
    V=$(curl -s --max-time 5 "http://127.0.0.1:$1/" 2>/dev/null | sed -n 's/.*"version": *"\([^"]*\)".*/\1/p')
  fi
  [ -z "$V" ] && return 1
  [ -n "$2" ] && [ "$V" != "$2" ] && return 1
  echo "$V"
  return 0
}

# ① 备用通道验活（不在就先拉起；还死就拒绝开工）
say "① 检查备用维护通道 :$MAINT_PORT"
if ! port_up "$MAINT_PORT"; then
  say "备用通道未起，拉起 maint_server"
  sh "$HOME_DIR/start_maint.sh" >/dev/null 2>&1
  sleep 2
fi
if ! port_up "$MAINT_PORT"; then
  say "✗ 备用通道不可用，拒绝切换（先修好保命线）"
  exit 2
fi
MV=$(health "$MAINT_PORT" "" "$MTOK") || { say "✗ 备用通道健康检查失败，拒绝切换"; exit 2; }
say "备用通道存活（v$MV）✓"

# ② 新版备用口预热（8793，不干扰在役服务）
PRE_PORT=${SWITCH_PRE_PORT:-8793}
NEW_VER=$(grep -m1 '^VERSION = ' "$HOME_DIR/$NEW_FILE" | sed 's/.*"\(.*\)".*/\1/')
say "② 预热 $NEW_FILE (v$NEW_VER) 于 :$PRE_PORT"
env LEMON_SLIM_PORT=$PRE_PORT LEMON_SLIM_PORT2=${SWITCH_PRE_PORT2:-18794} "$PY" -u "$HOME_DIR/$NEW_FILE" >> ${SWITCH_PROXY_LOG:-/data/lemonbrain/logs/slimproxy.log} 2>&1 &
PRE_PID=$!
i=0
while [ $i -lt 16 ]; do port_up $PRE_PORT && break; sleep 0.5; i=$((i+1)); done
if ! port_up $PRE_PORT; then
  say "✗ 新版预热失败（进程 $PRE_PID 未监听），不动旧版"
  kill $PRE_PID 2>/dev/null
  exit 3
fi
PV=$(health $PRE_PORT "$NEW_VER") || { say "✗ 新版预热健康检查失败"; kill $PRE_PID 2>/dev/null; exit 3; }
say "新版预热自检通过（v$PV）✓"

# ③ 替换：停旧（确认死透）→ 起新
say "③ 停旧版"
OLD_PID=""
[ -f "$HOME_DIR/.slim.$PORT.pid" ] && OLD_PID=$(cat "$HOME_DIR/.slim.$PORT.pid" 2>/dev/null)
sh "$HOME_DIR/stop.sh" >/dev/null 2>&1
i=0
while [ $i -lt 20 ]; do
  port_up $PORT || break
  [ $i -eq 10 ] && [ -n "$OLD_PID" ] && kill -9 "$OLD_PID" 2>/dev/null
  sleep 0.5
  i=$((i+1))
done
if port_up $PORT; then
  say "✗ 旧版拒绝退出，中止切换（新版预热实例一并清理）"
  kill $PRE_PID 2>/dev/null
  exit 4
fi
env LEMON_SLIM_PORT=$PORT LEMON_SLIM_PORT2=$PORT2 "$PY" -u "$HOME_DIR/$NEW_FILE" >> ${SWITCH_PROXY_LOG:-/data/lemonbrain/logs/slimproxy.log} 2>&1 &
NEW_PID=$!

# ④ 上线自检（本机口+公网口），失败自动回滚
i=0
while [ $i -lt 16 ]; do port_up $PORT && break; sleep 0.5; i=$((i+1)); done
OK=1
V=$(health $PORT "$NEW_VER") || OK=0
if [ $OK -eq 1 ] && [ -f "$HOME_DIR/.token" ]; then
  i=0
  while [ $i -lt 16 ]; do port_up $PORT2 && break; sleep 0.5; i=$((i+1)); done
  port_up $PORT2 || OK=0
fi
if [ $OK -eq 1 ]; then
  kill $PRE_PID 2>/dev/null
  echo "$NEW_PID" > "$HOME_DIR/.slim.$PORT.pid"
  say "✓ 切换完成：$NEW_FILE (v$NEW_VER) pid=$NEW_PID，公网口正常"
  exit 0
fi

say "✗ 新版上线自检失败，回滚旧版 slim_proxy.py"
kill -9 $NEW_PID 2>/dev/null
sh "$HOME_DIR/start.sh" >/dev/null 2>&1
kill $PRE_PID 2>/dev/null
say "回滚完成（旧版已起），请检查"
exit 5
