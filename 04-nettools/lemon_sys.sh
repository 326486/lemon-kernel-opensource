#!/system/bin/sh
# ============================================================
# lemon_sys.sh v1.0 · 系统增强（快照 / 状态监测 / 温度采样 / 综合报告）
# 20261001 · 小柠檬本体 · 授权：小良
# 用法: lemon_sys.sh {snapshot|watch|thermal|report} [...]
# ============================================================
SF=/data/adb/lemon_kernel/lemonlib/.sysfun
mkdir -p "$SF" 2>/dev/null
SNAP="$SF/snapshot.last"
STATE="$SF/last_state.txt"
HIST="$SF/snapshot.hist"
TLOG="$SF/thermal.csv"
TPID="$SF/thermal.pid"
BS=/sys/class/power_supply/battery

clean(){ case "$1" in \$*) printf '' ;; *) printf '%s' "$1" ;; esac; }
. /data/adb/lemon_kernel/lemonlib/thermal_lib.sh 2>/dev/null

cpu_freqs(){
  c=0
  while [ "$c" -le 7 ]; do
    f=/sys/devices/system/cpu/cpu$c/cpufreq/scaling_cur_freq
    [ -r "$f" ] && printf 'cpu%s=%s ' "$c" "$(( $(cat "$f") / 1000 ))"
    c=$((c + 1))
  done
  printf '\n'
}

mem_line(){
  awk '/^MemAvailable:|^MemTotal:|^SwapFree:|^SwapTotal:/{k=$1; sub(/:$/,"",k); printf "%s=%dMB ", k, $2/1024}' /proc/meminfo 2>/dev/null
  printf '\n'
}

stor_line(){
  df -h /data 2>/dev/null | grep -v -E 'Filesystem|^Filesystem' | head -n 1
}

do_snapshot(){
  tag=$(clean "$1")
  ts=$(date '+%F %T')
  up=$(cut -d' ' -f1 /proc/uptime 2>/dev/null | cut -d. -f1)
  ld=$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null)
  mt=$(max_temp)
  mav=$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo 2>/dev/null)
  sf=$(awk '/SwapFree/{print int($2/1024)}' /proc/meminfo 2>/dev/null)
  st=$(awk '/SwapTotal/{print int($2/1024)}' /proc/meminfo 2>/dev/null)
  cap=$(cat $BS/capacity 2>/dev/null)
  bt=$(cat $BS/temp 2>/dev/null); [ -n "$bt" ] && bt=$((bt / 10))
  bst=$(cat $BS/status 2>/dev/null)
  du=$(df -h /data 2>/dev/null | grep -v Filesystem | awk 'NR==1{print $5}')
  dw=$(df -h /data 2>/dev/null | grep -v Filesystem | awk 'NR==1{print $4}')
  gw=$(ip route get 223.5.5.5 2>/dev/null | sed -n 's/.*via \([0-9.]*\).*/\1/p' | head -n 1)
  [ -z "$gw" ] && gw=$(cat /proc/net/route 2>/dev/null | awk '$2=="00000000"{print $3; exit}' | sed 's/\(..\)\(..\)\(..\)\(..\)/0x\4 0x\3 0x\2 0x\1/' )
  {
    printf '===== 系统快照 %s =====\n' "$ts"
    printf '[标签] %s\n' "${tag:-（无）}"
    printf '[运行时长] %ss   [负载 1/5/15] %s\n' "$up" "$ld"
    printf '\n-- 温度 TOP8 (度) --\n'
    temp_top 8
    printf '\n-- CPU 频率 (MHz) --\n'
    cpu_freqs
    printf '\n-- 内存 --\n'
    mem_line
    printf '[存储 /data] 已用 %s  可用 %s\n' "$du" "$dw"
    printf '\n-- 电池 --\n'
    printf '电量=%s%%  温度=%sC  状态=%s\n' "${cap:-?}" "${bt:-?}" "${bst:-?}"
    printf '\n-- 网络 --\n'
    printf '默认网关=%s\n' "${gw:-无}"
    ip -o addr show 2>/dev/null | awk '{print $2, $4}' | grep -E 'wlan|rmnet|eth' | head -n 6
  } | tee "$SNAP"
  printf '%s\n' "----" >> "$HIST"
  cat "$SNAP" >> "$HIST"
  L=$(wc -l < "$HIST" 2>/dev/null); L=${L:-0}
  if [ "$L" -gt 600 ]; then tail -n 300 "$HIST" > "$HIST.t" 2>/dev/null && mv "$HIST.t" "$HIST"; fi
  {
    printf 'uptime=%s\n' "$up"
    printf 'load1=%s\n' "$(cut -d' ' -f1 /proc/loadavg 2>/dev/null)"
    printf 'memavail=%s\n' "$mav"
    printf 'swapfree=%s\n' "$sf"
    printf 'swaptotal=%s\n' "$st"
    printf 'maxtemp=%s\n' "$mt"
    printf 'batt=%s\n' "$cap"
    printf 'gw=%s\n' "$gw"
    printf 'storused=%s\n' "$du"
  } > "$STATE"
  printf '\n[OK] 快照已存 → %s\n' "$SNAP"
}

