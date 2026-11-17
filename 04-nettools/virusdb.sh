#!/system/bin/sh
# ============================================================
# virusdb.sh v1.0 · 病毒库管理（内核侧数据层）
# 20261004 · 小柠檬本体 · 授权：小良
# ------------------------------------------------------------
# 数据源: https://yl-tool-data.pages.dev  (safe1/safe2/mian1/mian2/key)
#    safe1=100%病毒包名  safe2=可能病毒包名
#    mian1=100%病毒名称  mian2=可能病毒名称  key=可疑关键字
# 兜底源: 本机已装游龙护盾 shared_prefs（离线可用）
#
# 用法:
#   virusdb.sh update           联网更新全部 5 库
#   virusdb.sh update --local   从本机游龙 prefs 离线导入
#   virusdb.sh status           库状态
#   virusdb.sh show <lib>       打印某库
#   virusdb.sh check <包名> [名称]  单条判定(P0/P1/clean)
# ============================================================
VDB=/data/adb/lemon_kernel/conf/virusdb
BASE="https://yl-tool-data.pages.dev"
UA="LemonVirus/1.0"
LOCAL_XML="/data/data/com.youlong.hd/shared_prefs/virus_db_prefs.xml"
LIBS="certain_pkgs:safe1.json suspect_pkgs:safe2.json certain_names:mian1.json suspect_names:mian2.json keys:key.json"
CURL=$(command -v curl 2>/dev/null || echo /data/data/com.termux/files/usr/bin/curl)
mkdir -p "$VDB" 2>/dev/null

# 清洗：兼容 JSON 数组与纯行文本（首字符是 [ 才做 JSON 展平）
clean_in() {
  _f="$1"
  _h=$(head -c 1 "$_f" 2>/dev/null)
  if [ "$_h" = "[" ]; then
    tr -d '[]"' < "$_f" 2>/dev/null | tr ',' '\n' | awk '{$1=$1} NF'
  else
    awk '{$1=$1} NF' "$_f" 2>/dev/null
  fi
}

fetch_one() {
  _n="$1"; _f="$2"
  _o="$VDB/$_n.txt"; _t="$VDB/.dl.$_n"
  rm -f "$_t" 2>/dev/null
  timeout 30 "$CURL" -sS -f --max-time 25 -A "$UA" "$BASE/$_f" -o "$_t" 2>/dev/null || {
    rm -f "$_t" 2>/dev/null; printf 'FAIL %-14s 网络不可达\n' "$_n"; return 1; }
  clean_in "$_t" > "$VDB/.c.$_n" 2>/dev/null
  _c=$(wc -l < "$VDB/.c.$_n" 2>/dev/null | tr -d ' ')
  [ -z "$_c" ] && _c=0
  if [ "$_c" -lt 1 ]; then
    rm -f "$_t" "$VDB/.c.$_n" 2>/dev/null; printf 'FAIL %-14s 空文件\n' "$_n"; return 1
  fi
  cat "$VDB/.c.$_n" > "$_o" 2>/dev/null
  rm -f "$_t" "$VDB/.c.$_n" 2>/dev/null
  printf 'OK   %-14s %s 条\n' "$_n" "$_c"
  return 0
}

