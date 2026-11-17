#!/system/bin/sh
# defense_watch.sh — 内核防御哨兵（261116 红蓝对抗·蓝队）
# 监测 guard/审计/核心/令牌闸日志新增安全事件 ＋ 端口存活；有界运行 720轮×10s=120分钟（#249）
KLOG=/data/lemonbrain/klogs
AL=/data/local/tmp/defense_alerts.log
OFFD=/data/local/tmp
MAXROUND=720
INTERVAL=10
GATELOG=/data/local/tmp/gate_8787.log
[ -f "$GATELOG" ] || GATELOG=$(ls -t /data/lemonbrain/logs/*gate* /data/lemonbrain/klogs/*gate* 2>/dev/null | head -1)
LOGS="$KLOG/audit.log $KLOG/guard.log $KLOG/kernel.log"
[ -n "$GATELOG" ] && LOGS="$LOGS $GATELOG"
for lg in $LOGS; do
  [ -f "$lg" ] && wc -c < "$lg" 2>/dev/null | tr -d ' ' > "$OFFD/.dwo_$(basename "$lg")"
done
echo "$(date '+%m%d %H:%M:%S') WATCH_START logs=$LOGS max=${MAXROUND}x${INTERVAL}s" >> "$AL"
i=0
while [ "$i" -lt "$MAXROUND" ]; do
  for lg in $LOGS; do
    [ -f "$lg" ] || continue
    of="$OFFD/.dwo_$(basename "$lg")"
    old=$(cat "$of" 2>/dev/null || echo 0)
    new=$(wc -c < "$lg" 2>/dev/null | tr -d ' ')
    [ -z "$new" ] && continue
    if [ "$new" -gt "$old" ]; then
      tail -c +$((old + 1)) "$lg" 2>/dev/null | grep -aE '策略拒绝|denied|blocked|拦截|401|403|[Uu]nauthorized|invalid|EPERM|EFAULT|reject|forbidden|越权|注入|RATELIMIT|RemoteDisconnected|Bad Request| 400 | 404 | 500 ' | while IFS= read -r line; do
        echo "$(date '+%m%d %H:%M:%S') [$(basename "$lg")] $line" >> "$AL"
      done
      echo "$new" > "$of"
    elif [ "$new" -lt "$old" ]; then
      echo "$new" > "$of"
    fi
  done
  if [ $((i % 6)) = 0 ]; then
    for p in 8788 8791 8792 8796; do
      HEX=$(printf "%X" "$p")
      awk -v h=":$HEX" '$2 ~ h"$" && $4 == "0A" {f=1} END {exit !f}' /proc/net/tcp /proc/net/tcp6 2>/dev/null || echo "$(date '+%m%d %H:%M:%S') [port] $p DOWN" >> "$AL"
    done
  fi
  sz=$(wc -c < "$AL" 2>/dev/null || echo 0)
  if [ "$sz" -gt 200000 ]; then
    tail -c 100000 "$AL" > "$AL.t" 2>/dev/null && cat "$AL.t" > "$AL" && rm -f "$AL.t"
  fi
  sleep "$INTERVAL"
  i=$((i + 1))
done
echo "$(date '+%m%d %H:%M:%S') WATCH_END reached_max_rounds" >> "$AL"
