#!/system/bin/sh
# ============================================================
# lemon_boot.sh v1.0 · 自启与服务管理
# 20261001 · 小柠檬本体
# 用法: lemon_boot.sh {autostart|bootaudit|svcpanel} [arg]
# ============================================================
clean(){ case "$1" in \$*) printf '' ;; *) printf '%s' "$1" ;; esac; }
DIRS="/data/adb/service.d /data/adb/post-fs-data.d /data/adb/init.d /system/etc/init.d"

do_autostart(){
  printf '===== 自启项全清单 %s =====\n' "$(date '+%F %T')"
  for d in $DIRS; do
    [ -d "$d" ] || continue
    n=$(ls "$d" 2>/dev/null | wc -l)
    printf '\n## %s  (%s 项)\n' "$d" "$n"
    for f in "$d"/*; do
      [ -e "$f" ] || continue
      b=$(basename "$f")
      x="-"; [ -x "$f" ] && x="x"
      sz=$(wc -c < "$f" 2>/dev/null)
      printf '  [%s] %-34s %6s B\n' "$x" "$b" "$sz"
    done
  done
  printf '\n## Magisk 模块 (勾选脚本)\n'
  for m in /data/adb/modules/*/; do
    [ -d "$m" ] || continue
    nm=$(basename "$m")
    dis="-"; [ -f "$m/disable" ] && dis="DISABLED"
    printf '  %-28s %s\n' "$nm" "$dis"
    for s in service.sh post-fs-data.sh boot-completed.sh; do
      [ -f "$m$s" ] || continue
      x="-"; [ -x "$m$s" ] && x="x"
      printf '      [%s] %s\n' "$x" "$s"
    done
  done
}

do_bootaudit(){
  printf '===== 自启项体检 %s =====\n' "$(date '+%F %T')"
  bad=0
  printf '\n-- 1) 缺少执行位 --\n'
  for d in /data/adb/service.d /data/adb/post-fs-data.d; do
    for f in "$d"/*; do
      [ -f "$f" ] || continue
      if [ ! -x "$f" ]; then printf '  [!] %s\n' "$f"; bad=$((bad+1)); fi
    done
  done
  [ "$bad" -eq 0 ] && printf '  无\n'
  printf '\n-- 2) 可疑特征 (网络/解码/eval) --\n'
  n2=0
  for f in /data/adb/service.d/* /data/adb/post-fs-data.d/*; do
    [ -f "$f" ] || continue
    h=$(grep -n -E 'curl |wget |nc |ncat |base64 -d|eval |/dev/tcp|busybox nc|setsid.*http' "$f" 2>/dev/null | grep -v -E '^[0-9]+:[[:space:]]*#' | grep -v -E '127\.0\.0\.1|localhost' | head -n 2)
    if [ -n "$h" ]; then printf '  [?] %s\n' "$f"; printf '%s\n' "$h" | sed 's/^/        /'; n2=$((n2+1)); fi
  done
  [ "$n2" -eq 0 ] && printf '  无\n'
  printf '\n-- 3) 重名冲突 --\n'
  ls /data/adb/service.d /data/adb/post-fs-data.d 2>/dev/null | grep -v -E '^/|:$' | sort | uniq -d | sed 's/^/  [!] /' | head -n 20
  printf '\n-- 4) 指向已失效的链接 --\n'
  for d in $DIRS; do
    for f in "$d"/*; do
      [ -L "$f" ] || continue
      [ -e "$f" ] || printf '  [!] 悬空链接 %s\n' "$f"
    done
  done
  printf '\n-- 5) 停用标记 --\n'
  ls /data/adb/modules/*/disable /data/adb/service.d/*.paused /data/adb/service.d/*.disabled 2>/dev/null | sed 's/^/  [i] /' | head -n 20
  printf '\n结论: 缺执行位 %s 个, 可疑 %s 个\n' "$bad" "$n2"
}

do_svcpanel(){
  act=$(clean "$1")
  case "$act" in
    restart-core)
      printf '[..] 2 秒后重启 LemonCore(8788)...\n'
      nohup sh -c 'sleep 2; sh /data/adb/lemon_core/lemoncore.sh restart' >/dev/null 2>&1 &
      printf '[OK] 已下发重启指令\n'; return 0 ;;
  esac
  printf '===== 自研服务面板 %s =====\n' "$(date '+%F %T')"
  printf '\n[主链路]\n'
  hz=$(curl -s -m 5 http://127.0.0.1:8788/healthz 2>/dev/null)
  if [ -n "$hz" ]; then printf '  8788 LemonCore : 在线 %s\n' "$hz"; else printf '  8788 LemonCore : [!] 不可达\n'; fi
  h9=$(curl -s -m 5 http://127.0.0.1:8790/healthz 2>/dev/null)
  if [ -n "$h9" ]; then printf '  8790 Java卫星  : 在线\n'; else printf '  8790 Java卫星  : [!] 不可达\n'; fi
  printf '\n[内核态]\n'
  if [ -x /data/adb/lemonbpf/lemonbpf ]; then
    n=$(/data/adb/lemonbpf/lemonbpf status 2>/dev/null | grep -c -E 'prog|map|link')
    printf '  eBPF(lemonbpf) : 对象 %s\n' "${n:-?}"
  else printf '  eBPF           : 未安装\n'; fi
  if [ -x /data/adb/lemon_kernel/khook/khook.sh ]; then
    printf '  khook          : %s\n' "$(sh /data/adb/lemon_kernel/khook/khook.sh health 2>/dev/null | tr '\n' ' ' | cut -c1-80)"
  else printf '  khook          : 未安装\n'; fi
  printf '\n[模块]\n'
  lsmod 2>/dev/null | grep -E 'lemon|guard|protect' | awk '{printf "  %s (%s)\n",$1,$3}'
  [ -x /data/adb/lemon_kernel/lemonprotect/lemon_protect_ctl.sh ] && sh /data/adb/lemon_kernel/lemonprotect/lemon_protect_ctl.sh status 2>/dev/null | sed -n '2,4p' | sed 's/^/  /'
  printf '\n[守护进程]\n'
  ps -A -o PID,PPID,NAME 2>/dev/null | grep -E 'lemoncore|lemon-kernel|guard|super' | grep -v grep | sed 's/^/  /'
  printf '\n[开机脚本] service.d 活跃 %s 个\n' "$(ls /data/adb/service.d/ 2>/dev/null | wc -l)"
  printf '\n[策略]\n'
  [ -x /data/adb/lemon_kernel/lemonlib/policy.sh ] && sh /data/adb/lemon_kernel/lemonlib/policy.sh brief 2>/dev/null | sed 's/^/  /'
}

case "$1" in
  autostart) do_autostart ;;
  bootaudit) do_bootaudit ;;
  svcpanel)  do_svcpanel "$2" ;;
  *) printf '用法: lemon_boot.sh {autostart|bootaudit|svcpanel [restart-core]}\n' ;;
esac