do_watch(){
  [ -r "$STATE" ] || { printf '[x] 还没有基线快照，先跑 snapshot\n'; return 1; }
  old_t=$(grep '^maxtemp=' "$STATE" | cut -d= -f2)
  old_m=$(grep '^memavail=' "$STATE" | cut -d= -f2)
  old_s=$(grep '^swapfree=' "$STATE" | cut -d= -f2)
  old_b=$(grep '^batt=' "$STATE" | cut -d= -f2)
  old_u=$(grep '^uptime=' "$STATE" | cut -d= -f2)
  new_t=$(max_temp)
  new_m=$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo 2>/dev/null)
  new_s=$(awk '/SwapFree/{print int($2/1024)}' /proc/meminfo 2>/dev/null)
  new_b=$(cat $BS/capacity 2>/dev/null)
  new_u=$(cut -d' ' -f1 /proc/uptime 2>/dev/null | cut -d. -f1)
  printf '===== 系统变化监测 %s =====\n' "$(date '+%T')"
  printf '%-12s %10s %10s %10s\n' 指标 基线 当前 变化
  printf '%-12s %10s %10s %+10s\n' 最高温度 "${old_t:-?}" "${new_t:-?}" "$(( ${new_t:-0} - ${old_t:-0} ))"
  printf '%-12s %10s %10s %+10s\n' 可用内存MB "${old_m:-?}" "${new_m:-?}" "$(( ${new_m:-0} - ${old_m:-0} ))"
  printf '%-12s %10s %10s %+10s\n' Swap空闲MB "${old_s:-?}" "${new_s:-?}" "$(( ${new_s:-0} - ${old_s:-0} ))"
  printf '%-12s %10s %10s %+10s\n' 电量 "${old_b:-?}" "${new_b:-?}" "$(( ${new_b:-0} - ${old_b:-0} ))"
  printf '%-12s %10s %10s %+10s\n' 运行秒 "${old_u:-?}" "${new_u:-?}" "$(( ${new_u:-0} - ${old_u:-0} ))"
  if [ "${new_u:-0}" -lt "${old_u:-0}" ]; then printf '\n[!] uptime 变小 = 中间重启过\n'; fi
  if [ "${new_t:-0}" -ge 65 ]; then printf '\n[!] 最高温 >=45C，注意发热\n'; fi
}

