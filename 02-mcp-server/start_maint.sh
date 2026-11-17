#!/system/bin/sh
# start_maint.sh —— 备用维护通道启动（幂等）v1.0.0 · 261111
PORT=${LEMON_MAINT_PORT:-8795}
S=${LEMON_HOME:-/data/lemonbrain}/slimproxy
LOG=${LEMON_HOME:-/data/lemonbrain}/logs/maint.log
PIDF=$S/.maint.$PORT.pid
P=${LEMON_TERMUX_USR:-/data/data/com.termux/files/usr}

port_up() {
  HEX=$(printf "%X" "$PORT")
  awk -v h=":$HEX" '$2 ~ h"$" && $4 == "0A" {f=1} END {exit !f}' /proc/net/tcp 2>/dev/null
}

if port_up; then
  echo "备用通道已在运行 port=$PORT"
  exit 0
fi

[ -f "$S/maint_server.py" ] || { echo "缺少 $S/maint_server.py"; exit 1; }
[ -x "$P/bin/python3" ] || { echo "缺少 python3"; exit 1; }
# 令牌兜底：.token_maint 缺则回退 .token，都没有则拒绝（不裸奔）
[ -s "$S/.token_maint" ] || [ -s "$S/.token" ] || { echo "无令牌，拒绝启动"; exit 1; }

export LD_LIBRARY_PATH=$P/lib
export PATH=$P/bin:$PATH
nohup env LEMON_MAINT_PORT=$PORT $P/bin/python3 -u "$S/maint_server.py" >> "$LOG" 2>&1 &
NEW=$!
sleep 2
kill -0 "$NEW" 2>/dev/null || { echo "启动失败，查 $LOG"; exit 1; }
i=0
while [ $i -lt 16 ]; do
  if port_up; then
    echo "$NEW" > "$PIDF"
    echo "备用通道启动成功 pid=$NEW port=$PORT"
    exit 0
  fi
  sleep 0.5
  i=$((i+1))
done
echo "端口未就绪，查 $LOG"
exit 1
