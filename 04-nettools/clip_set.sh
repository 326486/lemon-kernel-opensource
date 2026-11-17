#!/system/bin/sh
# clip_set.sh <text> - 写剪贴板
M=/data/adb/lemon_kernel/lemon
B64=$(printf '%s' "$1" | base64 -w0)
unset LD_LIBRARY_PATH
CLASSPATH=$M/clip/clip.dex /system/bin/app_process64 /system/bin clip.ClipAll set "$B64" 2>&1
