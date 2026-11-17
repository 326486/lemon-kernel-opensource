#!/system/bin/sh
# slimproxy 停止 · v3（261113）
# v1 三处失效（pid 文件名、特征串、兜底 pgrep）已在 v2 修复；
# v3 修复 v2 的判活缺陷：kill -0 对僵尸(Z)进程返回真，导致端口已释放却误报"仍存活"、
# 退出码 1 且不清理 pid 文件（真机复现：影子被父进程遗留成僵尸时必现）。
# 判活规则：进程不存在 或 状态为 Z → 视为已退出；最终成功以"端口释放"为权威判据。
S=/data/lemonbrain/slimproxy
PORT=${LEMON_SLIM_PORT:-8791}
LOG=/data/lemonbrain/logs/stop_sh.log
MODE=$1

port_up() {
  HEX=$(printf "%X" "$PORT")
  awk -v h=":$HEX" '$2 ~ h"$" && $4 == "0A" { f = 1 } END { exit !f }' /proc/net/tcp 2>/dev/null
}
say() {
  echo "$1"
  echo "[$(date '+%m-%d %H:%M:%S')] port=$PORT $1" >> "$LOG" 2>/dev/null
}
# 取状态字段：进程名可能含空格与括号，必须先切掉到最后一个 ')' 为止
proc_state() {
  [ -d "/proc/$1" ] || { echo "gone"; return; }
  sed 's/.*) //' "/proc/$1/stat" 2>/dev/null | cut -d' ' -f1
}
# 僵尸(Z)= 已退出待父进程回收，等同于死
is_dead() {
  case "$(proc_state "$1")" in
    gone|Z|X) return 0 ;;
    *) return 1 ;;
  esac
}
is_slim() {
  case "$(tr '\0' ' ' < /proc/$1/cmdline 2>/dev/null)" in
    *slim_proxy*) : ;;
    *) return 1 ;;
  esac
  case "$(readlink /proc/$1/exe 2>/dev/null)" in
    *python*) return 0 ;;
    *) return 1 ;;
  esac
}
# 端口归属：environ 里显式 LEMON_SLIM_PORT 且不是本端口 → 不属于本端口（防跨端口误杀）
owns() {
  EXPLICIT=$(tr '\0' '\n' < /proc/$1/environ 2>/dev/null | grep '^LEMON_SLIM_PORT=' | head -1 | cut -d= -f2)
  if [ -n "$EXPLICIT" ] && [ "$EXPLICIT" != "$PORT" ]; then
    return 1
  fi
  return 0
}
match() {
  for f in $(grep -la slim_proxy /proc/[0-9]*/cmdline 2>/dev/null); do
    p=$(echo "$f" | cut -d/ -f3)
    if is_slim "$p" && owns "$p"; then
      case "$(proc_state "$p")" in
        Z|gone) : ;;                       # 僵尸不算活目标，但仍列出供诊断
        *) echo "$p" ;;
      esac
    fi
  done
}

PIDF=""
if [ -f "$S/.slim.$PORT.pid" ]; then PIDF="$S/.slim.$PORT.pid"; fi
if [ -z "$PIDF" ] && [ -f "$S/.slim.pid" ]; then PIDF="$S/.slim.pid"; fi

P=""
if [ -n "$PIDF" ]; then P=$(cat "$PIDF" 2>/dev/null); fi
if [ -n "$P" ]; then
  if ! is_slim "$P" || ! owns "$P"; then
    say "pid 文件不可信（$PIDF 里的 $P 不是本端口 slim 进程）→ 改按特征定位"
    P=""
  fi
fi
CANDS=$(match)
NCAND=$(echo "$CANDS" | grep -c '[0-9]')
if [ -z "$P" ]; then P=$(echo "$CANDS" | grep '[0-9]' | head -1); fi

if [ -z "$P" ]; then
  if port_up; then
    say "端口仍被监听，但未发现属于本端口的 slim_proxy 活进程（候选 $NCAND）——交回看门狗处理"
    exit 0
  fi
  say "未发现属于本端口的 slim_proxy 进程（候选 $NCAND）"
  [ -n "$PIDF" ] && rm -f "$PIDF"
  exit 0
fi
NAME=$(cat /proc/$P/cmdline 2>/dev/null | tr '\0' ' ' | grep -oE 'slim_proxy_v1[0-9]+(\.pyc?)?|slim_proxy\.py' | head -1)
say "识别 pid=$P 目标=${NAME:-slim_proxy} 候选数=$NCAND 端口状态=$(port_up && echo up || echo down)"

if [ "$MODE" = "status" ] || [ "$MODE" = "dry-run" ]; then
  say "模式=$MODE：只识别，不杀进程"
  exit 0
fi

kill "$P" 2>/dev/null
i=0
while [ $i -lt 12 ]; do
  is_dead "$P" && break
  sleep 0.5
  i=$((i + 1))
done
if ! is_dead "$P"; then
  kill -9 "$P" 2>/dev/null
  sleep 1
fi

# 清理本端口其它活残留（跳过僵尸，它们会被各自父进程回收）
for p in $(match); do
  if [ "$p" != "$P" ]; then
    kill -9 "$p" 2>/dev/null
    say "清理本端口残留 pid=$p"
  fi
done

# 权威判据：端口是否释放；僵尸视为已退出
j=0
while [ $j -lt 12 ]; do
  port_up || break
  sleep 0.5
  j=$((j + 1))
done
if ! port_up; then
  [ -n "$PIDF" ] && rm -f "$PIDF"
  ST=$(proc_state "$P")
  if [ "$ST" = "Z" ]; then
    say "已停止 pid=$P（僵尸待父进程回收），端口已释放"
  else
    say "已停止 pid=$P，端口已释放"
  fi
  exit 0
fi
say "失败：pid=$P 状态=$(proc_state "$P") 仍占用端口，未清理 pid 文件"
exit 1