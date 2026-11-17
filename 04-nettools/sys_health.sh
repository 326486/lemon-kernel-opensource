#!/system/bin/sh
# ============================================================
# lemonlib · sys_health —— 全链一屏体检
#  2026-09-28 小柠檬本体
#  覆盖：8788 内核 / 8790 卫星 / eBPF / khook / lemon_guard /
#        守护进程 / Binder / service.d / 内核污染 / 内存负载
# ============================================================
P=/data/data/com.termux/files/usr
LC=/data/adb/lemon_core
LK=/data/adb/lemon_kernel
LB=/data/adb/lemonbpf

rc_ok=0
rc_bad=0
chk() { if [ "$1" = "1" ]; then rc_ok=$((rc_ok+1)); else rc_bad=$((rc_bad+1)); fi; }

echo "=================================================="
echo " 🍋 小柠檬内核体系 · 全链体检"
echo " $(date '+%F %T')  |  uptime $(awk '{printf "%d", $1}' /proc/uptime)s"
echo "=================================================="
echo

# ---------- 1. 8788 内核 ----------
printf '[8788 内核] '
init=$(curl -s -m 5 -X POST http://127.0.0.1:8788/mcp \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"health","version":"1"}}}' 2>/dev/null)
if [ -n "$init" ]; then
  echo "$(echo "$init" | grep -oE '"name":"[^"]+"' | head -1 | cut -d'"' -f4) $(echo "$init" | grep -oE '"version":"[^"]+"' | head -1 | cut -d'"' -f4)"
  echo "  工具: $(echo "$init" | grep -oE '"tools":[0-9]+' | cut -d: -f2)  (本地 $(echo "$init" | grep -oE '"local_tools":[0-9]+' | cut -d: -f2))"
  chk 1
else
  echo "❌ 无响应"
  chk 0
fi

# ---------- 2. 8790 卫星 ----------
printf '[8790 卫星] '
if curl -s -m 4 -X POST http://127.0.0.1:8790/mcp -H 'Content-Type: application/json' \
   -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"h","version":"1"}}}' 2>/dev/null | grep -q result; then
  echo "在线 ✅"; chk 1
else
  echo "未响应 ⚠️"; chk 0
fi

# ---------- 3. eBPF ----------
printf '[eBPF] '
if [ -x $LB/lemonbpf ]; then
  st=$($LB/lemonbpf status 2>/dev/null)
  n=$(echo "$st" | grep -c '已装载')
  obj=$(echo "$st" | grep -oE '内核对象存活数：[0-9]+' | grep -oE '[0-9]+')
  echo "对象 ${obj:-?} 个（map/prog/link 共 $n 项）"
  chk 1
else
  echo "❌ 二进制缺失"; chk 0
fi

# ---------- 4. khook ----------
printf '[khook] '
if [ -x $LK/khook/khook.sh ]; then
  h=$($LK/khook/khook.sh health 2>/dev/null | grep -oE 'PASS=[0-9]+ FAIL=[0-9]+')
  echo "${h:-未检出}"
  [ "${h##*FAIL=}" = "0" ] && chk 1 || chk 0
else
  echo "❌ 脚本缺失"; chk 0
fi

# ---------- 5. lemon_guard ----------
printf '[lemon_guard] '
gmod=$(awk '/^lemon_guard/{print $1; exit}' /proc/modules 2>/dev/null)
[ -z "$gmod" ] && [ -d /sys/module/lemon_guard_v6/parameters ] && gmod=lemon_guard_v6   # 隐身感知
if [ -n "$gmod" ]; then
  gpar=/sys/module/$gmod/parameters
  dr=$(cat $gpar/dry_run 2>/dev/null)
  pd=$(cat $gpar/protect_disks 2>/dev/null)
  sp=$(cat $gpar/sys_protected 2>/dev/null)
  if [ "$dr" = "N" ]; then
    lh=$(cat $gpar/lg_hide 2>/dev/null); echo "已加载 ✅ ($gmod${lh:+/隐身})  模式=拦截  范围=${pd:-?}  sys_protected=${sp:-?}"
    chk 1
  else
    echo "已加载 ⚠️ ($gmod)  模式=观察(dry_run=${dr:-?})  未实际拦截"
    chk 0
  fi
else
  echo "未加载 ⚠️"; chk 0
fi

# ---------- 6. 守护进程 ----------
printf '[守护进程] '
n=$(ps -A 2>/dev/null | grep -cE 'lemoncore|lemon-svc|lemon-kernel|guard')
echo "$n 个 (lemoncore/svc/kernel/guard)"
[ "$n" -ge 3 ] && chk 1 || chk 0

# ---------- 7. Binder 服务 ----------
printf '[Binder] '
if service list 2>/dev/null | grep -q 'lemon'; then
  echo "lemon 服务在线 ✅"; chk 1
else
  echo "未发现 ⚠️"; chk 0
fi

# ---------- 8. service.d ----------
printf '[service.d] '
n=$(ls /data/adb/service.d/*.sh 2>/dev/null | wc -l)
bad=$(ls /data/adb/service.d/ 2>/dev/null | grep -cE '\.bak|\.done')
echo "活跃 ${n} 个, 残留 ${bad} 个"
[ "$bad" = "0" ] && chk 1 || chk 0

# ---------- 9. 内核污染 ----------
printf '[内核污染] '
t=$(cat /proc/sys/kernel/tainted 2>/dev/null)
echo "tainted=$t  $([ "$t" = "512" ] && echo '（与基线一致·隐身后）' || echo '（★ 有变化，需查）')"
[ "$t" = "512" ] && chk 1 || chk 0

# ---------- 10. 内存 / 负载 ----------
printf '[内存负载] '
mf=$(awk '/MemFree/{print $2}' /proc/meminfo)
echo "空闲 $((mf/1024)) MB  |  负载 $(cut -d' ' -f1-3 /proc/loadavg)"
chk 1

echo
# ---------- 11. 统一策略中心 ----------
printf '[策略] '
if [ -x "$LK/lemonlib/policy.sh" ]; then
  pout=$(timeout 25 sh "$LK/lemonlib/policy.sh" brief 2>/dev/null)
  pi=$(printf '%s\n' "$pout" | awk -F= '/^POLICY_ITEMS=/{print $2+0}')
  pdr=$(printf '%s\n' "$pout" | awk -F= '/^POLICY_DRIFT=/{print $2+0}')
  if [ -z "$pdr" ]; then
    echo "未检出 ⚠️"; chk 0
  elif [ "$pdr" = "0" ]; then
    echo "策略项 ${pi:-?}  漂移 0  ✅"; chk 1
  else
    echo "策略项 ${pi:-?}  漂移 $pdr  ⚠️"; chk 0
  fi
else
  echo "策略中心未安装 ⚠️"; chk 0
fi

echo "--------------------------------------------------"
echo " 检查项: 通过 $rc_ok  异常 $rc_bad"
if [ "$rc_bad" = "0" ]; then
  echo " 结论: 全链健康 ✅"
else
  echo " 结论: 有 $rc_bad 项需关注 ⚠️"
fi
echo "=================================================="
