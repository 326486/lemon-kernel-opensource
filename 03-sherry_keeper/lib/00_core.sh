#!/system/bin/sh
# 00_core.sh — 路径/日志/锁/计数（雪莉重建 v9）
SK_ROOT=/data/lemonbrain/sherry_keeper
SK_FILES="$SK_ROOT/files"
SK_STUDIO='/storage/emulated/0/雪莉工作室'
# 日志与运行状态放工作室（文件管理器可见）；工作室不可用时回退模块内
if mkdir -p "$SK_STUDIO/日志" "$SK_STUDIO/运行状态" 2>/dev/null && [ -w "$SK_STUDIO/日志" ]; then
  SK_LOGS="$SK_STUDIO/日志"
  SK_STATUS="$SK_STUDIO/运行状态"
else
  SK_LOGS="$SK_ROOT/logs"
  SK_STATUS="$SK_FILES/status"
fi
SK_CLASSIFY='/storage/emulated/0/分类文件夹'
if mkdir -p "$SK_CLASSIFY/回收站" 2>/dev/null && [ -w "$SK_CLASSIFY/回收站" ]; then
  SK_RECYCLE="$SK_CLASSIFY/回收站"
else
  SK_RECYCLE="$SK_FILES/recycle"
fi
SK_VERSION="v9.3.1-retention"
mkdir -p "$SK_STATUS" "$SK_RECYCLE" "$SK_LOGS" 2>/dev/null

sk_log(){
  _lg="$SK_LOGS/sherry.log"
  printf '%s [%s] %s\n' "$(date '+%y%m%d-%H%M%S')" "$1" "$2" >> "$_lg"
  _sz=$(wc -c < "$_lg" 2>/dev/null || echo 0)
  if [ "$_sz" -gt 524288 ]; then
    mv -f "$_lg.2" "$_lg.3" 2>/dev/null
    mv -f "$_lg.1" "$_lg.2" 2>/dev/null
    mv -f "$_lg" "$_lg.1" 2>/dev/null
  fi
}

sk_lock(){
  mkdir "$SK_FILES/.lock" 2>/dev/null || { echo "[sherry] busy: another instance running"; exit 3; }
  trap 'rmdir "$SK_FILES/.lock" 2>/dev/null' EXIT INT TERM
}

sk_count(){
  _cf="$SK_STATUS/$1.count"
  _v=$(cat "$_cf" 2>/dev/null || echo 0)
  _v=$((_v + ${2:-1}))
  echo "$_v" > "$_cf"
  echo "$_v"
}

sk_get(){ cat "$SK_STATUS/$1.count" 2>/dev/null || echo 0; }

# crond 自愈：任何雪莉调用都确认定时守护在位（service.d受guard保护，用自愈替代开机脚本）
sk_ensure_crond(){
  ps -ef 2>/dev/null | grep -v grep | grep -q 'crond -c /data/cron' && return 0
  [ -x /data/adb/magisk/busybox ] || return 0
  [ -f /data/cron/root ] || return 0
  /data/adb/magisk/busybox crond -c /data/cron 2>/dev/null
  return 0
}
