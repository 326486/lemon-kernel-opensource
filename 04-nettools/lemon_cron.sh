#!/system/bin/sh
# ============================================================
# lemon_cron.sh v1.0 · 计划任务管理（add/list/del/run/start/stop/status）
# 20261001 · 小柠檬本体
# ============================================================
SF=/data/adb/lemon_kernel/lemonlib/.sysfun
mkdir -p "$SF" 2>/dev/null
CRON=$SF/cron.conf; PIDF=$SF/cron.pid; LOG=$SF/cron.log
DAEMON=/data/adb/lemon_kernel/lemonlib/cron_daemon.sh
clean(){ case "$1" in \$*) printf '' ;; *) printf '%s' "$1" ;; esac; }

do_add(){
  nm=$(clean "$1"); iv=$(clean "$2"); cm=$(clean "$3")
  [ -z "$nm" ] && { printf '[x] 用法: add <名字> <间隔分钟> <命令>\n'; return 1; }
  case "$nm" in *'|'*) printf '[x] 名字不能含 |\n'; return 1 ;; esac
  case "$iv" in ''|*[!0-9]*) iv=60 ;; esac
  [ "$iv" -lt 1 ] && iv=1
  [ -z "$cm" ] && { printf '[x] 需要命令\n'; return 1; }
  case "$cm" in *'|'*) printf '[x] 命令不能含 |\n'; return 1 ;; esac
  touch "$CRON"
  if grep -q "^$nm|" "$CRON" 2>/dev/null; then printf '[x] 同名任务已存在: %s\n' "$nm"; return 1; fi
  printf '%s|%s|0|%s\n' "$nm" "$iv" "$cm" >> "$CRON"
  printf '[OK] 已添加: %s（每 %s 分钟）\n' "$nm" "$iv"
}
do_list(){
  [ -s "$CRON" ] || { printf '（无计划任务）\n'; return 0; }
  printf '===== ⏰ 计划任务 =====\n'
  now=$(date +%s)
  while IFS='|' read -r nm iv last cm; do
    [ -z "$nm" ] && continue
    case "$iv" in ''|*[!0-9]*) iv=60 ;; esac
    case "$last" in ''|*[!0-9]*) last=0 ;; esac
    left=$(( last + iv * 60 - now )); [ "$left" -lt 0 ] && left=0
    printf '  %-16s 每%4s分  下次%5ss  %s\n' "$nm" "$iv" "$left" "$cm"
  done < "$CRON"
}
do_del(){
  nm=$(clean "$1"); [ -z "$nm" ] && { printf '[x] 用法: del <名字>\n'; return 1; }
  [ -s "$CRON" ] || { printf '[i] 无任务\n'; return 0; }
  grep -v "^$nm|" "$CRON" > "$CRON.t" 2>/dev/null
  mv "$CRON.t" "$CRON" 2>/dev/null
  printf '[OK] 已删除(若存在): %s\n' "$nm"
}
do_run(){
  nm=$(clean "$1"); [ -z "$nm" ] && { printf '[x] 用法: run <名字>\n'; return 1; }
  cm=$(grep "^$nm|" "$CRON" 2>/dev/null | head -n 1 | cut -d'|' -f4-)
  [ -z "$cm" ] && { printf '[x] 找不到任务: %s\n' "$nm"; return 1; }
  printf '▶ 立即执行 %s: %s\n' "$nm" "$cm"
  timeout 120 sh -c "$cm" 2>&1 | head -n 40
  printf '■ 完成 rc=%s\n' "$?"
}
do_start(){
  if [ -r "$PIDF" ]; then op=$(cat "$PIDF" 2>/dev/null); kill -0 "$op" 2>/dev/null && { printf '[i] 调度器已运行 pid=%s\n' "$op"; return 0; }; fi
  [ -s "$CRON" ] || { printf '[x] 无任务，先 add\n'; return 1; }
  nohup sh "$DAEMON" >/dev/null 2>&1 &
  printf '%s\n' "$!" > "$PIDF"
  printf '[OK] 调度器启动 pid=%s（30s 轮询，24h 自限）\n' "$!"
}
do_stop(){
  if [ -r "$PIDF" ]; then op=$(cat "$PIDF" 2>/dev/null); kill "$op" 2>/dev/null && printf '[OK] 已停 pid=%s\n' "$op"; rm -f "$PIDF"; else printf '[i] 未运行\n'; fi
}
do_status(){
  printf '===== ⏰ 调度器状态 =====\n'
  if [ -r "$PIDF" ]; then op=$(cat "$PIDF" 2>/dev/null); kill -0 "$op" 2>/dev/null && printf '运行中 pid=%s\n' "$op" || printf '未运行(陈旧 pid)\n'; else printf '未运行\n'; fi
  printf '任务数: %s\n' "$(grep -c '|' "$CRON" 2>/dev/null || echo 0)"
  printf '\n-- 最近日志 --\n'
  [ -r "$LOG" ] && tail -n 12 "$LOG" || printf '（无）\n'
}
case "$1" in
  add)    do_add "$2" "$3" "$4" ;;
  list)   do_list ;;
  del|rm) do_del "$2" ;;
  run)    do_run "$2" ;;
  start)  do_start ;;
  stop)   do_stop ;;
  status) do_status ;;
  *) printf '用法: lemon_cron.sh {add <名> <分钟> <命令>|list|del <名>|run <名>|start|stop|status}\n' ;;
esac
