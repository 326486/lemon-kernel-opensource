#!/system/bin/sh
# watchdog_v151.sh —— 小柠檬双活看门狗 v5.1（261111）
# 守护对象：主门面 8791/8792 + 备用维护通道 8795 + zeronews 隧道（节流300s）
# 双活：本脚本支持主备两个实例（参数 primary/secondary），互写心跳，30s 失联即接管对方
# 防空转(#249)：循环阻塞 sleep 3；curl 全带超时；日志限长
# 用法：nohup sh watchdog_v151.sh primary >/dev/null 2>&1 &
#       nohup sh watchdog_v151.sh secondary >/dev/null 2>&1 &

ROLE=${1:-primary}
S=${WD_HOME:-/data/lemonbrain/slimproxy}
LOG=${WD_LOG:-/data/lemonbrain/logs/watchdog.log}
HB_DIR=$S/.hb
PIDF=$S/.watchdog_$ROLE.pid
PEER_ROLE=secondary
[ "$ROLE" = "secondary" ] && PEER_ROLE=primary
PEER_HB=$HB_DIR/$PEER_ROLE
MY_HB=$HB_DIR/$ROLE
ZN=/data/local/tmp/zn_tmp/zeronews/zeronews
ZNWD=/data/local/tmp/zeronews_home
ZNTS=$S/.zn_restart_ts
SSL_CERT_FILE=/data/data/com.termux/files/usr/etc/tls/cert.pem
MAXLOG=1048576
ZN_MIN_INTERVAL=300
DRY=${WD_DRYRUN:-0}

mkdir -p "$HB_DIR"

# 启动去重：只杀 argv 精确匹配「本脚本+本角色」的旧实例
OLD=$(cat "$PIDF" 2>/dev/null)
if [ -n "$OLD" ] && [ "$OLD" != "$$" ] && kill -0 "$OLD" 2>/dev/null; then
  A=$(tr '\0' ' ' < /proc/$OLD/cmdline 2>/dev/null)
  case "$A" in *watchdog_v15*"sh $ROLE"*) kill "$OLD" 2>/dev/null; sleep 1;; esac
fi
echo $$ > "$PIDF"

log() {
  if [ -f "$LOG" ] && [ "$(stat -c %s "$LOG" 2>/dev/null || echo 0)" -gt "$MAXLOG" ]; then
    tail -n 300 "$LOG" > "$LOG.tmp" 2>/dev/null && mv -f "$LOG.tmp" "$LOG"
  fi
  echo "[$(date '+%m-%d %H:%M:%S')] [$ROLE] $*" >> "$LOG"
}

port_up() {
  HEX=$(printf "%X" "$1")
  awk -v h=":$HEX" '$2 ~ h"$" && $4 == "0A" {f=1} END {exit !f}' /proc/net/tcp 2>/dev/null
}

peer_alive() {   # 心跳 30 秒内 = 活
  [ -f "$PEER_HB" ] || return 1
  NOW=$(date +%s)
  LAST=$(cat "$PEER_HB" 2>/dev/null || echo 0)
  [ $((NOW - LAST)) -lt 30 ]
}

run() { [ "$DRY" = "1" ] && { echo "[DRY] $*"; return; }; eval "$@"; }

# v5.1 通知栏告警（cmd notification，免 Termux:API；同类 600s 节流防刷屏）
notify() {  # $1=事件key $2=内容
  NF="$S/.notify.$1"
  NOW=$(date +%s)
  LAST=$(cat "$NF" 2>/dev/null || echo 0)
  [ $((NOW - LAST)) -lt 600 ] && return 0
  echo "$NOW" > "$NF"
  [ "$DRY" = "1" ] && { echo "[DRY-NOTIFY] $1: $2"; return; }
  cmd notification post -S bigtext -t "小柠檬看门狗" "lemon_wd_$1" "$2" >/dev/null 2>&1
}

