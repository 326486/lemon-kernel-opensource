#!/system/bin/sh
# slimproxy 看门狗 v4.1 · 小柠檬 261104
# v4 升级（261104 电池事故复盘）：
#   1) 退役 dnsmasq 常驻：实测零查询也 98% 单核空转（voluntary_ctx=0 纯用户态死循环），zeronews 自带 DNS 缓存不依赖 53
#   2) zeronews 重启节流：300 秒内最多拉起 1 次（261103 夜 78 次重启风暴教训）
#   3) 启动去重 v4.1：读 /proc/P/cmdline 精确比对 argv[1]==脚本本体，绝不误杀调用方（v4.0 的 pgrep -f 文本匹配误杀启动链已修）
# 防空转(#249)：循环体阻塞 sleep 3；curl 全带超时；日志限长

PORT=8791
HEX="2257"
HEX2="2258"
S=/data/lemonbrain/slimproxy
LOG=/data/lemonbrain/logs/watchdog.log
PIDF=/data/lemonbrain/slimproxy/.watchdog.pid
ZN=/data/local/tmp/zn_tmp/zeronews/zeronews
ZNWD=/data/local/tmp/zeronews_home
ZNTS=/data/lemonbrain/slimproxy/.zn_restart_ts
SSL_CERT_FILE=/data/data/com.termux/files/usr/etc/tls/cert.pem
MAXLOG=1048576
ZN_MIN_INTERVAL=300

# 启动去重 v4.1：只杀 argv[1] 精确等于本脚本路径的真旧实例
for P in $(pgrep -f watchdog 2>/dev/null); do
  [ "$P" = "$$" ] && continue
  A1=$(tr '\0' '\n' < /proc/$P/cmdline 2>/dev/null | sed -n 2p)
  [ "$A1" = "$0" ] && kill "$P" 2>/dev/null
done
echo $$ > "$PIDF"

log() {
  if [ -f "$LOG" ] && [ "$(stat -c %s "$LOG" 2>/dev/null || echo 0)" -gt "$MAXLOG" ]; then
    tail -n 300 "$LOG" > "$LOG.tmp" 2>/dev/null && mv -f "$LOG.tmp" "$LOG"
  fi
  echo "[$(date '+%m-%d %H:%M:%S')] $*" >> "$LOG"
}

port_up() {
  awk -v h=":$HEX" '$2 ~ h"$" && $4 == "0A" {f=1} END {exit !f}' /proc/net/tcp 2>/dev/null
}

port2_up() {
  awk -v h2=":$HEX2" '$2 ~ h2"$" && $4 == "0A" {f=1} END {exit !f}' /proc/net/tcp 2>/dev/null
}

log "watchdog v4.1 启动 pid=$$ 守护(8791+8792+zeronews节流300s) [dnsmasq已退役]"

CNT=0
while true; do
  sleep 3
  if ! port_up; then
    log "8791 未监听，拉起 slimproxy"
    sh $S/start.sh >/dev/null 2>&1
    continue
  fi
  CNT=$((CNT+1))
  if [ $((CNT % 10)) -eq 0 ]; then
    if [ -s $S/.token ] && ! port2_up; then
      log "8792 公网口异常(token在但未监听)，重启 slimproxy"
      nohup sh -c "sh $S/stop.sh; sleep 1; sh $S/start.sh" >/dev/null 2>&1 &
      continue
    fi
    HC=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 http://127.0.0.1:37271/healthz 2>/dev/null)
    if [ "$HC" != "200" ]; then
      NOW=$(date +%s)
      LAST=$(cat "$ZNTS" 2>/dev/null || echo 0)
      AGE=$((NOW - LAST))
      if [ "$AGE" -ge "$ZN_MIN_INTERVAL" ]; then
        log "zeronews 不健康(HTTP=$HC)，重启(节流${ZN_MIN_INTERVAL}s)"
        echo "$NOW" > "$ZNTS"
        export SSL_CERT_FILE
        cd /data/local/tmp/zn_tmp/zeronews 2>/dev/null && \
          nohup $ZN --workdir $ZNWD start > /data/local/tmp/zn_start.log 2>&1 &
      fi
    fi
  fi
done
