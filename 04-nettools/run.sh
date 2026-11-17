#!/system/bin/sh
# lemon 去重包装器 v1 · 小柠檬1号分身 20260919
# 用法: run.sh <工具名> <原始命令...>
# 开关: 存在 $D/off 则全局禁用去重
D=/data/adb/lemon_kernel/lemon/dedup
NAME="$1"; shift
CMD="$*"
[ -f "$D/off" ] && exec sh -c "$CMD"
sh "$D/guard.sh" "$NAME" "$CMD" || exit 1
exec sh -c "$CMD"
