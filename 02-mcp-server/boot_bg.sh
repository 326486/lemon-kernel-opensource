#!/system/bin/sh
# boot_bg.sh —— LemonSlim 后台开机引导 v1.5.2（261112）
# 由 service.d/lemon_slim_boot.sh 后台拉起；在后台等解锁+网络，再按铁序幂等拉起全套
# 铁序：zeronews 隧道(实例一+实例二) → 备用维护通道(8795) → 主门面(8791/8792) → 令牌闸(8796) → 双活看门狗
# 幂等：端口/进程活着就跳过，重复执行无害
# [261112 v1.5.2] 实例二(zeronews_home2)开机拉起；令牌闸⑫从 exit 0 之后移入执行路径

S=${LEMON_BOOT_HOME:-/data/lemonbrain/slimproxy}
LOG=${LEMON_BOOT_LOG:-/data/lemonbrain/logs/boot_bg.log}
mkdir -p "$(dirname "$LOG")" 2>/dev/null
say() { echo "[$(date '+%m-%d %H:%M:%S')] boot: $*" >> "$LOG"; }

say "引导开始 pid=$$"

# ① 等开机完成 + CE 存储解锁（/data/data 可读）——后台等，不阻塞 service.d
#    BOOT_SKIP_WAIT=1（沙箱测试/手动热执行）跳过所有等待
if [ "${BOOT_SKIP_WAIT:-0}" != "1" ]; then
  i=0
  while [ "$(getprop sys.boot_completed 2>/dev/null)" != "1" ] && [ $i -lt 120 ]; do
    sleep 5; i=$((i+1))
  done
  say "boot_completed=$(getprop sys.boot_completed)（等了 $((i*5))s）"
  i=0
  while [ ! -x /data/data/com.termux/files/usr/bin/python3 ] && [ $i -lt 60 ]; do
    sleep 5; i=$((i+1))   # CE 区（Termux）解锁确认
  done

  # ② 再等网络就绪（zeronews 要出网），最多 3 分钟
  i=0
  while [ $i -lt 36 ]; do
    ping -c1 -W2 223.5.5.5 >/dev/null 2>&1 && break
    sleep 5; i=$((i+1))
  done
  say "网络就绪（$((i*5))s）"
  sleep 10   # 网络刚起来时 DNS/路由未必稳，再缓一缓
else
  say "BOOT_SKIP_WAIT=1，跳过等待段"
fi

port_up() {  # 本机端口监听检测（/proc/net/tcp，十六进制端口 + 0A=LISTEN）
  HEX=$(printf "%X" "$1")
  awk -v h=":$HEX" '$2 ~ h"$" && $4 == "0A" {f=1} END {exit !f}' /proc/net/tcp 2>/dev/null
}
proc_alive() {  # cmdline 精确匹配（防 PID 复用冒充）
  for P in $(ls /proc | grep -E '^[0-9]+$'); do
    C=$(tr '\0' ' ' < "/proc/$P/cmdline" 2>/dev/null)
    case "$C" in *"$1"*) return 0;; esac
  done
  return 1
}

# ③ zeronews 隧道（隧道看门狗兜底；它不在就整个隧道体系没人管）
if ! proc_alive "lemon_tunnel_watchdog.sh"; then
  say "隧道看门狗不在，拉起"
  nohup sh /data/local/tmp/lemon_tunnel_watchdog.sh >/dev/null 2>&1 &
else
  say "隧道看门狗已在 ✓"
fi
# ③-a 实例一（zeronews_home，指向 8792 门面）
if ! proc_alive "zeronews_home start"; then
  say "zeronews 实例一不在，直接拉起"
  # [261112 #249/D8] zn_start.log 轮转：留上一轮排障，最多两代，防无限增长
ZL=/data/local/tmp
rm -f "$ZL"/zn_start.log.2
mv -f "$ZL"/zn_start.log.1 "$ZL"/zn_start.log.2 2>/dev/null
mv -f "$ZL"/zn_start.log "$ZL"/zn_start.log.1 2>/dev/null
cd /data/local/tmp/zn_tmp/zeronews && nohup ./zeronews --workdir /data/local/tmp/zeronews_home start >/data/local/tmp/zn_start.log 2>&1 &
else
  say "zeronews 实例一已在 ✓"
fi
# ③-b 实例二（zeronews_home2，第二账号独立客户端，指向 8796 令牌闸）—— 261112 新增
if ! proc_alive "zeronews_home2 start"; then
  say "zeronews 实例二不在，拉起"
ZL=/data/local/tmp
rm -f "$ZL"/zn2_start.log.2
mv -f "$ZL"/zn2_start.log.1 "$ZL"/zn2_start.log.2 2>/dev/null
mv -f "$ZL"/zn2_start.log "$ZL"/zn2_start.log.1 2>/dev/null
cd /data/local/tmp/zn_tmp/zeronews && nohup env SSL_CERT_FILE=/data/data/com.termux/files/usr/etc/tls/cert.pem ./zeronews --workdir /data/local/tmp/zeronews_home2 start --http_listen 127.0.0.1:37272 >/data/local/tmp/zn2_start.log 2>&1 &
else
  say "zeronews 实例二已在 ✓"
fi

# ④ 备用维护通道（无令牌文件则启动器自己会拒绝，安全）
if ! port_up 8795; then
  say "备用通道未起，拉起"
  sh "$S/start_maint.sh" >/dev/null 2>&1
else
  say "备用通道 8795 ✓"
fi

# ⑤ 主门面：统一入口自动选最新版（新版上线后无需改本脚本）
if ! port_up 8791; then
  say "主门面未起，start_current.sh 拉起"
  sh "$S/start_current.sh" >/dev/null 2>&1
else
  say "主门面 8791 ✓"
fi

# ⑦ MCP 令牌闸 (8796 → 8787, MT root MCP 前置鉴权) —— 261112 新增；v1.5.2 移入执行路径
if ! port_up 8796; then
  nohup /data/data/com.termux/files/usr/bin/python3 -B /data/local/tmp/mcp_gate_8787.py >/dev/null 2>&1 &
  say "MCP 令牌闸已拉起 (8796)"
else
  say "MCP 令牌闸已在运行，跳过"
fi

# ⑥ 双活看门狗（互备；最后起，让它们接手一切巡检）
for ROLE in primary secondary; do
  if ! proc_alive "watchdog_v15.* $ROLE" && ! pgrep -f "watchdog_v15[0-9]\.sh $ROLE" >/dev/null 2>&1; then
    say "看门狗 $ROLE 不在，拉起"
    nohup sh "$S/watchdog_v151.sh" "$ROLE" >/dev/null 2>&1 &
  else
    say "看门狗 $ROLE ✓"
  fi
done

say "引导完成"
# 开机自检通知（lemon-user手机通知栏可见；静默失败不影响主流程）
cmd notification post -S bigtext -t "小柠檬内核" lemon_boot \
  "开机自启完成：门面/备用通道/隧道(×2)/令牌闸/看门狗已就绪" 2>/dev/null
exit 0