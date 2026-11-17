#!/system/bin/sh
# ============================================================
# virus_key.sh v1.2 · 应急快捷键守护（双键序列 · 防误触）
# 20261004 · 小柠檬本体 · 授权：小良
# ------------------------------------------------------------
# 触发：音量下连按3次 + 音量上连按3次（每键2s内，两段15s内，顺序不限）
# 原理：直接读内核 input 原始事件，不经 App、不怕遮挡/被杀
# 设备：event1 = 音量下   event4 = 音量上
# 用法: start [--dry] | stop | status | selftest
# ============================================================
LK=/data/adb/lemon_kernel
LV=$LK/lemonlib/lemon_virus.sh
LOGDIR=$LK/logs
LOG=$LOGDIR/virus_key.log
PIDF=$LK/conf/virus_key.pid
DEVD=/dev/input/event1
DEVU=/dev/input/event4
DONED=$LK/conf/vk.done.down
DONEU=$LK/conf/vk.done.up
COOLF=$LK/conf/vk.cool
LOCKD=$LK/conf/vk.lock
WINDOW=2000
NEED=3
SEQWIN=15000
COOLDOWN=10
mkdir -p "$LOGDIR" "$LK/conf" 2>/dev/null
[ -f "$LK/conf/virus.flags" ] || {
  echo "key_force=1" > "$LK/conf/virus.flags" 2>/dev/null
  echo "key_uninstall=1" >> "$LK/conf/virus.flags" 2>/dev/null
  echo "scan_autoremove=0" >> "$LK/conf/virus.flags" 2>/dev/null
}
_kf0=$(sed -n 's/^key_force=//p' "$LK/conf/virus.flags" 2>/dev/null | head -1)
[ -z "$_kf0" ] && echo "key_force=1" >> "$LK/conf/virus.flags" 2>/dev/null

log() {
  echo "$(date '+%m%d %H:%M:%S') $*" >> "$LOG" 2>/dev/null
  _n=$(wc -l < "$LOG" 2>/dev/null | tr -d ' ')
  if [ -n "$_n" ] && [ "$_n" -gt 300 ]; then
    tail -n 180 "$LOG" > "$LOG.t" 2>/dev/null && cat "$LOG.t" > "$LOG" 2>/dev/null; rm -f "$LOG.t" 2>/dev/null
  fi
}

ms() { awk '{printf "%d", $1*1000}' /proc/uptime 2>/dev/null; }

# 递归回收进程树（只按 pid，绝不按命令行文本匹配 —— 防自杀陷阱）
kill_watcher() {
  _wp="$1"
  [ -z "$_wp" ] && return 0
  [ "$_wp" = "$$" ] && return 0
  kill -0 "$_wp" 2>/dev/null || return 0
  for _wc in $(ps -A -o PID,PPID 2>/dev/null | awk -v p="$_wp" '$2==p{print $1}'); do
    kill -KILL "$_wc" 2>/dev/null
  done
  kill -KILL "$_wp" 2>/dev/null
  log "STOPPED pid=$_wp"
  return 0
}

trigger() {
  _m="$1"
  log "TRIGGER mode=$_m"
  _po="$LOGDIR/virus_panic_out.log"
  _sz=$(wc -c < "$_po" 2>/dev/null | tr -d ' ')
  if [ -n "$_sz" ] && [ "$_sz" -gt 200000 ]; then
    tail -c 50000 "$_po" > "$_po.t" 2>/dev/null && cat "$_po.t" > "$_po" 2>/dev/null
    rm -f "$_po.t" 2>/dev/null
  fi
  if [ "$_m" = "dry" ]; then
    echo "DRY-TRIGGER $(date '+%m%d %H:%M:%S') front=$(timeout 20 sh $LV front 2>/dev/null)" >> "$_po" 2>/dev/null
  else
    _pu="--force"
    _kf=$(sed -n 's/^key_force=//p' "$LK/conf/virus.flags" 2>/dev/null | head -1)
    [ "$_kf" = "0" ] && _pu=""
    _kv=$(sed -n 's/^key_uninstall=//p' "$LK/conf/virus.flags" 2>/dev/null | head -1)
    [ "$_kv" = "0" ] || _pu="$_pu --remove"
    ( timeout 180 sh "$LV" panic $_pu >> "$_po" 2>&1 ) &
  fi
}

clean_flags() {
  _n="$1"
  _v=$(cat "$DONED" 2>/dev/null)
  if [ -n "$_v" ] && [ $((_n - _v)) -gt "$SEQWIN" ]; then rm -f "$DONED" 2>/dev/null; fi
  _v=$(cat "$DONEU" 2>/dev/null)
  if [ -n "$_v" ] && [ $((_n - _v)) -gt "$SEQWIN" ]; then rm -f "$DONEU" 2>/dev/null; fi
}

try_fire() {
  _n="$1"; _mode="$2"
  _d=$(cat "$DONED" 2>/dev/null); _u=$(cat "$DONEU" 2>/dev/null)
  [ -z "$_d" ] && return 0
  [ -z "$_u" ] && return 0
  if mkdir "$LOCKD" 2>/dev/null; then
    _cool=$(cat "$COOLF" 2>/dev/null); [ -z "$_cool" ] && _cool=0
    if [ "$_n" -ge "$_cool" ]; then
      rm -f "$DONED" "$DONEU" 2>/dev/null
      echo $((_n + COOLDOWN * 1000)) > "$COOLF" 2>/dev/null
      rmdir "$LOCKD" 2>/dev/null
      trigger "$_mode"
      return 0
    fi
    rmdir "$LOCKD" 2>/dev/null
  fi
  return 0
}

