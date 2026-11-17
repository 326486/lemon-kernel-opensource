#!/system/bin/sh
# ============================================================
# fscan.sh v1.0 · Flutter / Dart AOT 解析引擎桥
# 取长补短计划 · 261031 · 小柠檬
# 引擎：aotopsy（Blutter 后端，静态链接，无运行时依赖）
# 入参全部走环境变量（#572 铁律），由 LemonCore 单引号转义
#   FL_CMD   info | scan | grep | list | clean   (默认 info)
#   FL_PATH  目标：APK / libapp.so / 输出目录
#   FL_OUT   指定输出目录（可空=按 sha256 自动命名）
#   FL_KW    关键词（grep 用）
#   FL_OPT   --all --graph --fast --force
# 防空转（#249）：所有外部调用带 timeout；循环有界；输出 head 限长
# ============================================================
ROOT=/data/adb/lemon_kernel/lemon/flutter
BIN=$ROOT/bin/aotopsy
OUTD=$ROOT/out
LOGD=$ROOT/log
KEEP=3

CMD=${FL_CMD:-info}
T=${FL_PATH:-}
KW=${FL_KW:-}
OPT=${FL_OPT:-}
TS=$(date +%Y%m%d-%H%M%S)

mkdir -p "$OUTD" "$LOGD" 2>/dev/null

die(){ echo "ERR $*"; exit 2; }
[ -x "$BIN" ] || die "引擎缺失 $BIN"

hsz(){
  b=$(stat -c %s "$1" 2>/dev/null || echo 0)
  if [ "$b" -ge 1048576 ]; then
    echo "$((b / 1048576))MB"
  else
    echo "$((b / 1024))KB"
  fi
}

magic4(){ head -c 4 "$1" 2>/dev/null | od -An -tx1 | tr -d " \n"; }
is_zip(){ [ "$(magic4 "$1")" = "504b0304" ]; }
is_elf(){ [ "$(magic4 "$1")" = "7f454c46" ]; }

AOPT=""
case "$OPT" in *--all*)   AOPT="$AOPT --all" ;; esac
case "$OPT" in *--graph*) AOPT="$AOPT --graph" ;; esac
case "$OPT" in *--fast*)  : ;; *) AOPT="$AOPT --decompile" ;; esac
force=0
case "$OPT" in *--force*) force=1 ;; esac
slim=0
case "$OPT" in *--slim*) slim=1 ;; esac

jget(){
  v=$(grep -o "\"$2\": *\"[^\"]*\"" "$1" 2>/dev/null | head -1 | sed 's/.*: *"//; s/"$//')
  if [ -n "$v" ]; then echo "$v"; return 0; fi
  grep -o "\"$2\": *[0-9][0-9.]*" "$1" 2>/dev/null | head -1 | sed 's/.*: *//'
}