import_local() {
  [ -f "$LOCAL_XML" ] || { echo "本机无游龙 prefs: $LOCAL_XML"; return 1; }
  _ok=0
  for kv in $LIBS; do
    _n=${kv%%:*}
    awk -v k="name=\"$_n\"" '
      index($0,k)>0 {
        s=$0; sub(/^[^>]*>/,"",s); sub(/<\/string>.*$/,"",s);
        gsub(/&#10;/,"\n",s); print s; exit
      }' "$LOCAL_XML" 2>/dev/null | awk '{$1=$1} NF' > "$VDB/.L.$_n" 2>/dev/null
    _c=$(wc -l < "$VDB/.L.$_n" 2>/dev/null | tr -d ' ')
    [ -z "$_c" ] && _c=0
    if [ "$_c" -ge 1 ]; then
      cat "$VDB/.L.$_n" > "$VDB/$_n.txt" 2>/dev/null
      printf 'OK   %-14s %s 条\n' "$_n" "$_c"; _ok=$((_ok+1))
    else
      printf 'SKIP %-14s\n' "$_n"
    fi
    rm -f "$VDB/.L.$_n" 2>/dev/null
  done
  { echo "source=local(youLong prefs)"; echo "time=$(date '+%Y-%m-%d %H:%M:%S')"; echo "ok=$_ok"; } > "$VDB/meta.txt" 2>/dev/null
  [ "$_ok" -gt 0 ] && return 0 || return 1
}

cmd_status() {
  echo "病毒库目录: $VDB"
  _t=0
  for kv in $LIBS; do
    _n=${kv%%:*}
    if [ -f "$VDB/$_n.txt" ]; then
      _c=$(wc -l < "$VDB/$_n.txt" 2>/dev/null | tr -d ' ')
      printf '  %-14s %5s 条\n' "$_n" "$_c"; _t=$((_t+_c))
    else
      printf '  %-14s    --\n' "$_n"
    fi
  done
  echo "  合计 $_t 条"
  [ -f "$VDB/meta.txt" ] && { echo "-- 元信息 --"; cat "$VDB/meta.txt"; }
}

_hit() {
  [ -f "$VDB/$1.txt" ] || return 1
  awk -v v="$2" 'v!="" && $0==v {f=1} END {exit !f}' "$VDB/$1.txt"
}

cmd_check() {
  _p="$1"; _l="$2"
  _pl=$(printf '%s' "$_p" | tr 'A-Z' 'a-z')
  _ll=$(printf '%s' "$_l" | tr 'A-Z' 'a-z')
  if _hit certain_pkgs "$_p" || _hit certain_pkgs "$_pl"; then echo "P0 确定病毒·包名命中"; return 0; fi
  if [ -n "$_l" ] && { _hit certain_names "$_l" || _hit certain_names "$_ll"; }; then echo "P0 确定病毒·名称命中"; return 0; fi
  if _hit suspect_pkgs "$_p" || _hit suspect_pkgs "$_pl"; then echo "P1 疑似·包名命中"; return 1; fi
  if [ -n "$_l" ] && { _hit suspect_names "$_l" || _hit suspect_names "$_ll"; }; then echo "P1 疑似·名称命中"; return 1; fi
  if [ -f "$VDB/keys.txt" ]; then
    while IFS= read -r k; do
      [ -z "$k" ] && continue
      case "$_p" in *"$k"*) echo "P1 疑似·包名含关键字[$k]"; return 1;; esac
      if [ -n "$_l" ]; then case "$_l" in *"$k"*) echo "P1 疑似·名称含关键字[$k]"; return 1;; esac; fi
    done < "$VDB/keys.txt"
  fi
  echo "clean"
  return 2
}

case "$1" in
  update)
    if [ "$2" = "--local" ]; then import_local; exit $?; fi
    echo "== 更新源: $BASE =="
    _ok=0; _bad=0
    for kv in $LIBS; do
      _n=${kv%%:*}; _f=${kv##*:}
      if fetch_one "$_n" "$_f"; then _ok=$((_ok+1)); else _bad=$((_bad+1)); fi
    done
    { echo "source=$BASE"; echo "time=$(date '+%Y-%m-%d %H:%M:%S')"; echo "epoch=$(date +%s)"; echo "ok=$_ok fail=$_bad"; } > "$VDB/meta.txt" 2>/dev/null
    echo "== 结果: OK=$_ok FAIL=$_bad =="
    [ "$_ok" -gt 0 ] && exit 0 || exit 1
    ;;
  status) cmd_status ;;
  show)
    if [ -f "$VDB/$2.txt" ]; then cat "$VDB/$2.txt"; else echo "无此库: $2"; ls "$VDB"/*.txt 2>/dev/null; fi ;;
  check) cmd_check "$2" "$3" ;;
  *) sed -n '2,18p' "$0"; exit 1 ;;
esac
