#!/system/bin/sh
# 40_clean.sh — 规则清理（tmp/log/cache/bak/空目录/旧APK），一切经回收站
sk_clean(){
  _dry=0; _dir=""
  for a in "$@"; do
    case "$a" in
      --dry) _dry=1;;
      --*) ;;
      *) _dir="$a";;
    esac
  done
  if [ -n "$_dir" ]; then
    sherry_path_allowed "$_dir/probe" || { echo "[sherry] deny: $_dir out of whitelist"; return 2; }
    _targets="$_dir"
    _age=0
  else
    _targets="/data/local/tmp /storage/emulated/0/Download"
    _age=1
  fi
  _n=0
  for d in $_targets; do
    [ -d "$d" ] || continue
    if [ "$_age" -gt 0 ]; then
      find "$d" -maxdepth 2 -type f -mtime +$_age \( -name '*.tmp' -o -name '*.temp' -o -name '*.log' -o -name '*.cache' -o -name '*.bak' \) > "$SK_STATUS/.clean_cand" 2>/dev/null
    else
      find "$d" -maxdepth 2 -type f \( -name '*.tmp' -o -name '*.temp' -o -name '*.log' -o -name '*.cache' -o -name '*.bak' \) > "$SK_STATUS/.clean_cand" 2>/dev/null
    fi
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      sherry_path_allowed "$f" || continue
      if [ "$_dry" = 1 ]; then
        echo "[sherry] DRY candidate: $f"
      else
        safe_rm "$f" && _n=$((_n+1))
      fi
    done < "$SK_STATUS/.clean_cand"
    if [ "$_dir" = "$d" ] || [ -z "$_dir" ]; then
      find "$d" -maxdepth 2 -type d -empty 2>/dev/null > "$SK_STATUS/.clean_dirs"
      while IFS= read -r e; do
        [ -n "$e" ] || continue
        [ "$e" = "$d" ] && continue
        sherry_path_allowed "$e/probe" || continue
        if [ "$_dry" = 1 ]; then echo "[sherry] DRY emptydir: $e"; else rmdir "$e" 2>/dev/null; fi
      done < "$SK_STATUS/.clean_dirs"
    fi
  done
  rm -f "$SK_STATUS/.clean_cand" "$SK_STATUS/.clean_dirs" 2>/dev/null
  if [ "$_dry" = 1 ]; then
    echo "[sherry] dry-run done, nothing moved"
  else
    echo "[sherry] clean done: $_n files recycled"
  fi
}
