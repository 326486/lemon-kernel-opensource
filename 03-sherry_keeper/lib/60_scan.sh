#!/system/bin/sh
# 60_scan.sh — 深度扫描（只扫不删，分级报告）
sk_deep_scan(){
  _dir="${1:-/storage/emulated/0}"
  sherry_scan_allowed "$_dir/probe" || { echo "[sherry] deny: $_dir out of scan scope"; return 2; }
  _rpt="$SK_STATUS/scan_$(date +%y%m%d-%H%M%S).txt"
  {
    echo "[sherry] deep_scan report $(date '+%y%m%d-%H%M%S') target=$_dir"
    find "$_dir" -maxdepth 3 -type f 2>/dev/null > "$SK_STATUS/.scan_list"
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      g=$(sherry_grade "$f")
      sz=$(wc -c < "$f" 2>/dev/null || echo 0)
      printf '%s\t%s\t%s\n' "$g" "$sz" "$f"
    done < "$SK_STATUS/.scan_list"
    rm -f "$SK_STATUS/.scan_list" 2>/dev/null
  } > "$_rpt"
  sk_log INFO "deep_scan $_dir -> $_rpt"
  echo "[sherry] scan done: $_rpt (scan only, nothing deleted)"
}
