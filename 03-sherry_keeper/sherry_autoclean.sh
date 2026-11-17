#!/system/bin/sh
# 雪莉自主清理管线 — cron 包装（#249合规：单次有界运行，无循环，纯shell不吃API）
K=/data/lemonbrain/sherry_keeper
ST='/storage/emulated/0/雪莉工作室'
mkdir -p "$ST/日志" 2>/dev/null
{
  echo "=== autoclean start $(date '+%y%m%d-%H%M%S') ==="
  sh "$K/sherry_agent.sh" clean
  sh "$K/sherry_agent.sh" auto_classify
  sh "$K/sherry_agent.sh" recycle_retention
  echo "=== autoclean end $(date '+%y%m%d-%H%M%S') ==="
} >> "$ST/日志/autoclean.log" 2>&1
