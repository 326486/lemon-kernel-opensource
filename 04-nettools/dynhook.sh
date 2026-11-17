#!/system/bin/sh
# dynhook.sh v1.1 —— 动态插桩引擎（rusda/frida 封装）
# 归属：8788 内核体系 · 分类「动态插桩」
# 用法: dynhook.sh {status|up [port]|down|hook <目标> <脚本> [秒]|spawn <包名> <脚本> [秒]|log [n]|scripts|clean}
D=/data/adb/lemon_kernel/rusda
BIN=$D/rusda-server
INJ=$D/rusda-inject
LOGD=$D/logs
SCR=$D/scripts
PIDF=$D/frida.pid
PORTF=$D/frida.port
SB=/data/adb/magisk/busybox
mkdir -p "$LOGD" "$SCR" 2>/dev/null

getpid() {
  [ -f "$PIDF" ] || return 1
  _p=$(cat "$PIDF" 2>/dev/null)
  [ -n "$_p" ] || return 1
  kill -0 "$_p" 2>/dev/null || return 1
  echo "$_p"
}
port_open() {
  hex=$(printf '%04X' "$1" 2>/dev/null)
  [ -n "$hex" ] || return 1
  $SB grep -qi ":$hex " /proc/net/tcp 2>/dev/null && return 0
  return 1
}
resolve_script() {
  [ -f "$1" ] && { echo "$1"; return 0; }
  [ -f "$SCR/$1" ] && { echo "$SCR/$1"; return 0; }
  [ -f "$SCR/$1.js" ] && { echo "$SCR/$1.js"; return 0; }
  return 1
}
# 找到目标的 pid（严格匹配：comm 精确 -> argv[0] 基名；排除自身，避免误伤自己）
find_target_pid() {
  key="$1"
  self=$$
  case "$key" in
    [0-9]*) [ -d "/proc/$key" ] && { echo "$key"; return 0; }; return 1 ;;
  esac
  for x in /proc/[0-9]*; do
    pid=${x#/proc/}
    [ "$pid" = "$self" ] && continue
    [ -r "$x/comm" ] || continue
    c=$(cat "$x/comm" 2>/dev/null)
    [ "$c" = "$key" ] && { echo "$pid"; return 0; }
  done
  for x in /proc/[0-9]*; do
    pid=${x#/proc/}
    [ "$pid" = "$self" ] && continue
    [ -r "$x/cmdline" ] || continue
    a0=$(tr "\0" "\n" < "$x/cmdline" 2>/dev/null | head -1)
    b=$(basename "$a0" 2>/dev/null)
    [ "$b" = "$key" ] && { echo "$pid"; return 0; }
  done
  return 1
}
# ★可注入性预检：静态链接进程 frida 注入必崩（踩坑固化：magisk busybox 是静态的）
check_injectable() {
  pid="$1"
  exe=$(readlink "/proc/$pid/exe" 2>/dev/null)
  [ -n "$exe" ] || { echo "  ⚠ 无法读取 /proc/$pid/exe，跳过预检"; return 0; }
  needed=$(/system/bin/readelf -d "$exe" 2>/dev/null | grep -c NEEDED)
  case "$needed" in ''|*[!0-9]*) echo "  ⚠ 无法判定链接方式，跳过预检"; return 0 ;; esac
  if [ "$needed" = "0" ]; then
    echo "✗ 目标不可注入: pid=$pid  exe=$exe  是【静态链接】"
    echo "  frida 需要动态链接进程（有 linker/libc）。magisk busybox、静态编译的二进制都注入不了。"
    echo "  建议目标: App 进程 / /system/bin 下的 toybox 程序 / zygote 子进程"
    return 1
  fi
  echo "  预检通过: $(basename "$exe")  动态链接(NEEDED=$needed)"
  return 0
}

case "$1" in
status)
  echo "=== 动态插桩（rusda 17.15.0）==="
  p=$(getpid)
  if [ -n "$p" ]; then
    echo "服务:   运行中  pid=$p  端口=$(cat "$PORTF" 2>/dev/null)"
  else
    echo "服务:   未运行"
  fi
  echo "服务端: $BIN"
  echo "注入器: $INJ"
  echo "版本:   $("$BIN" --version 2>&1 | head -1)"
  echo "脚本库: $SCR  ($(ls "$SCR" 2>/dev/null | wc -l) 个)"
  echo "  列表: $(ls "$SCR" 2>/dev/null | tr '\n' ' ')"
  echo "日志:   $LOGD  ($(ls "$LOGD" 2>/dev/null | wc -l) 个)"
  last=$(ls -t "$LOGD"/hook_*.log "$LOGD"/spawn_*.log 2>/dev/null | head -1)
  if [ -n "$last" ]; then echo "最近注入: $(basename "$last")  $(stat -c %y "$last" 2>/dev/null | cut -c1-19)"; else echo "最近注入: （无）"; fi
  ;;