watch_key() {
  _which="$1"; _code="$2"; _dev="$3"; _mode="$4"
  [ -r "$_dev" ] || { log "ERR 打不开 $_dev"; return 1; }
  echo "$$" > "$LK/conf/vk.w.$_which" 2>/dev/null
  echo -1000 > /proc/self/oom_score_adj 2>/dev/null
  log "WATCH $_which pid=$$ dev=$_dev code=$_code mode=$_mode"
  exec 3< "$_dev" 2>/dev/null || { log "ERR open fail $_dev"; return 1; }
  _cnt=0; _last=0; _empty=0
  while :; do
    _raw=$(dd bs=24 count=1 <&3 2>/dev/null | od -An -tu1 -v 2>/dev/null)
    if [ -z "$_raw" ]; then
      _empty=$((_empty+1))
      if [ "$_empty" -ge 120 ]; then log "ERR $_which 设备无响应，退出"; break; fi
      sleep 1; continue
    fi
    _empty=0
    set -- $_raw
    [ $# -ge 24 ] || continue
    _type=$(( ${17} + ${18} * 256 ))
    [ "$_type" = "1" ] || continue
    _c=$(( ${19} + ${20} * 256 ))
    [ "$_c" = "$_code" ] || continue
    _v=$(( ${21} + ${22} * 256 + ${23} * 65536 + ${24} * 16777216 ))
    [ "$_v" = "1" ] || continue
    _now=$(ms); [ -z "$_now" ] && continue
    _dt=$(( _now - _last ))
    if [ "$_dt" -lt "$WINDOW" ]; then _cnt=$((_cnt+1)); else _cnt=1; fi
    _last=$_now
    [ "$_mode" = "dry" ] && log "KEY $_which dt=${_dt}ms cnt=$_cnt"
    if [ "$_cnt" -ge "$NEED" ]; then
      _cnt=0
      clean_flags "$_now"
      if [ "$_which" = "down" ]; then echo "$_now" > "$DONED" 2>/dev/null
      else echo "$_now" > "$DONEU" 2>/dev/null; fi
      log "HALF $_which 三连达成"
      try_fire "$_now" "$_mode"
    fi
  done
  log "WATCH-EXIT $_which"
}

stop_all() {
  if [ -f "$PIDF" ]; then
    for _p in $(cat "$PIDF" 2>/dev/null); do kill_watcher "$_p"; done
  fi
  for _f in "$LK/conf/vk.w.down" "$LK/conf/vk.w.up"; do
    if [ -f "$_f" ]; then kill_watcher "$(cat "$_f" 2>/dev/null)"; rm -f "$_f" 2>/dev/null; fi
  done
  rm -f "$PIDF" "$DONED" "$DONEU" "$COOLF" 2>/dev/null
  rmdir "$LOCKD" 2>/dev/null
  return 0
}

case "$1" in
  start)
    _mode=panic
    shift
    while [ $# -gt 0 ]; do
      case "$1" in --dry) _mode=dry ;; esac
      shift
    done
    stop_all
    sleep 1
    nohup sh "$0" watch down 114 "$DEVD" "$_mode" </dev/null >>"$LOG" 2>&1 &
    _p1=$!
    nohup sh "$0" watch up 115 "$DEVU" "$_mode" </dev/null >>"$LOG" 2>&1 &
    _p2=$!
    echo "$_p1 $_p2" > "$PIDF" 2>/dev/null
    sleep 2
    _ok=0
    kill -0 "$_p1" 2>/dev/null && _ok=$((_ok+1))
    kill -0 "$_p2" 2>/dev/null && _ok=$((_ok+1))
    echo "watcher=$_ok/2  mode=$_mode"
    echo "  音量下 pid=$_p1 ($DEVD)"
    echo "  音量上 pid=$_p2 ($DEVU)"
    ;;
  stop)
    stop_all
    echo "已停止"
    ;;
  status)
    if [ -f "$PIDF" ]; then
      _i=0
      for _p in $(cat "$PIDF" 2>/dev/null); do
        _i=$((_i+1))
        if kill -0 "$_p" 2>/dev/null; then echo "watcher$_i: 运行中 pid=$_p"; else echo "watcher$_i: 已死 pid=$_p"; fi
      done
    else
      echo "守护: 未运行"
    fi
    echo "  信号旗: 下=$(cat $DONED 2>/dev/null) 上=$(cat $DONEU 2>/dev/null)"
    echo "-- 日志末尾 --"
    [ -f "$LOG" ] && tail -n 6 "$LOG"
    ;;
  selftest)
    printf '\001\000\000\000\000\000\000\000\002\000\000\000\000\000\000\000\001\000\162\000\001\000\000\000' > /data/local/tmp/vk.ev
    _raw=$(od -An -tu1 -v /data/local/tmp/vk.ev)
    set -- $_raw
    echo "字段数=$#  type=$(( ${17} + ${18} * 256 ))  code=$(( ${19} + ${20} * 256 ))  val=$(( ${21} + ${22} * 256 + ${23} * 65536 + ${24} * 16777216 ))"
    ;;
  watch) watch_key "$2" "$3" "$4" "$5" ;;
  *) sed -n '2,16p' "$0"; exit 1 ;;
esac
