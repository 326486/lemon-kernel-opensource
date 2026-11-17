#!/system/bin/sh
# ============================================================
# lemon_store.sh v1.0 · 存储增强（大文件排行 / 重复文件）
# 20261001 · 小柠檬本体
# 用法: lemon_store.sh {bigfiles [路径] [n]|dupfile [路径] [最小KB] [上限]}
# ============================================================
clean(){ case "$1" in \$*) printf '' ;; *) printf '%s' "$1" ;; esac; }
TMP=/data/local/tmp/lemon_store
mkdir -p "$TMP" 2>/dev/null

do_bigfiles(){
  p=$(clean "$1"); [ -z "$p" ] && p=/storage/emulated/0
  n=$(clean "$2"); [ -z "$n" ] && n=25
  [ -d "$p" ] || { printf '[x] 目录不存在: %s\n' "$p"; return 1; }
  printf '===== 💾 大文件 TOP%s — %s =====\n' "$n" "$p"
  find "$p" -type f -size +5M -printf '%s|%p\n' 2>/dev/null | sort -rn | head -n "$n" \
    | awk -F'|' '{printf "  %8.1f MB  %s\n", $1/1048576, $2}'
  printf '\n-- 分区占用 --\n'
  df -h "$p" 2>/dev/null | sed 's/^/  /'
}

do_dupfile(){
  p=$(clean "$1"); [ -z "$p" ] && p=/storage/emulated/0
  mink=$(clean "$2"); [ -z "$mink" ] && mink=1024
  lim=$(clean "$3"); [ -z "$lim" ] && lim=4000
  [ -d "$p" ] || { printf '[x] 目录不存在: %s\n' "$p"; return 1; }
  printf '===== 💾 重复文件查找 — %s (>=%sKB, 上限%s) =====\n' "$p" "$mink" "$lim"
  T="$TMP/cand.txt"; S="$TMP/sizes.txt"; H="$TMP/hash.txt"
  find "$p" -type f -size +${mink}k -printf '%s|%p\n' 2>/dev/null | head -n "$lim" > "$T"
  tot=$(wc -l < "$T"); printf '候选文件: %s\n' "$tot"
  awk -F'|' '{c[$1]++} END{for(k in c) if(c[k]>1) print k}' "$T" | sort -rn | head -n 30 > "$S"
  g=$(wc -l < "$S")
  if [ "$g" -eq 0 ]; then printf '  没有同尺寸候选 → 无重复\n'; return 0; fi
  printf '同尺寸组: %s → 逐一算 md5\n\n' "$g"
  : > "$H"
  while read -r sz; do
    awk -F'|' -v s="$sz" '$1==s{print $2}' "$T" | while IFS= read -r f; do
      m=$(md5sum "$f" 2>/dev/null | cut -d' ' -f1)
      [ -n "$m" ] && printf '%s|%s\n' "$m" "$f" >> "$H"
    done
  done < "$S"
  awk -F'|' '{c[$1]++; g[$1]=g[$1] "\n    " $2} END{
    for(k in c) if(c[k]>1){ printf "  ── 重复组 [%s] x%d%s\n", substr(k,1,12), c[k], g[k]; n++; waste+=c[k]-1 }
    printf "\n  共 %d 组重复\n", n
  }' "$H"
  printf '[提示] 清理前请确认内容，可用 file_rm 删除冗余副本\n'
}

case "$1" in
  bigfiles) do_bigfiles "$2" "$3" ;;
  dupfile)  do_dupfile "$2" "$3" "$4" ;;
  *) printf '用法: lemon_store.sh {bigfiles [路径] [n]|dupfile [路径] [最小KB] [上限]}\n' ;;
esac