up)
  # 日志上限保护（#249：禁止无上限 >> 追加）
  if [ -f "$LOGD/frida.log" ]; then
    _sz=$(wc -c < "$LOGD/frida.log" 2>/dev/null)
    case "$_sz" in ""|*[!0-9]*) _sz=0 ;; esac
    if [ "$_sz" -gt 1048576 ]; then
      tail -100 "$LOGD/frida.log" > /data/local/tmp/_frlog_rotate 2>/dev/null
      cat /data/local/tmp/_frlog_rotate > "$LOGD/frida.log"
      echo "[rotate] frida.log 超 1MB，仅保留末 100 行" >> "$LOGD/frida.log"
      rm -f /data/local/tmp/_frlog_rotate
    fi
  fi
  p=$(getpid)
  if [ -n "$p" ]; then echo "已在运行: pid=$p 端口=$(cat "$PORTF" 2>/dev/null)"; exit 0; fi
  PORT="$2"
  case "$PORT" in ''|*[!0-9]*) PORT=8765 ;; esac
  [ "$PORT" = "27042" ] && PORT=8765
  "$BIN" -l "127.0.0.1:$PORT" >> "$LOGD/frida.log" 2>&1 &
  np=$!
  echo "$np" > "$PIDF"; echo "$PORT" > "$PORTF"
  i=0
  while [ "$i" -lt 20 ]; do
    port_open "$PORT" && break
    kill -0 "$np" 2>/dev/null || { echo "启动失败（进程已退出）日志尾部："; tail -5 "$LOGD/frida.log" 2>/dev/null; exit 1; }
    sleep 0.5; i=$(( i + 1 ))
  done
  if port_open "$PORT"; then
    echo "已启动: pid=$np  监听 127.0.0.1:$PORT  (非默认端口)"
  else
    echo "警告: 进程在但端口未就绪（可能 SELinux 限制）；日志尾部："; tail -5 "$LOGD/frida.log" 2>/dev/null
  fi
  ;;

down)
  p=$(getpid)
  if [ -n "$p" ]; then
    kill "$p" 2>/dev/null; sleep 1
    kill -0 "$p" 2>/dev/null && kill -9 "$p" 2>/dev/null
    echo "已停止服务 pid=$p"
  else
    n=0
    for x in /proc/[0-9]*; do
      [ -r "$x/cmdline" ] || continue
      c=$(tr '\0' ' ' < "$x/cmdline" 2>/dev/null)
      case "$c" in *"rusda-server"*) kill "${x#/proc/}" 2>/dev/null && n=$(( n + 1 )) ;; esac
    done
    echo "已停止（清理 $n 个残留实例）"
  fi
  rm -f "$PIDF"
  ;;

hook)
  TGT="$2"; SC="$3"; SEC="${4:-20}"
  [ -n "$TGT" ] || { echo "用法: dynhook.sh hook <包名|进程名|pid> <脚本> [秒=20]"; exit 1; }
  [ -n "$SC" ]  || { echo "用法: dynhook.sh hook <目标> <脚本> [秒=20]"; exit 1; }
  SC=$(resolve_script "$SC") || { echo "脚本不存在: $3"; echo "可用: $(ls "$SCR" 2>/dev/null | tr '\n' ' ')"; exit 1; }
  case "$SEC" in ''|*[!0-9]*) SEC=20 ;; esac
  echo "目标预检:"
  TPID=$(find_target_pid "$TGT") || { echo "✗ 未找到目标进程: $TGT（需正在运行）"; exit 1; }
  check_injectable "$TPID" || exit 1
  TS=$(date +%Y%m%d_%H%M%S)
  OUT="$LOGD/hook_${TS}.log"
  nohup timeout "$SEC" "$INJ" -p "$TPID" -s "$SC" > "$OUT" 2>&1 &
  echo "$!" > "$D/hook.pid"
  echo "已注入(attach): pid=$TPID($TGT)  脚本=$(basename "$SC")  时长=${SEC}s"
  echo "日志: $OUT"
  ;;

spawn)
  PKG="$2"; SC="$3"; SEC="${4:-20}"
  [ -n "$PKG" ] || { echo "用法: dynhook.sh spawn <包名> <脚本> [秒=20]"; exit 1; }
  [ -n "$SC" ]  || { echo "用法: dynhook.sh spawn <包名> <脚本> [秒=20]"; exit 1; }
  SC=$(resolve_script "$SC") || { echo "脚本不存在: $3"; exit 1; }
  case "$SEC" in ''|*[!0-9]*) SEC=20 ;; esac
  TS=$(date +%Y%m%d_%H%M%S)
  OUT="$LOGD/spawn_${TS}.log"
  nohup timeout "$SEC" "$INJ" -f "$PKG" -s "$SC" > "$OUT" 2>&1 &
  echo "$!" > "$D/hook.pid"
  echo "已注入(spawn): 包名=$PKG  脚本=$(basename "$SC")  时长=${SEC}s"
  echo "日志: $OUT"
  ;;

log)
  N="${2:-40}"
  case "$N" in ''|*[!0-9]*) N=40 ;; esac
  last=$(ls -t "$LOGD"/hook_*.log "$LOGD"/spawn_*.log 2>/dev/null | head -1)
  if [ -z "$last" ]; then echo "暂无注入日志"; exit 0; fi
  echo "=== 最新: $(basename "$last") ==="
  tail -"$N" "$last"
  ;;

scripts)
  echo "=== 脚本库 $SCR ==="
  if [ -z "$(ls "$SCR" 2>/dev/null)" ]; then echo "（空）"; else
    for f in "$SCR"/*.js; do
      [ -f "$f" ] || continue
      printf "  %-20s %s\n" "$(basename "$f")" "$(head -2 "$f" 2>/dev/null | tail -1 | sed 's|^// *||')"
    done
  fi
  ;;

clean)
  n=$(ls "$LOGD"/*.log 2>/dev/null | wc -l)
  rm -f "$LOGD"/hook_*.log "$LOGD"/spawn_*.log 2>/dev/null
  echo "已清理 $n 个日志"
  ;;

*)
  echo "dynhook.sh v1.1 —— 8788 动态插桩引擎"
  echo "  status              状态总览"
  echo "  up [port]           起 frida-server（默认 8765）"
  echo "  down                停服务"
  echo "  hook <目标> <脚本> [秒]   attach 注入（目标=包名/进程名/pid，自带可注入性预检）"
  echo "  spawn <包名> <脚本> [秒]  spawn 启动并注入"
  echo "  log [n]             看最新注入日志"
  echo "  scripts             列脚本库"
  echo "  clean               清理日志"
  ;;
esac
