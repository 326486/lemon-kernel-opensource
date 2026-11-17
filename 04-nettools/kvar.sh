#!/system/bin/sh
# lemonlib · kvar v1.2 —— 读内核变量/结构体（kprobe @符号 fetch）
# 2026-09-28 小柠檬本体
# ★ 无需 .ko，无需 kptr_restrict=0 —— 内核自己解析符号名
# v1.2 修复（QEMU 实测发现的 4 个真 bug）：
#   1) cleanup 幂等化：注销前 grep 确认探针存在（注销不存在的探针=ENOENT
#      会漏 write error；enabled 时直接注销=EBUSY，先 disable 再注销）
#   2) 挂探针成功与否只看 kprobe_events 内容（busybox echo 写失败 rc=0，
#      退出码不可信；内容验证在 toybox/busybox 都可靠）
#   3) sym 行数默认与宽度默认解耦（原 L=${W:-30} 被 u64 污染 → head -n u64）
#   4) struct 偏移 0 时退化为 @sym（内核拒 @sym+0 语法）
ACT="$1"; SYM="$2"; W="${3:-u64}"; OFF="$4"
TP=/sys/kernel/tracing
PROBE="lemonkvar"
TRIG="${5:-schedule}"
PENABLE="$TP/events/kprobes/$PROBE/enable"

cleanup() {
  [ -e "$PENABLE" ] && printf '0\n' > "$PENABLE" 2>/dev/null
  if grep -q "lemonkvar" $TP/kprobe_events 2>/dev/null; then
    printf '%s\n' "-:$PROBE" > "$TP/kprobe_events" 2>/dev/null
  fi
  return 0
}
trap cleanup EXIT INT TERM

wait_enable() {
  i=0
  while [ $i -lt 20 ]; do
    if [ -e "$PENABLE" ]; then
      printf '1\n' > "$PENABLE" 2>/dev/null && return 0
    fi
    sleep 0.1
    i=$((i+1))
  done
  return 1
}

case "$ACT" in
read|struct)
  [ -z "$SYM" ] && { echo "!! 缺符号名。用法: kvar read <符号> [宽度]"; exit 1; }
  if [ "$ACT" = "struct" ]; then
    [ -z "$OFF" ] && { echo "!! 缺偏移。用法: kvar struct <符号> <偏移> <宽度>"; exit 1; }
    if [ "$OFF" = "0" ]; then
      EXPR="@$SYM:$W"
    else
      EXPR="@$SYM+$OFF:$W"
    fi
  else
    EXPR="@$SYM:$W"
  fi
  echo "=================================================="
  echo " 读内核变量"
  echo "   符号: $SYM$([ "$ACT" = "struct" ] && echo " + $OFF")"
  echo "   宽度: $W"
  echo "   触发: $TRIG"
  echo "=================================================="
  if ! grep -qE "(^|[[:space:]])$SYM([[:space:]]|$)" /proc/kallsyms 2>/dev/null; then
    echo "警告: 符号 $SYM 不在 kallsyms 中（可能内联/未导出/拼写有误）"
    echo "相近符号："
    grep -iE "$SYM" /proc/kallsyms 2>/dev/null | head -n 5 | awk '{print "     " $3}'
    exit 1
  fi
  echo "[符号确认] $(grep -E "(^| )$SYM( |$)" /proc/kallsyms | head -n 1 | awk '{print $2" "$3}')"
  cleanup
  # v1.3 防呆：重启后 tracing_on 默认 0，探针挂上也不进 buffer（20260928 实测坑）
  echo 1 > $TP/tracing_on 2>/dev/null
  printf 'p:%s %s v=%s\n' "$PROBE" "$TRIG" "$EXPR" > $TP/kprobe_events 2>/tmp/kvar_err
  if ! grep -q "lemonkvar" $TP/kprobe_events 2>/dev/null; then
    echo "X 挂探针失败:"
    cat /tmp/kvar_err 2>/dev/null
    echo "可能原因：fetch 表达式不支持或触发函数不存在"
    exit 1
  fi
  echo "[1] 探针已挂: $(grep lemonkvar $TP/kprobe_events | tail -n 1)"
  if ! wait_enable; then
    echo "X 探针启用失败（sysfs 目录未出现）"
    exit 1
  fi
  echo "[2] 探针已启用，等待触发（1 秒）"
  echo > $TP/trace
  sleep 1
  line=$(grep "$PROBE:" $TP/trace 2>/dev/null | tail -n 1)
  if [ -n "$line" ]; then
    val=$(echo "$line" | grep -oE 'v=[^ ]*' | cut -d= -f2)
    echo "[3] 结果"
    echo "    值: $val"
    case "$val" in
      [0-9]*) printf '    十六进制: 0x%x\n' "$val" 2>/dev/null ;;
    esac
    echo "    （样本行: $(echo "$line" | sed 's/^ *//' | head -c 120)）"
  else
    echo "[3] X 未捕获到（触发点可能没跑）"
    exit 1
  fi
  cleanup
  echo "[4] 探针已清理"
  echo "=================================================="
  ;;
sym)
  KW="$SYM"; L="$3"
  [ -z "$L" ] && L=30
  [ -z "$KW" ] && { echo "!! 用法: kvar sym <关键字> [行数]"; exit 1; }
  echo "=================================================="
  echo " 符号表搜索: $KW  (最多 $L 行)"
  echo "=================================================="
  total=$(grep -icF "$KW" /proc/kallsyms 2>/dev/null)
  echo "  命中总数: $total  (kallsyms 共 $(wc -l < /proc/kallsyms) 个符号)"
  grep -iF "$KW" /proc/kallsyms 2>/dev/null | head -n "$L" | awk '{printf "  %-4s %s\n", $2, $3}'
  echo "=================================================="
  ;;
list)
  echo "=================================================="
  echo " 常用触发点（探针挂载目标）"
  echo "=================================================="
  for t in schedule do_sys_open vfs_read vfs_write tcp_sendmsg tcp_recvmsg __arm64_sys_read __arm64_sys_write; do
    if grep -qE "(^|[[:space:]])$t([[:space:]]|$)" /proc/kallsyms 2>/dev/null; then
      echo "  OK $t"
    else
      echo "  -- $t (不存在)"
    fi
  done
  echo "  提示：schedule 最稳（一直在跑，必中）"
  echo "=================================================="
  ;;
*)
  echo "lemonlib · kvar v1.2 —— 读内核变量/结构体（kprobe @符号 fetch）"
  echo "用法:"
  echo "  kvar read   <符号> [宽度] [触发点]     读内核变量"
  echo "  kvar struct <符号> [宽度] [偏移]        读符号+偏移(宽度在前)"
  echo "  kvar sym    <关键字> [行数]             搜符号表"
  echo "  kvar list                               列可用触发点"
  echo "宽度: u8/u16/u32/u64/s8/s16/s32/s64/x8/x16/x32/x64/string"
  echo "示例: kvar read jiffies u64 | kvar struct jiffies_64 8 u64 | kvar sym lemon_guard"
  ;;
esac
