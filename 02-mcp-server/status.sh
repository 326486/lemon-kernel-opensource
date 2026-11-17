#!/system/bin/sh
# slimproxy 状态 v1.3 · 261030
# v1.3：pid 用 ss 提取（v1.2 遍历 /proc/*/fd 太慢会卡）
PORT=${LEMON_SLIM_PORT:-8791}
HEX=$(printf "%X" "$PORT")
PIDF=/data/lemonbrain/slimproxy/.slim.$PORT.pid

echo "=== slim_proxy 状态 (port=$PORT) ==="
if awk -v h=":$HEX" '$2 ~ h"$" && $4 == "0A" {f=1} END {exit !f}' /proc/net/tcp 2>/dev/null; then
  echo "监听: 是"
  PID=$(ss -tlnp 2>/dev/null | grep ":$PORT " | grep -o 'pid=[0-9]*' | head -1 | cut -d= -f2)
  echo "进程pid: ${PID:-未知}"
else
  echo "监听: 否"
fi
[ -f "$PIDF" ] && echo "pid文件: $(cat $PIDF)"

if [ -f /data/lemonbrain/slimproxy/.watchdog.pid ]; then
  WP=$(cat /data/lemonbrain/slimproxy/.watchdog.pid)
  if kill -0 "$WP" 2>/dev/null; then echo "watchdog: 存活 pid=$WP"; else echo "watchdog: 已死（记录 pid=$WP）"; fi
else
  echo "watchdog: 无 pid 文件"
fi

echo "--- 健康 ---"
curl -s -m 5 "http://127.0.0.1:$PORT/" 2>&1 | head -c 200
echo
echo "--- 索引 ---"
T=/data/lemonbrain/tools/_索引/工具索引.tsv
if [ -f "$T" ]; then echo "工具索引: $(( $(wc -l < $T) - 1 )) 条"; else echo "工具索引: 不存在"; fi
echo "--- 最近日志 ---"
tail -6 /data/lemonbrain/logs/slimproxy.log 2>/dev/null