log "双活看门狗 v5.1 启动 pid=$$ role=$ROLE（主门面+备用通道+zeronews+8788上游）"
[ "$ROLE" = "primary" ] && echo "$$" > "$S/.watchdog_primary.pid"

CNT=0
while true; do
  sleep 3
  date +%s > "$MY_HB"

  # 互备：对端心跳失联 → 接管其职责（这里体现为：自己也全量巡检）
  TAKEOVER=0
  peer_alive || TAKEOVER=1

  # secondary 本职：盯着 primary 看门狗本体，死了就补位（必须先于巡检的 continue）
  if [ "$ROLE" = "secondary" ] && [ $TAKEOVER -eq 1 ]; then
    PPID_X=$(cat $S/.watchdog_primary.pid 2>/dev/null)
    if [ -z "$PPID_X" ] || ! kill -0 "$PPID_X" 2>/dev/null; then
      log "primary 进程失踪，补位拉起"
      run "nohup sh $S/watchdog_v151.sh primary >/dev/null 2>&1 &"
    fi
  fi

  if [ "$ROLE" = "primary" ] || [ $TAKEOVER -eq 1 ]; then
    # 主门面（v5.1：拉起后不 continue——8788 等后续检查本轮照做，避免饿死）
    JUST_STARTED=0
    if ! port_up 8791; then
      log "8791 未监听，拉起 slimproxy(最新版)"
      run "sh $S/start_current.sh >/dev/null 2>&1"
      notify "slim" "主门面 8791 掉线，看门狗已拉起"
      JUST_STARTED=1
    fi
    # 备用维护通道
    if ! port_up 8795; then
      log "8795 备用通道未监听，拉起 maint_server"
      run "sh $S/start_maint.sh >/dev/null 2>&1"
      notify "maint" "备用维护通道掉线，看门狗已拉起"
    fi
    # lemoncore 上游 8788：拉起归 lemoncore_super（已有双守护），看门狗只检测+告警
    if ! port_up 8788; then
      CNT8=$(cat "$S/.c8788" 2>/dev/null || echo 0); CNT8=$((CNT8+1)); echo "$CNT8" > "$S/.c8788"
      if [ "$CNT8" -ge 3 ]; then   # 连续约 9 秒不活才告警（排除瞬时抖动）
        log "⚠ lemoncore(8788) 连续 ${CNT8} 轮未监听，super 应自愈；持续死亡请人工"
        notify "core8788" "lemoncore 上游(8788) 连续掉线！super 守护应在自愈，若长时间未恢复请人工查看"
      fi
    else
      [ -f "$S/.c8788" ] && [ "$(cat "$S/.c8788")" -ge 3 ] && notify "core8788ok" "lemoncore(8788) 已恢复"
      rm -f "$S/.c8788"
    fi
    CNT=$((CNT+1))
    if [ $((CNT % 10)) -eq 0 ] && [ "${JUST_STARTED:-0}" = "0" ]; then
      if { [ -s $S/.token ] || [ -s $S/.tokens.json ]; } && ! port_up 8792; then
        log "8792 公网口异常，重启 slimproxy"
        run "nohup sh -c 'sh $S/stop.sh; sleep 1; sh $S/start_current.sh' >/dev/null 2>&1 &"
        continue
      fi
      HC=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 http://127.0.0.1:37271/healthz 2>/dev/null)
      if [ "$HC" != "200" ]; then
        NOW=$(date +%s)
        LAST=$(cat "$ZNTS" 2>/dev/null || echo 0)
        if [ $((NOW - LAST)) -ge "$ZN_MIN_INTERVAL" ]; then
          log "zeronews 不健康(HTTP=$HC)，重启(节流${ZN_MIN_INTERVAL}s)"
          echo "$NOW" > "$ZNTS"
          export SSL_CERT_FILE
          run "cd /data/local/tmp/zn_tmp/zeronews && nohup $ZN --workdir $ZNWD start > /data/local/tmp/zn_start.log 2>&1 &"
        fi
      fi
    fi
  fi
done
