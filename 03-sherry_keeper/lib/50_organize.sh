#!/system/bin/sh
# 50_organize.sh — 按类型归类
sk_organize(){
  _dir="$1"
  [ -d "$_dir" ] || { echo "[sherry] organize: dir not found"; return 2; }
  sherry_path_allowed "$_dir/probe" || { echo "[sherry] deny: $_dir out of whitelist"; return 2; }
  find "$_dir" -maxdepth 1 -type f > "$SK_STATUS/.org_list" 2>/dev/null
  _n=0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    case "$f" in
      *.jpg|*.jpeg|*.png|*.gif|*.webp|*.bmp) c=Images;;
      *.mp3|*.wav|*.flac|*.m4a|*.ogg) c=Audio;;
      *.mp4|*.mkv|*.avi|*.mov) c=Video;;
      *.pdf|*.doc|*.docx|*.txt|*.md|*.xls|*.xlsx|*.ppt|*.pptx) c=Docs;;
      *.zip|*.tar|*.gz|*.7z|*.rar|*.apk) c=Archives;;
      *) c=Other;;
    esac
    mkdir -p "$_dir/$c" 2>/dev/null
    mv "$f" "$_dir/$c/" 2>/dev/null && { _n=$((_n+1)); sk_count organized >/dev/null; }
  done < "$SK_STATUS/.org_list"
  rm -f "$SK_STATUS/.org_list" 2>/dev/null
  echo "[sherry] organized $_n files -> $_dir"
}
