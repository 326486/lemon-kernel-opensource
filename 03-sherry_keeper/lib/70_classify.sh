#!/system/bin/sh
# 70_classify.sh — 15类自主分类（v9.3.0）
# 分类文件夹/回收站 在用户区可见；manifest 留痕可逆；默认不碰系统铃声/闹钟/通知目录
SK_CLASSIFY='/storage/emulated/0/分类文件夹'
SK_CLASSIFY_MANIFEST="$SK_CLASSIFY/分类manifest.tsv"

classify_cat(){
  case "$(printf '%s' "$1" | tr 'A-Z' 'a-z')" in
    *.apk|*.apks|*.xapk) echo '01-安装包';;
    *.mp3|*.flac|*.wav|*.m4a|*.ogg|*.aac|*.wma) echo '02-音乐';;
    *.mp4|*.mkv|*.avi|*.mov|*.flv|*.wmv|*.webm|*.m4v|*.3gp) echo '03-视频';;
    *.jpg|*.jpeg|*.png|*.gif|*.webp|*.bmp|*.heic|*.heif|*.svg) echo '04-图片';;
    *.pdf|*.doc|*.docx|*.xls|*.xlsx|*.ppt|*.pptx|*.txt|*.md|*.csv|*.rtf) echo '05-文档';;
    *.zip|*.rar|*.7z|*.tar|*.gz|*.bz2|*.xz) echo '06-压缩包';;
    *.epub|*.mobi|*.azw3|*.azw) echo '07-电子书';;
    *.ttf|*.otf|*.woff|*.woff2) echo '08-字体';;
    *.py|*.sh|*.js|*.ts|*.java|*.c|*.cpp|*.h|*.json|*.xml|*.yaml|*.yml|*.html|*.css) echo '09-代码脚本';;
    *.torrent) echo '10-种子';;
    *.iso|*.img|*.bin) echo '11-镜像';;
    *.amr|*.opus|*.awb) echo '12-录音';;
    *.db|*.sqlite|*.sqlite3|*.mdb|*.sql) echo '13-数据库';;
    *.bak|*.conf|*.ini|*.cfg|*.properties|*.old) echo '14-配置备份';;
    *) echo '15-其他';;
  esac
}

sk_classify_init(){
  for c in 01-安装包 02-音乐 03-视频 04-图片 05-文档 06-压缩包 07-电子书 08-字体 09-代码脚本 10-种子 11-镜像 12-录音 13-数据库 14-配置备份 15-其他 回收站; do
    mkdir -p "$SK_CLASSIFY/$c" 2>/dev/null
  done
}

sk_auto_organize(){
  _dry=0; _srcs=""; _skiproot=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry) _dry=1; shift;;
      --src) _srcs="$2"; shift 2;;
      --skip-root) _skiproot=1; shift;;
      *) shift;;
    esac
  done
  sk_classify_init
  _sess="$SK_STATUS/.cls_session"
  : > "$_sess"
  if [ -n "$_srcs" ]; then
    printf '%s\n' "$_srcs" > "$SK_STATUS/.cls_srcs"
  else
    printf '%s\n' '/storage/emulated/0/Download' '/storage/emulated/0/UCDownloads' '/storage/emulated/0/Browser' '/storage/emulated/0/Documents' '/storage/emulated/0/My Documents' '/storage/emulated/0/Music' '/storage/emulated/0/音乐' '/storage/emulated/0/Movies' '/storage/emulated/0/Pictures' '/storage/emulated/0/DCIM' '/storage/emulated/0/Recordings' '/storage/emulated/0/Audiobooks' '/storage/emulated/0/Podcasts' > "$SK_STATUS/.cls_srcs"
  fi
  {
    while IFS= read -r d; do
      [ -d "$d" ] || continue
      find "$d" -maxdepth 3 -type f ! -name '.*' 2>/dev/null
    done < "$SK_STATUS/.cls_srcs"
    if [ "$_skiproot" = 0 ]; then
      find /storage/emulated/0 -maxdepth 1 -type f ! -name '.*' 2>/dev/null
    fi
  } > "$SK_STATUS/.cls_cand"
  _n=0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    case "$f" in "$SK_CLASSIFY"/*) continue;; esac
    _cat=$(classify_cat "$f")
    _base=$(basename "$f")
    _dst="$SK_CLASSIFY/$_cat/$_base"
    _i=1
    while [ -e "$_dst" ]; do
      _dst="$SK_CLASSIFY/$_cat/${_base%.*}_$_i.${_base##*.}"
      _i=$((_i+1))
    done
    if [ "$_dry" = 1 ]; then
      printf 'DRY\t%s\t%s\n' "$f" "$_dst" >> "$_sess"
    else
      if mv "$f" "$_dst" 2>/dev/null; then
        printf '%s\t%s\t%s\n' "$(date '+%y%m%d-%H%M%S')" "$f" "$_dst" >> "$SK_CLASSIFY_MANIFEST"
        printf 'MOVED\t%s\t%s\n' "$f" "$_dst" >> "$_sess"
        sk_count classified >/dev/null
      fi
    fi
    _n=$((_n+1))
  done < "$SK_STATUS/.cls_cand"
  _rpt="$SK_STATUS/classify_$(date +%y%m%d-%H%M%S).txt"
  {
    echo "[sherry] classify report $(date '+%y%m%d-%H%M%S') dry=$_dry total=$_n"
    for c in 01-安装包 02-音乐 03-视频 04-图片 05-文档 06-压缩包 07-电子书 08-字体 09-代码脚本 10-种子 11-镜像 12-录音 13-数据库 14-配置备份 15-其他; do
      _k=$(grep -c "/$c/" "$_sess" 2>/dev/null)
      echo "$c: ${_k:-0}"
    done
  } > "$_rpt"
  rm -f "$SK_STATUS/.cls_cand" "$SK_STATUS/.cls_srcs" 2>/dev/null
  sk_log INFO "auto_organize dry=$_dry total=$_n report=$_rpt"
  if [ "$_dry" = 1 ]; then
    echo "[sherry] classify dry-run: $_n candidates (nothing moved), report=$_rpt"
  else
    echo "[sherry] classify done: $_n files sorted, report=$_rpt"
  fi
}

sk_restore_classify(){
  _n="${1:-1}"
  case "$_n" in all) _n=999999;; esac
  [ -f "$SK_CLASSIFY_MANIFEST" ] || { echo "[sherry] no classify manifest"; return 1; }
  _r=0
  tail -n "$_n" "$SK_CLASSIFY_MANIFEST" | tac > "$SK_STATUS/.rst_list" 2>/dev/null
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    _src=$(printf '%s' "$line" | cut -f2)
    _dst=$(printf '%s' "$line" | cut -f3)
    if [ -e "$_dst" ] && [ ! -e "$_src" ]; then
      mkdir -p "$(dirname "$_src")" 2>/dev/null
      mv "$_dst" "$_src" 2>/dev/null && { _r=$((_r+1)); sk_log INFO "restore $_dst -> $_src"; }
    fi
  done < "$SK_STATUS/.rst_list"
  rm -f "$SK_STATUS/.rst_list" 2>/dev/null
  echo "[sherry] restored $_r files to original paths"
}
