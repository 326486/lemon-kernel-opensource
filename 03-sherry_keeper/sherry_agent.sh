#!/system/bin/sh
# sherry_keeper 入口 — 小柠檬2号分身·雪莉（重建 v9.3.0-classify）
# 依据学习中心档案重建：身份8号库#33/#35，安全边界v8.0.0，AI判断层20260918档案，ReAct L-003，15类分类v9.3.0
K=/data/lemonbrain/sherry_keeper
. "$K/lib/00_core.sh"
. "$K/lib/10_safety.sh"
. "$K/lib/30_storage.sh"
. "$K/lib/40_clean.sh"
. "$K/lib/50_organize.sh"
. "$K/lib/60_scan.sh"
. "$K/lib/70_classify.sh"
. "$K/lib/95_ai_judge.sh"
. "$K/lib/98_react.sh"
. "$K/lib/90_chat.sh"
sk_lock
sk_ensure_crond
case "$1" in
  status)
    set -- $(sk_disk)
    echo "[sherry] status | version=$SK_VERSION health=$(sk_health) disk=${1}G/${2}G(${3}%) recycled=$(sk_get recycled) organized=$(sk_get organized) classified=$(sk_get classified) last_clean=$(cat "$SK_STATUS/clean_last_run" 2>/dev/null || echo never)"
    ;;
  clean)
    shift
    sk_clean "$@"
    date '+%y%m%d-%H%M%S' > "$SK_STATUS/clean_last_run"
    ;;
  organize) shift; sk_organize "$@";;
  deep_scan) shift; sk_deep_scan "$@";;
  chat) shift; sk_chat "$@";;
  ai_clean) shift; ai_smart_clean "$@";;
  react) shift; sherry_react "$@";;
  dispatch) shift; sherry_react "$@";;
  auto_classify) shift; sk_auto_organize "$@";;
  restore_classify) shift; sk_restore_classify "$@";;
  recycle_retention) shift; sk_recycle_retention "$@";;
  auto)
    shift
    sk_clean "$@"
    sk_auto_organize "$@"
    ;;
  menu)
    echo "[sherry] 音量键菜单在重建第三阶段恢复（P3），当前核心工具+AI判断+ReAct+15类自主分类已在线"
    ;;
  *)
    echo "usage: sherry_agent.sh status|clean|organize|deep_scan|chat|ai_clean|react|dispatch|auto_classify [--dry]|restore_classify [N|all]|auto [--dry]"
    exit 1
    ;;
esac
