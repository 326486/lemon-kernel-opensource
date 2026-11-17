#!/system/bin/sh
# start_current.sh —— 幂等启动最新版 slim 门面（261111）
# 自动选 slim_proxy_v1*.py 中版本号最大者；8791 活着就跳过；版本升级无需改任何调用方
S=${LEMON_HOME:-/data/lemonbrain}/slimproxy
port_up() {
  HEX=$(printf "%X" "$1")
  awk -v h=":$HEX" '$2 ~ h"$" && $4 == "0A" {f=1} END {exit !f}' /proc/net/tcp 2>/dev/null
}
port_up 8791 && { echo "8791 已在跑，跳过"; exit 0; }
# [261112] 选版逻辑升级：.py 与 .pyc 都可选(v134 源码被删,pyc 为唯一完整遗物)
#   同版本优先 .py(源码可维护)；只有 .pyc 时直接跑 pyc(python3 可执行字节码)
BEST=$(for f in "$S"/slim_proxy_v1*.py "$S"/slim_proxy_v1*.pyc; do
  [ -f "$f" ] || continue
  v=${f##*/slim_proxy_}; v=${v%%.*}
  echo "$v"
done 2>/dev/null | sort -V | uniq | tail -1)
if [ -n "$BEST" ] && [ -f "$S/slim_proxy_$BEST.py" ]; then
  CUR="$S/slim_proxy_$BEST.py"
elif [ -n "$BEST" ] && [ -f "$S/slim_proxy_$BEST.pyc" ]; then
  CUR="$S/slim_proxy_$BEST.pyc"
else
  CUR="$S/slim_proxy.py"
fi
PY=${LEMON_PY:-/data/data/com.termux/files/usr/bin/python3}
LOGD=${LEMON_HOME:-/data/lemonbrain}/logs
mkdir -p "$LOGD" 2>/dev/null
nohup env LEMON_SLIM_PORT=8791 LEMON_SLIM_PORT2=8792 \
  "$PY" -u "$CUR" \
  >> "$LOGD/slimproxy.log" 2>&1 &
echo $! > "$S/.slim.8791.pid"
echo "已启动 $CUR pid=$!"

# [261112 #249] 有界就绪等待：15s 内确认 8791 真监听，起不来报警，不闷头走人
i=0
while [ $i -lt 15 ] && ! port_up 8791; do sleep 1; i=$((i+1)); done
if port_up 8791; then
  echo "8791 就绪（等了 ${i}s）"
else
  echo "警告: 8791 等了 ${i}s 仍未监听 → 查 $LOGD/slimproxy.log"
fi
