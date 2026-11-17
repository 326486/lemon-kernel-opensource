#!/system/bin/sh
M=/data/adb/lemon_kernel/lemon
unset LD_LIBRARY_PATH
CLASSPATH=$M/clip/clip.dex /system/bin/app_process64 /system/bin clip.ClipAll clear 2>&1
