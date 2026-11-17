#!/system/bin/sh
# virus_maintenance.sh — 每日防病毒维护（cron 包装，#249 有界无循环）
# 更新病毒库 ＋ 已装应用扫描（只读比对，不自动删除）；脚本防御扫描按需另跑
LK=/data/adb/lemon_kernel
LOG=/data/local/tmp/virus_maintenance.log
{
  echo "=== virus maintenance $(date '+%y%m%d-%H%M%S') ==="
  sh "$LK/lemonlib/virusdb.sh" update
  sh "$LK/lemonlib/lemon_virus.sh" scan
  echo "=== done $(date '+%y%m%d-%H%M%S') ==="
} >> "$LOG" 2>&1
