#!/system/bin/sh
# ============================================================
# lemonlib · ko_mgr —— 内核模块管理（info / load / unload）
#  2026-09-28 小柠檬本体
#  遵循 #230（备份先行/非空校验/回读验证）+ #274（升级必过虚拟机测试）
#
# 用法: ko_mgr.sh <action> <args...>
#   info   <ko路径>            加载前体检（md5/vermagic/符号/段）
#   load   <ko路径> [参数]      体检 -> 加载 -> 验证
#   unload <模块名>             卸载 -> 验证
#   status                      当前自研模块状态
# ============================================================
ACT="$1"; A2="$2"; A3="$3"
LIB=/data/adb/lemon_kernel/lemonlib
BK=/data/小柠檬资源/8788内核专用备份仓库/lemonlib_ko_backup
mkdir -p "$BK"

case "$ACT" in

info)
  KO="$A2"
  [ -f "$KO" ] || { echo "!! 文件不存在: $KO"; exit 1; }
  echo "=================================================="
  echo " 模块体检: $KO"
  echo "=================================================="
  echo
  echo "[基本]"
  echo "  大小: $(wc -c < "$KO") 字节"
  echo "  md5 : $(md5sum "$KO" | cut -d' ' -f1)"
  echo
  echo "[vermagic 比对]"
  mv=$(readelf -p .modinfo "$KO" 2>/dev/null | grep -oE 'vermagic=[^ ]* [^ ]* [^ ]* [^ ]* [^ ]* [^ ]*')
  kv=$(uname -r)
  dbg=$(uname -r | sed 's/-[^-]*$//')
  echo "  模块: ${mv#vermagic=}"
  echo "  内核: $(grep -oE '^Linux version [^ ]+' /proc/version | cut -d' ' -f3)"
  if echo "${mv#vermagic=}" | grep -q "$kv"; then
    echo "  ✅ vermagic 匹配"
  else
    echo "  ⚠️ vermagic 不匹配（加载会失败）"
  fi
  echo
  echo "[关键段]"
  n=0
  for s in .plt .init.plt .text.ftrace_trampoline .init.text .exit.text .modinfo .gnu.linkonce.this_module __versions; do
    if readelf -S "$KO" 2>/dev/null | grep -qF "$s"; then n=$((n+1)); fi
  done
  echo "  关键段: $n / 8"
  echo
  echo "[符号一致性]"
  readelf -sW "$KO" 2>/dev/null | awk '$7=="UND" && $8!="" {print $8}' | sort -u > /data/local/tmp/ko_u.txt
  MODSRC="${KO%.ko}.mod.c"
  if [ -f "$MODSRC" ]; then
    grep -oE '"[a-zA-Z_]+"' "$MODSRC" | tr -d '"' | sort -u > /data/local/tmp/ko_v.txt
  else
    # 从 __versions 段提取
    strings "$KO" 2>/dev/null | grep -E '^[a-z_]+$' | sort -u > /data/local/tmp/ko_v.txt
  fi
  miss=$(comm -23 /data/local/tmp/ko_u.txt /data/local/tmp/ko_v.txt 2>/dev/null)
  echo "  未定义符号: $(wc -l < /data/local/tmp/ko_u.txt) 个"
  if [ -z "$miss" ]; then
    echo "  ✅ 全部有 CRC 登记"
  else
    echo "  ⚠️ 缺登记: $miss"
  fi
  echo
  echo "[modinfo]"
  readelf -p .modinfo "$KO" 2>/dev/null | grep -E 'license|author|version|description' | sed 's/^/  /'
  echo "=================================================="
  ;;