dev_list(){
  n=0
  for p in /data/app/*/*/lib/arm64/libapp.so /data/app/*/*/lib/arm/libapp.so; do
    [ -f "$p" ] || continue
    d=${p%/lib/*}
    pkg=$(basename "$d" | sed 's/-[0-9a-zA-Z_-]*==$//')
    echo "  $(hsz "$p")  $pkg"
    n=$((n + 1))
    [ $n -ge 15 ] && break
  done
  [ "$n" = "0" ] && echo "  (设备内未发现 Flutter AOT 应用)"
  return 0
}

do_info(){
  if [ -z "$T" ]; then
    echo "【设备内 Flutter 应用】"
    dev_list
    echo
    echo "【用法】"
    echo "  flutter_info path=<APK>      APK 是否 Flutter + Dart 版本 + libapp 指纹"
    echo "  flutter_scan path=<APK|libapp.so>  全流程解析（汇编/类/伪代码/线索）"
    return 0
  fi
  [ -f "$T" ] || die "文件不存在：$T"
  kind=bin
  is_zip "$T" && kind=apk
  is_elf "$T" && kind=elf
  case "$kind" in
    apk)
      echo "【APK 侦察】$(basename "$T")  $(hsz "$T")"
      mkdir -p "$OUTD/.probe"
      timeout 180 "$BIN" find-libapp --apk "$T" --out "$OUTD/.probe" >"$LOGD/find-$TS.log" 2>&1
      j=$(ls -t "$OUTD"/.probe/*_find_libapp.json 2>/dev/null | head -1)
      [ -n "$j" ] || die "解析失败：$(tail -3 "$LOGD/find-$TS.log")"
      if ! grep -q '"found": *true' "$j"; then
        echo "  判定: 未检出 Dart AOT（非 Flutter 或已剥离）"
        grep -o '"reason": *"[^"]*"' "$j" | head -1
        return 1
      fi
      ip=$(grep -o '"path_in_apk": *"[^"]*"' "$j" | sed 's/.*: *"//; s/"$//' | grep 'libapp\.so$' | head -1)
      dv=$(jget "$j" dart_version)
      if [ -z "$ip" ] || [ -z "$dv" ]; then
        echo "  判定: 疑似（仅命中 Dart 符号，无 libapp.so 或无 Dart 版本标记）"
        echo "  提示: 多见于逆向工具包/自研 so，不是可解析的 Flutter 应用"
        return 1
      fi
      echo "  判定: Flutter / Dart AOT ✅"
      echo "  Dart VM : $dv"
      echo "  libapp  : $ip"
      echo "  大小    : $(jget "$j" size) B"
      echo "  sha256  : $(jget "$j" sha256)"
      echo "  snapshot: $(jget "$j" snapshot_hash)"
      echo
      echo "  下一步  : flutter_scan path=$T"
      ;;
    *)
      echo "【文件侦察】$(basename "$T")  $(hsz "$T")"
      magic=$(head -c 4 "$T" 2>/dev/null | od -An -tx1 | tr -d ' \n')
      if [ "$magic" = "7f454c46" ]; then
        echo "  类型: ELF（疑似 libapp.so / 共享库）"
      else
        echo "  类型: 非 ELF（magic=$magic）"
      fi
      echo "  sha256(前16): $(sha256sum "$T" | cut -c1-16)"
      echo "  下一步  : flutter_scan path=$T"
      ;;
  esac
}

do_scan(){
  [ -n "$T" ] || die "需要 FL_PATH（APK 或 libapp.so）"
  [ -f "$T" ] || die "文件不存在：$T"
  lib=""
  dv=""
  name=$(printf '%s' "$(basename "$T" | sed 's/\.[a-zA-Z0-9]*$//')" | tr -c 'A-Za-z0-9._-' '_')
  name=${name%_}
  kind=bin
  is_zip "$T" && kind=apk
  is_elf "$T" && kind=elf
  case "$kind" in
    apk)
      mkdir -p "$OUTD/.probe"
      timeout 180 "$BIN" find-libapp --apk "$T" --out "$OUTD/.probe" >"$LOGD/find-$TS.log" 2>&1
      j=$(ls -t "$OUTD"/.probe/*_find_libapp.json 2>/dev/null | head -1)
      [ -n "$j" ] || die "未产出 find_libapp.json"
      grep -q '"found": *true' "$j" || die "该包不含 Dart AOT"
      ip=$(grep -o '"path_in_apk": *"[^"]*"' "$j" | sed 's/.*: *"//; s/"$//' | grep 'libapp\.so$' | head -1)
      dv=$(jget "$j" dart_version)
      [ -n "$ip" ] || die "未找到 libapp.so（可能只有 Dart 符号的工具包，或已剥离）"
      [ -n "$dv" ] || echo "  警告: 未取到 Dart 版本，按通用模式解析"
      lib=$OUTD/.probe/$name-libapp.so
      timeout 120 unzip -p "$T" "$ip" > "$lib" 2>/dev/null
      [ -f "$lib" ] || die "抽取 $ip 失败"
      [ "$(stat -c %s "$lib")" -gt 4096 ] || die "抽取结果异常（$(hsz "$lib")）"
      ;;
    elf)
      lib=$T
      ;;
    *)
      die "既非 APK/ZIP 也非 ELF，无法解析：$(basename "$T")"
      ;;
  esac

  [ -f "$lib" ] || die "libapp 不存在：$lib"
  sha=$(sha256sum "$lib" | cut -c1-16)
  out=${FL_OUT:-}
  [ -n "$out" ] || out=$OUTD/$name-$sha

  lk=$OUTD/.lock-$sha
  trap '[ -n "${lk:-}" ] && rmdir "$lk" 2>/dev/null' EXIT INT TERM
  if [ "$force" = "0" ] && [ ! -f "$out/flutter_meta.json" ]; then
    if ! mkdir "$lk" 2>/dev/null; then
      echo "【排队】同一 libapp 正在解析，等待中…"
      i=0
      while [ $i -lt 90 ]; do
        [ -f "$out/flutter_meta.json" ] && break
        sleep 2
        i=$((i + 1))
      done
      if [ -f "$out/flutter_meta.json" ]; then
        echo "【复用缓存】$out（他人已完成）"
        lk=""
      else
        echo "  等待超时：接管陈旧锁（前一个任务已死）"
        rmdir "$lk" 2>/dev/null
        mkdir "$lk" 2>/dev/null
      fi
    fi
  fi

  if [ -f "$out/.running" ]; then
    age=$(( $(date +%s) - $(stat -c %Y "$out/.running" 2>/dev/null || echo 0) ))
    if [ "$age" -lt 1200 ]; then
      die "该目录解析中（${age}s），等它完成或 FL_OUT 换目录"
    fi
    rm -f "$out/.running"
  fi
  if [ -f "$out/flutter_meta.json" ] && [ "$force" = "0" ]; then
    echo "【复用缓存】$out"
    echo "  （加 FL_OPT=--force 可强制重解析）"
  else
    mkdir -p "$out"
    : > "$out/.running"
    echo "【解析中】libapp=$(hsz "$lib")  dart=${dv:-未知}"
    echo "  引擎: $BIN $AOPT"
    timeout 900 "$BIN" "$lib" --out "$out" $AOPT >"$LOGD/scan-$TS.log" 2>&1
    rc=$?
    if [ ! -f "$out/flutter_meta.json" ]; then
      echo "!! 解析失败 rc=$rc，日志尾部："
      tail -12 "$LOGD/scan-$TS.log"
      rm -f "$out/.running"
      [ -n "${lk:-}" ] && rmdir "$lk" 2>/dev/null
      return 1
    fi
    echo "  完成 rc=$rc  日志: $LOGD/scan-$TS.log"
    rm -f "$out/.running"
    [ -n "${lk:-}" ] && rmdir "$lk" 2>/dev/null
  fi

  echo
  if [ "$slim" = "1" ]; then
    rm -rf "$out/asm" "$out/evidence.jsonl" 2>/dev/null
    rm -f "$out"/*.dot "$out"/*.sarif 2>/dev/null
    echo "  已瘦身 --slim（删 asm/evidence/dot/sarif）"
  fi
  echo "【产物】$out"
  for f in classes.jsonl functions.jsonl pool_immediates.jsonl crypto_findings.jsonl network_endpoints.jsonl platform_channels.jsonl native_capabilities.jsonl string_value_xref.jsonl; do
    [ -f "$out/$f" ] && echo "  $(wc -l < "$out/$f" | tr -d ' ') 条  $f"
  done
  [ -d "$out/dart" ] && echo "  $(ls "$out/dart" 2>/dev/null | wc -l | tr -d ' ') 个  dart/（Dart 伪代码）"
  [ -d "$out/asm" ] && echo "  $(ls "$out/asm" 2>/dev/null | wc -l | tr -d ' ') 个  asm/（函数汇编）"
  echo
  echo "【线索速览】"
  [ -s "$out/crypto_findings.jsonl" ] && { echo "  加密:"; head -3 "$out/crypto_findings.jsonl" | cut -c1-180; }
  [ -s "$out/network_endpoints.jsonl" ] && { echo "  网络:"; head -3 "$out/network_endpoints.jsonl" | cut -c1-180; }
  [ -s "$out/platform_channels.jsonl" ] && { echo "  通道:"; head -3 "$out/platform_channels.jsonl" | cut -c1-160; }
  echo
  echo "  搜索: flutter_grep kw=<类名/字符串>"
}

do_grep(){
  [ -n "$KW" ] || die "需要 FL_KW"
  d=${T:-}
  [ -n "$d" ] || d=$(ls -1td "$OUTD"/*/ 2>/dev/null | head -1)
  [ -d "$d" ] || die "无解析结果，先跑 flutter_scan"
  echo "【搜索】$KW"
  echo "  目录: $d"
  echo
  timeout 90 grep -rIn --exclude=evidence.jsonl --exclude=*.dot --include=*.dart --include=*.jsonl --include=*.json -- "$KW" "$d" 2>/dev/null | head -12 | cut -c1-220
  rc=$?
  [ $rc -eq 124 ] && echo "  (已达 90s 上限，请缩小范围：param path=<输出目录>)"
  return 0
}

do_list(){
  echo "【解析历史】$OUTD"
  ls -1t "$OUTD" 2>/dev/null | grep -v '^\.' | head -10
  echo
  echo "  占用: $(du -sh "$OUTD" 2>/dev/null | cut -f1)  保留最近 $KEEP 个（clean 清理）"
}

do_clean(){
  n=0
  ls -1td "$OUTD"/*/ 2>/dev/null | tail -n +$((KEEP + 1)) > "$LOGD/clean-$TS.lst"
  while read -r d; do
    [ -n "$d" ] || continue
    rm -rf "$d" && n=$((n + 1))
  done < "$LOGD/clean-$TS.lst"
  rm -rf "$OUTD/.probe"
  echo "已清理 $n 个旧解析目录（保留最近 $KEEP 个）"
}

case "$CMD" in
  info)  do_info ;;
  scan)  do_scan ;;
  grep)  do_grep ;;
  list)  do_list ;;
  clean) do_clean ;;
  *)     die "未知 FL_CMD=$CMD（info|scan|grep|list|clean）" ;;
esac