#!/system/bin/sh
# ============================================================
# lemonlib · shizuku_ko —— LemonShizuku 内核模块管理器
# 2026-10-02 小柠檬本体
# ------------------------------------------------------------
# 定位：内核态 Shizuku —— 伪造 binder 调用方身份（sender_euid）
#   kprobe binder_proc_transaction(t,...) -> 改写 t+132
#   v1.1 已修：白名单热更新 / 空白名单=不改
#   真机三类用例（正例/反例/闭环）已全过
#
# 用法: shizuku_ko.sh <action> [args]
#   status              模块状态 + 白名单 + 统计
#   load   [uids] [dst] 加载模块（可带初始白名单 / 目标 uid）
#   unload              卸载模块
#   uids   <列表>        设白名单（逗号分隔；空 = 不改任何东西）
#   dst    <uid>        设伪装目标 uid（默认 2000 = shell）
#   enable <0|1>        总开关（默认 0）
#   stats               统计详情
#   selftest            自检
#
# 安全阀：空白名单 = 完全惰性；enable 默认 0
# ============================================================
KO=/data/adb/lemon_kernel/lemonshizuku_ko/lemon_shizuku.ko
MOD=lemon_shizuku
P=/sys/module/$MOD/parameters
ACT="$1"

loaded() { grep -q "^$MOD " /proc/modules 2>/dev/null; }
pp()     { cat "$P/$1" 2>/dev/null; }

case "$ACT" in

status)
  echo "=================================================="
  echo " LemonShizuku 内核模块状态"
  echo "=================================================="
  if loaded; then
    echo "  模块      : 已加载 ($(grep "^$MOD " /proc/modules | awk '{print $2" 字节, 引用 "$3}'))"
    echo "  enable    : $(pp sh_enable)   (0=惰性  1=生效)"
    echo "  白名单    : [$(pp src_uids)]  ($(pp st_white) 项)"
    echo "  目标 uid  : $(pp dst_uid)"
    echo "  ---- 统计 ----"
    echo "  st_calls  : $(pp st_calls)"
    echo "  st_matched: $(pp st_matched)"
    echo "  st_rewrote: $(pp st_rewrote)"
    echo "  last_from : $(pp st_last_from)   last_code: $(pp st_last_code)"
  else
    echo "  模块      : 未加载"
    echo "  ko 路径   : $KO"
    [ -f "$KO" ] && echo "  ko 状态   : 存在 ($(wc -c < "$KO") 字节)"
  fi
  echo "=================================================="
  ;;

stats)
  if loaded; then
    echo "calls=$(pp st_calls) matched=$(pp st_matched) rewrote=$(pp st_rewrote) white=$(pp st_white) last_from=$(pp st_last_from) last_code=$(pp st_last_code) enable=$(pp sh_enable)"
  else
    echo "模块未加载"
    exit 1
  fi
  ;;

load)
  U="$2"; D="$3"
  if loaded; then
    echo "已在加载中"
    exit 0
  fi
  [ -f "$KO" ] || { echo "!! ko 不存在: $KO"; exit 1; }
  if [ -n "$U" ] && [ -n "$D" ]; then
    insmod "$KO" "src_uids=$U" "dst_uid=$D" 2>&1
  elif [ -n "$U" ]; then
    insmod "$KO" "src_uids=$U" 2>&1
  else
    insmod "$KO" 2>&1
  fi
  n=0
  while [ $n -lt 5 ]; do
    n=$((n+1))
    sleep 1
    loaded && break
  done
  if loaded; then
    echo "★ 加载成功"
    echo "  白名单=[$(pp src_uids)] ($(pp st_white) 项) ｜ 目标=$(pp dst_uid) ｜ enable=$(pp sh_enable)"
    dmesg 2>/dev/null | grep lemon_shizuku | tail -2
  else
    echo "!! 加载失败"
    exit 1
  fi
  ;;

unload)
  if ! loaded; then
    echo "未加载"
    exit 0
  fi
  # 安全：先关功能再卸载
  echo 0 > "$P/sh_enable" 2>/dev/null
  rmmod "$MOD" 2>&1
  sleep 1
  if loaded; then
    echo "!! 卸载失败"
    exit 1
  fi
  echo "★ 已卸载"
  dmesg 2>/dev/null | grep "unloaded" | tail -1
  ;;

uids)
  loaded || { echo "!! 模块未加载"; exit 1; }
  echo "$2" > "$P/src_uids" 2>/dev/null || { echo "!! 写入失败"; exit 1; }
  sleep 1
  echo "白名单已设: [$(pp src_uids)] ($(pp st_white) 项)"
  [ "$(pp st_white)" = "0" ] && echo "  (注: 0 项 = 完全惰性，不改任何东西)"
  ;;

dst)
  loaded || { echo "!! 模块未加载"; exit 1; }
  [ -n "$2" ] || { echo "!! 需指定 uid"; exit 1; }
  echo "$2" > "$P/dst_uid" 2>/dev/null || { echo "!! 写入失败"; exit 1; }
  echo "目标 uid 已设: $(pp dst_uid)"
  ;;

enable)
  loaded || { echo "!! 模块未加载"; exit 1; }
  case "$2" in
    0|1) echo "$2" > "$P/sh_enable" 2>/dev/null ;;
    *)   echo "!! 需 0 或 1"; exit 1 ;;
  esac
  echo "sh_enable = $(pp sh_enable)"
  if [ "$(pp sh_enable)" = "Y" ]; then
    W=$(pp st_white)
    [ "$W" = "0" ] && echo "  ⚠️ 警告：白名单为空(0 项) → 模块完全惰性，不会有任何改写"
  fi
  ;;

selftest)
  echo "=== LemonShizuku 自检 ==="
  echo "[1] ko 文件      : $([ -f "$KO" ] && echo OK || echo MISSING)"
  echo "[2] 模块加载     : $(loaded && echo OK || echo '未加载')"
  echo "[3] 参数目录     : $([ -d "$P" ] && echo OK || echo MISSING)"
  if loaded; then
    echo "[4] 参数项数     : $(ls "$P" 2>/dev/null | wc -l) (预期 9)"
    echo "[5] 空白名单惰性 : $([ "$(pp st_white)" = "0" ] && [ "$(pp st_matched)" = "0" ] && echo OK || echo '有匹配(可能已配置)')"
    echo "[6] kprobe 地址  : $(dmesg 2>/dev/null | grep -o 'vaddr=[0-9a-f]*' | tail -1)"
  fi
  ;;

*)
  echo "用法: $0 {status|load [uids] [dst]|unload|uids <列表>|dst <uid>|enable <0|1>|stats|selftest}"
  exit 1
  ;;
esac