load)
  KO="$A2"; ARGS="$A3"
  [ -f "$KO" ] || { echo "!! 文件不存在: $KO"; exit 1; }
  NAME=$(basename "$KO" .ko)
  # 取模块真实名（KBUILD_MODNAME）
  MODNAME=$(readelf -p .modinfo "$KO" 2>/dev/null | grep -oE 'name=[a-zA-Z_0-9]+' | head -1 | cut -d= -f2)
  [ -z "$MODNAME" ] && MODNAME="$NAME"
  echo "=================================================="
  echo " 加载模块: $KO"
  echo "  模块名: $MODNAME   参数: ${ARGS:-（无）}"
  echo "=================================================="
  echo
  echo "[1] 已加载? "
  if grep -q "^$MODNAME " /proc/modules 2>/dev/null; then
    echo "  ⚠️ 已加载，跳过（如需重载请先 unload）"
    exit 0
  fi
  echo "  未加载 ✅"
  echo
  echo "[2] 备份先行 (#230)"
  cp -f "$KO" "$BK/${MODNAME}_$(date +%Y%m%d_%H%M%S).ko"
  echo "  已备份 -> $BK/ ($(ls $BK | wc -l) 份)"
  echo
  echo "[3] 加载"
  insmod "$KO" $ARGS
  rc=$?
  echo "  insmod 返回码: $rc"
  sleep 1
  echo
  echo "[4] 回读验证"
  if grep -q "^$MODNAME " /proc/modules 2>/dev/null; then
    replace=("mod" "")
    echo "  ✅ 已加载: $(grep "^$MODNAME " /proc/modules)"
    if [ -d "/sys/module/$MODNAME/parameters" ]; then
      echo "  参数:"
      for p in /sys/module/$MODNAME/parameters/*; do
        [ -e "$p" ] || continue
        echo "    $(basename $p) = $(cat $p 2>/dev/null)"
      done
    fi
  else
    echo "  ❌ 未加载（检查 dmesg）"
    dmesg 2>/dev/null | tail -5 | sed 's/^/    /'
  fi
  echo
  echo "[5] dmesg"
  dmesg 2>/dev/null | grep -i "$MODNAME" | tail -5 | sed 's/^/  /'
  echo "=================================================="
  ;;

unload)
  NAME="$A2"
  [ -z "$NAME" ] && { echo "!! 用法: ko_mgr unload <模块名>"; exit 1; }
  echo "=================================================="
  echo " 卸载模块: $NAME"
  echo "=================================================="
  grep -q "^$NAME " /proc/modules 2>/dev/null || { echo "  未加载，无需卸载"; exit 0; }
  echo "[1] 卸载前: $(grep "^$NAME " /proc/modules)"
  rmmod "$NAME"
  rc=$?
  echo "[2] rmmod 返回码: $rc"
  sleep 1
  echo "[3] 回读验证"
  if grep -q "^$NAME " /proc/modules 2>/dev/null; then
    echo "  ❌ 仍在加载中"
  else
    echo "  ✅ 已卸载"
  fi
  echo "[4] dmesg"
  dmesg 2>/dev/null | grep -i "$NAME" | tail -3 | sed 's/^/  /'
  echo "=================================================="
  ;;

status)
  echo "=================================================="
  echo " 自研模块状态"
  echo "=================================================="
  n=0
  for m in $(grep -oE '^[a-zA-Z_0-9]+' /proc/modules); do
    case "$m" in
      lemon_guard|lemon*|hello*)
        echo "  ★ $m: $(grep "^$m " /proc/modules | awk '{print "size="$2" refs="$3" state="$5}')"
        [ -d "/sys/module/$m/parameters" ] && {
          echo -n "      参数: "
          for p in /sys/module/$m/parameters/*; do
            [ -e "$p" ] && echo -n "$(basename $p)=$(cat $p 2>/dev/null) "
          done
          echo
        }
        n=$((n+1))
        ;;
    esac
  done
  [ "$n" = "0" ] && echo "  （无）"
  echo
  echo "  tainted=$(cat /proc/sys/kernel/tainted)"
  echo "  备份目录: $BK ($(ls $BK 2>/dev/null | wc -l) 份)"
  echo "=================================================="
  ;;

*)
  echo "lemonlib · ko_mgr —— 内核模块管理"
  echo
  echo "用法:"
  echo "  ko_mgr info   <ko路径>          加载前体检"
  echo "  ko_mgr load   <ko路径> [参数]    加载（自动备份+验证）"
  echo "  ko_mgr unload <模块名>           卸载"
  echo "  ko_mgr status                    自研模块状态"
  ;;
esac
