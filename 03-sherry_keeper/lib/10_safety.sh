#!/system/bin/sh
# 10_safety.sh — 白名单硬边界 + 分级 + 回收站（继承 v8.0.0 并加强自保护）
sherry_path_allowed(){
  case "$1" in
    /system/*|/vendor/*|/product/*|/data/adb/*|/data/data/*|/data/system/*|/data/misc/*|$LEMON_DATA/*|/data/lemonbrain/*) return 1;;
    /storage/emulated/0/Download/*|/storage/emulated/0/下载/*|/storage/emulated/0/DCIM/*|/storage/emulated/0/Pictures/*|/storage/emulated/0/Android/data/*|/data/local/tmp/*) return 0;;
    *) return 1;;
  esac
}

# 只读扫描宽口径（深扫可览全用户区，变更类操作仍走严格白名单）
sherry_scan_allowed(){
  case "$1" in
    /storage/emulated/0/*|/data/local/tmp/*) return 0;;
    *) return 1;;
  esac
}

sherry_grade(){
  _p="$1"
  sherry_path_allowed "$_p" || { echo DANGEROUS; return; }
  case "$_p" in
    *.tmp|*.temp|*.log|*.cache|*.bak|*/cache/*) echo SAFE;;
    *.apk)
      _mt=$(stat -c %Y "$_p" 2>/dev/null || echo 0)
      _now=$(date +%s)
      if [ $((_now - _mt)) -gt 2592000 ]; then echo SAFE; else echo CAUTION; fi;;
    *) echo CAUTION;;
  esac
}

safe_rm(){
  _src="$1"
  [ -e "$_src" ] || return 1
  sherry_path_allowed "$_src" || { sk_log WARN "deny $_src"; return 1; }
  _ts=$(date +%y%m%d-%H%M%S)
  _dst="$SK_RECYCLE/$_ts/$(echo "$_src" | sed 's|^/||')"
  mkdir -p "$(dirname "$_dst")" 2>/dev/null
  mv "$_src" "$_dst" 2>/dev/null || return 1
  printf '%s\t%s\t%s\n' "$_ts" "$_src" "$_dst" >> "$SK_RECYCLE/manifest.tsv"
  sk_count recycled >/dev/null
  sk_log INFO "recycled $_src"
  return 0
}

# 回收站保留期：超30天自动彻底清理（lemon-user261115常设授权）；只动回收站内已登记文件，逐件审计留痕
SK_RETENTION_DAYS=30
sk_recycle_retention(){
  _dry=0
  [ "$1" = "--dry" ] && _dry=1
  _m="$SK_RECYCLE/manifest.tsv"
  [ -f "$_m" ] || { echo "[sherry] retention: manifest empty, nothing to do"; return 0; }
  _cutoff=$(date -d "@$(( $(date +%s) - SK_RETENTION_DAYS * 86400 ))" +%y%m%d 2>/dev/null)
  [ -n "$_cutoff" ] || { echo "[sherry] retention: date calc failed"; return 2; }
  _keep="$SK_RECYCLE/.manifest_keep"
  _audit="$SK_LOGS/recycle_retention_purge.tsv"
  : > "$_keep"
  _p=0; _k=0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    _ts=$(printf '%s' "$line" | cut -f1)
    _dst=$(printf '%s' "$line" | cut -f3)
    _d=${_ts%%-*}
    case "$_dst" in
      "$SK_RECYCLE"/*) ;;
      *) printf '%s\n' "$line" >> "$_keep"; _k=$((_k+1)); continue;;
    esac
    if [ "$_d" -lt "$_cutoff" ] 2>/dev/null; then
      if [ "$_dry" = 1 ]; then
        echo "[sherry] DRY retention purge: $_dst"
        printf '%s\n' "$line" >> "$_keep"
        _k=$((_k+1))
      else
        [ -e "$_dst" ] && rm -f "$_dst" 2>/dev/null
        printf '%s\t%s\n' "$(date '+%y%m%d-%H%M%S')" "$line" >> "$_audit"
        _p=$((_p+1))
      fi
    else
      printf '%s\n' "$line" >> "$_keep"
      _k=$((_k+1))
    fi
  done < "$_m"
  if [ "$_dry" = 0 ]; then
    mv -f "$_keep" "$_m"
    find "$SK_RECYCLE" -mindepth 1 -maxdepth 1 -type d -empty -exec rmdir {} + 2>/dev/null
    sk_log INFO "retention purged=$_p kept=$_k cutoff=$_cutoff"
    echo "[sherry] retention done: purged=$_p kept=$_k (>${SK_RETENTION_DAYS}d auto-purge)"
  else
    rm -f "$_keep" 2>/dev/null
    echo "[sherry] retention dry-run done (nothing deleted)"
  fi
}
