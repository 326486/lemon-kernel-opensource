#!/system/bin/sh
# clip_get.sh [limit] - 读取搜狗剪贴板历史(绕过SELinux)
M=/data/adb/lemon_kernel/lemon
LIMIT="${1:-20}"
PID=""
for p in /proc/[0-9]*; do
  cl=$(tr '\0' ' ' < "$p/cmdline" 2>/dev/null)
  case "$cl" in
    com.sohu.inputmethod.sogou*) PID=$(basename $p); break ;;
  esac
done
if [ -z "$PID" ]; then echo "ERR: 搜狗输入法未运行"; exit 1; fi
SRC="/proc/$PID/root/data/data/com.sohu.inputmethod.sogou/databases/clipboard_db"
TMP=/data/local/tmp/lemon_cdb.db
cp "$SRC" "$TMP" 2>/dev/null || { echo "ERR: 复制剪贴板库失败"; exit 2; }
unset LD_LIBRARY_PATH
CLASSPATH=$M/clip/clip.dex /system/bin/app_process64 /system/bin clip.ClipAll get "$TMP" "$LIMIT" 2>&1
