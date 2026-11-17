#!/system/bin/sh
# 小柠檬 · App 记忆库工具 v1.1  20260925（小柠檬本体）
# 背景：RikkaHub(com.xuanxing.app) 记忆已改为「按需读取」，本脚本提供 list/get/search/add
# 用法：appmem.sh list | get <id> | search <关键词> | add <内容>
# v1.1 修复：① get 的全角分隔符「｜」匹配 ② 无参时 shift 报错
export PATH=/data/adb/magisk:/system/bin:/system/xbin:$PATH
LIBS=/data/data/com.termux/files/usr/lib
S=/data/local/tmp/sqlite3
APP=/data/user/0/com.xuanxing.app
DB=$APP/databases/rikka_hub
MEM=$APP/files/memory/小柠檬App记忆库.md
SEP="｜"

ACT="$1"
if [ $# -gt 0 ]; then shift; fi

[ -f "$MEM" ] || { echo "NO_ARCHIVE $MEM"; exit 1; }

case "$ACT" in
list)
  echo "== App 记忆归档（按需读取模式）=="
  echo "文件: $MEM"
  echo "规模: $(wc -c < "$MEM") 字节 / $(wc -m < "$MEM") 字符"
  echo "---- 条目清单 ----"
  grep -n '^## \[id=' "$MEM"
  echo "---- 注入残留 MemoryEntity ----"
  LD_LIBRARY_PATH=$LIBS $S "$DB" "SELECT 'id='||id||' | '||assistant_id||' | '||length(content)||' 字符' FROM MemoryEntity;" 2>/dev/null
  ;;
get)
  [ -n "$1" ] || { echo "用法: appmem.sh get <id>"; exit 1; }
  awk -v id="$1" -v sep="$SEP" '
    /^## \[id=/ { f = (index($0, "## [id=" id sep) == 1) ? 1 : 0 }
    f { print }
  ' "$MEM"
  ;;
search)
  [ -n "$1" ] || { echo "用法: appmem.sh search <关键词>"; exit 1; }
  grep -n -F -B1 -A5 -- "$1" "$MEM" | head -120
  ;;
add)
  [ -n "$1" ] || { echo "用法: appmem.sh add <内容>"; exit 1; }
  printf '\n## [新增%s%s%s手动追加]\n\n%s\n\n---\n\n' "$SEP" "$(date '+%Y-%m-%d %H:%M')" "$SEP" "$1" >> "$MEM"
  echo "APPENDED ok, size=$(wc -c < "$MEM") 字节"
  ;;
*)
  echo "用法: appmem.sh list | get <id> | search <关键词> | add <内容>"
  ;;
esac