do_thermal(){
  act=$(clean "$1"); a2=$(clean "$2"); a3=$(clean "$3")
  case "$act" in
    start)
      mins="$a2"; iv="$a3"
      [ -z "$mins" ] && mins=10
      [ -z "$iv" ] && iv=3
      case "$mins" in ''|*[!0-9]*) printf '[x] 分钟数非法\n'; return 1 ;; esac
      case "$iv" in ''|*[!0-9]*) printf '[x] 间隔非法\n'; return 1 ;; esac
      [ "$iv" -lt 1 ] && iv=1
      [ "$mins" -gt 720 ] && mins=720
      if [ -r "$TPID" ]; then
        op=$(cat "$TPID" 2>/dev/null)
        if [ -n "$op" ] && kill -0 "$op" 2>/dev/null; then printf '[x] 已在采样 pid=%s\n' "$op"; return 1; fi
      fi
      nohup env LEMON_IV="$iv" LEMON_MAX=$(( mins * 60 / iv )) LEMON_CSV="$TLOG" LEMON_PID="$TPID" \
        timeout $(( mins * 60 + 120 )) sh "$SF/thermal_run.sh" >/dev/null 2>&1 &
      printf '%s\n' "$!" > "$TPID"
      printf '[OK] 温度采样已启动 pid=%s  时长=%s分钟  间隔=%ss  共%s点\n' "$!" "$mins" "$iv" "$(( mins * 60 / iv ))"
      ;;
    stop)
      if [ -r "$TPID" ]; then
        op=$(cat "$TPID" 2>/dev/null)
        [ -n "$op" ] && kill "$op" 2>/dev/null && printf '[OK] 已停 pid=%s\n' "$op"
        rm -f "$TPID"
      else printf '[i] 不在采样\n'; fi
      ;;
    show)
      n="$a2"; [ -z "$n" ] && n=20
      if [ -r "$TLOG" ]; then printf '== 最近 %s 条 ==\n' "$n"; tail -n "$n" "$TLOG"; else printf '[i] 无记录\n'; fi
      ;;
    stat)
      [ -r "$TLOG" ] || { printf '[i] 无记录\n'; return 0; }
      awk -F, '$1!="time" && NF>=6 { if(n==0)mx=$2+0; if($2+0>mx)mx=$2+0; if($3+0>sb)sb=$3+0; if($4+0>fr)fr=$4+0; if($5+0>bt)bt=$5+0; n++; s+=$2 }
        END{ if(n==0){print "无有效样本"; exit} printf "样本=%d\n最高SoC=%dC\n机身背板最高=%dC\n机身正面最高=%dC\n电池最高=%dC\n平均SoC=%.1fC\n", n, mx, sb, fr, bt, s/n }' "$TLOG"
      if [ -r "$TPID" ]; then op=$(cat "$TPID" 2>/dev/null); kill -0 "$op" 2>/dev/null && printf '状态: 采样中 pid=%s\n' "$op" || printf '状态: 已停止\n'; else printf '状态: 未启动\n'; fi
      ;;
    *) printf '用法: thermal {start [分钟] [秒]|stop|show [n]|stat}\n' ;;
  esac
}

do_report(){
  printf '########## 柠檬综合健康报告 %s ##########\n' "$(date '+%F %T')"
  printf '\n【一、内核栈】\n'
  sh /data/adb/lemon_kernel/lemonlib/sys_health.sh 2>/dev/null | sed -n '1,30p'
  printf '\n【二、系统负载】\n'
  printf '负载: %s\n' "$(cat /proc/loadavg 2>/dev/null)"
  printf '内存: '; mem_line
  printf '温度 TOP5:\n'; temp_top 5
  printf '存储: '; stor_line
  printf '\n【三、安全速览】\n'
  printf 'root: %s\n' "$(id 2>/dev/null | cut -d' ' -f1)"
  printf 'SELinux: %s\n' "$(getenforce 2>/dev/null)"
  printf 'ADB: %s  开发者模式: %s\n' "$(settings get global adb_enabled 2>/dev/null)" "$(settings get global development_settings_enabled 2>/dev/null)"
  printf 'service.d 活跃脚本: %s\n' "$(ls /data/adb/service.d/ 2>/dev/null | wc -l)"
  printf '已加载第三方模块(非GKI): %s\n' "$(cat /proc/modules 2>/dev/null | grep -v -E '^[a-z_]+ [0-9]+ [0-9]+ - (Live|Loading)' | wc -l)"
  printf '\n########## 报告结束 ##########\n'
}

case "$1" in
  snapshot) do_snapshot "$2" ;;
  watch)    do_watch ;;
  thermal)  do_thermal "$2" "$3" "$4" ;;
  report)   do_report ;;
  *) printf '用法: lemon_sys.sh {snapshot [标签]|watch|thermal {start|stop|show|stat}|report}\n' ;;
esac
