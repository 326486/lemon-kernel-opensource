#!/system/bin/sh
# slimproxy 启动（幂等）· 小柠檬 261030 v1.1
# v1.1 修复：端口已监听直接返回；新进程必须存活才算成功（防 bind 失败误报）
P=/data/data/com.termux/files/usr
SP=/data/lemonbrain/slimproxy/slim_proxy.py
LOG=/data/lemonbrain/logs/slimproxy.log
PORT=${LEMON_SLIM_PORT:-8792}
PY=${LEMON_PY:-$(command -v python3 2>/dev/null || echo ""$PY"")}
while (exec 3<>/dev/tcp/127.0.0.1/$PORT) 2>/dev/null; do exec 3>&- 3<&-; PORT=$((PORT+1)); done
PIDF=/data/lemonbrain/slimproxy/.slim.${PORT}.pid

# 统一口径：用 /proc/net/tcp 判定 LISTEN（netstat 在 Android 上既慢又和影子测试口径不一致）
port_up() {
  HEX=$(printf "%X" "$PORT")
  awk -v h=":$HEX" '$2 ~ h"$" && $4 == "0A" {f=1} END {exit !f}' /proc/net/tcp 2>/dev/null
}
# 取监听该端口的 pid（遍历 /proc/*/fd 找 socket inode，失败返回空）
port_pid() {
  HEX=$(printf "%X" "$PORT")
  INODE=$(awk -v h=":$HEX" '$2 ~ h"$" && $4=="0A" {print $10; exit}' /proc/net/tcp 2>/dev/null)
  [ -z "$INODE" ] && { echo ""; return; }
  for d in /proc/[0-9]*; do
    for fd in $d/fd/*; do
      ln=$(readlink "$fd" 2>/dev/null)
      case "$ln" in
        "socket:[$INODE]") echo "${d#/proc/}"; return;;
      esac
    done 2>/dev/null
  done
  echo ""
}

# 1) 端口已在监听 → 直接成功（可能不是我们启的，但服务可用）
if port_up; then
  P2=$(port_pid)
  [ -n "$P2" ] && echo "$P2" > "$PIDF"
  echo "已在运行 port=$PORT pid=$P2"
  exit 0
fi

# 2) pid 文件里的进程活着且是 slim → 等待端口（可能在启动中）
if [ -f "$PIDF" ]; then
  OLD=$(cat "$PIDF" 2>/dev/null)
  if [ -n "$OLD" ] && kill -0 "$OLD" 2>/dev/null; then
    case "$(tr '\0' ' ' < /proc/$OLD/cmdline 2>/dev/null)" in
      *slim_proxy.py*)
        i=0
        while [ $i -lt 10 ]; do port_up && { echo "已在运行 pid=$OLD"; exit 0; }; sleep 0.5; i=$((i+1)); done
        ;;
    esac
  fi
fi

[ -f "$SP" ] || { echo "缺少 $SP"; exit 1; }
[ -n "$PY" ] || { echo "缺少python3,设LEMON_PY"; exit 1; }

mkdir -p /data/lemonbrain/logs /data/lemonbrain/tools/_索引
export LD_LIBRARY_PATH=$P/lib
export PATH=$P/bin:$PATH

nohup env LEMON_SLIM_PORT=$PORT "$PY" -u "$SP" >> "$LOG" 2>&1 &
NEW=$!

# 3) 新进程必须存活
sleep 2
if ! kill -0 "$NEW" 2>/dev/null; then
  echo "启动失败（进程已退出），最近日志："
  tail -5 "$LOG" 2>/dev/null
  rm -f "$PIDF"
  exit 1
fi

# 4) 等端口（最多 8 秒）
i=0
while [ $i -lt 16 ]; do
  if port_up; then
    echo "$NEW" > "$PIDF"
    echo "启动成功 pid=$NEW port=$PORT"
    exit 0
  fi
  sleep 0.5
  i=$((i+1))
done
echo "端口未就绪，查日志 $LOG"
exit 1
