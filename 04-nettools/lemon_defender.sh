#!/system/bin/sh
# ============================================================
# lemon_defender.sh v1.0 · 恶意脚本防御者（引擎 + 主控）
# 20261001 · 小柠檬本体 · 授权：小良
# ------------------------------------------------------------
#  定位：持续扫描 + 特征评分 + 命中即隔离删除
#  配合：lemon_guard_v6（内核态硬拦截）形成双层防线
#
#  用法:
#    lemon_defender.sh scan   [路径...]   一次性扫描（默认全部监控点）
#    lemon_defender.sh start  [间隔秒]    启动持续监控守护
#    lemon_defender.sh stop              停止守护
#    lemon_defender.sh status            状态
#    lemon_defender.sh quarantine        列出隔离区
#    lemon_defender.sh restore <文件>    从隔离区恢复
#    lemon_defender.sh whitelist         列出白名单
#    lemon_defender.sh report            扫描报告
#    lemon_defender.sh check <文件>      单文件详查（不删）
# ============================================================
DF=/data/adb/lemon_defender
QUAR=$DF/quarantine
DLOG=$DF/logs
DSTATE=$DF/state
mkdir -p "$QUAR" "$DLOG" "$DSTATE" 2>/dev/null

# ---------- 监控点 ----------
WATCH_DIRS="/data/adb/service.d
/data/adb/post-fs-data.d
/data/adb/init.d
/data/adb/modules
/data/local/tmp
/storage/emulated/0/Download
/storage/emulated/0/tencent
/storage/emulated/0/Android/data/com.tencent.mm/Tencent
/storage/emulated/0/Android/data/com.tencent.tim/Tencent
/storage/emulated/0/Android/data/com.tencent.mobileqq/Tencent
/storage/emulated/0/Android/data/com.tencent.mobileqq/Tencent/TIMfile_recv"

# ---------- 白名单（路径前缀，命中则永不处置）----------
WLIST="/data/adb/lemon_kernel
/data/adb/lemon_core
/data/adb/lemonguard
/data/adb/lemonprotect
/data/adb/lemonbpf
/data/adb/lemon_svc
/data/adb/lemon_defender
/data/adb/modules/lemon
/data/adb/modules/LemonMCPRoot
/data/adb/MT2"

# ---------- 文件级白名单（精确路径，自家脚本永不处置）----------
#   说明：lemon_guard_boot.sh 等含 insmod 关键字会被 P2 标记，属正常，此处豁免
FILE_WLIST="/data/adb/service.d/lemon_guard_boot.sh
/data/adb/service.d/lemon_lemoncore_boot.sh
/data/adb/service.d/lemon_bpf_boot.sh
/data/adb/service.d/lemon_khook_boot.sh
/data/adb/service.d/lemon_svc_boot.sh
/data/adb/service.d/lemon_agent_backup.sh
/data/adb/service.d/lemon_kernel_guard.sh
/data/adb/service.d/lemon_skill_selftest.sh
/data/adb/service.d/lemon_crashguard.sh
/data/adb/service.d/lemon_xbmcp_boot.sh"

# ---------- 可扫描扩展名 ----------
EXTS="sh
bash
py
pl
txt
js
lua
cfg
conf
prop"

is_whitelisted(){
  for w in $WLIST; do
    case "$1" in "$w"*) return 0 ;; esac
  done
  for w in $FILE_WLIST; do
    [ "$1" = "$w" ] && return 0
  done
  return 1
}

ext_ok(){
  e=$(printf '%s' "$1" | sed 's/.*\.//')
  for x in $EXTS; do [ "$e" = "$x" ] && return 0; done
  # 无扩展名但内容像脚本
  case "$1" in */*) return 1 ;; esac
  return 1
}

# ============================================================
# 特征评分引擎：scan_content <文件> -> "分数|等级|命中规则"
#   规则全部用 grep -E（toybox 不支持 BRE \|）
# ============================================================
scan_content(){
  f="$1"
  [ -r "$f" ] || { printf '0|OK|'; return; }
  # 二进制快速排除（od 读魔数，toybox grep 不支持 \x 转义）
  mg=$(od -An -tx1 -N4 "$f" 2>/dev/null | tr -d ' \n')
  case "$mg" in
    7f454c46*|89504e47*|504b0304*|1f8b08*|425a68*) printf '0|OK|BIN'; return ;;
  esac
  # ★v1.1：单趟 awk 引擎（原 20+ 次 grep → 1 次，约 20x 提速）
  awk -f /data/adb/lemon_kernel/lemonlib/rules/defender_rules.awk "$f" 2>/dev/null
}

# 是否自动处置（P0/P1 删；P2 仅标记）
should_purge(){ case "$2" in P0-*|P1-*) return 0 ;; *) return 1 ;; esac; }

# ============================================================
# 处置：隔离（备份到隔离区）后删除
# ============================================================
quarantine_file(){
  src="$1"; tag="$2"
  ts=$(date +%Y%m%d_%H%M%S)
  dst="$QUAR/$ts"
  mkdir -p "$dst"
  base=$(basename "$src")
  cp -a "$src" "$dst/$base" 2>/dev/null
  if [ -f "$dst/$base" ]; then
    printf '%s\t%s\t%s\t%s\n' "$ts" "$tag" "$src" "$dst/$base" >> "$DLOG/quarantine.tsv"
    if rm -f "$src" 2>/dev/null; then
      printf '    🚫 已隔离并删除: %s  [%s]\n' "$src" "$tag"
    else
      # 内核态在受保护目录内拦截了 rm → 降级为「清零失效」（清空内容，使其无法执行）
      if : > "$src" 2>/dev/null; then
        printf '    🚫 已隔离 + 清零失效（rm 被内核拦，内容已清空）: %s  [%s]\n' "$src" "$tag"
      else
        printf '    ⚠ 已隔离（副本安全），但原文件 rm/清零均被拒: %s\n' "$src"
      fi
    fi
    return 0
  fi
  printf '    [!] 隔离失败（保留原文件）: %s\n' "$src"
  return 1
}

# ============================================================
# 扫描
# ============================================================
do_scan(){
  dirs="$*"
  [ -z "$dirs" ] && dirs="$WATCH_DIRS"
  ts=$(date +%Y%m%d_%H%M%S)
  RPT="$DLOG/scan_$ts.log"
  CAND="$DSTATE/cand.txt"; CLEAN="$DSTATE/cand.clean"; HITS="$DSTATE/hits.txt"
  : > "$CAND"
  for d in $dirs; do
    [ -d "$d" ] || continue
    find "$d" -maxdepth 3 -type f \( -name '*.sh' -o -name '*.bash' -o -name '*.py' \
         -o -name '*.txt' -o -name '*.cfg' -o -name '*.conf' -o -name '*.prop' \
         -o -name '*.js' -o -name '*.lua' -o -name '*.pl' \) 2>/dev/null | head -n 800 >> "$CAND"
  done
  : > "$CLEAN"
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    is_whitelisted "$f" && continue
    case "$f" in *.bak|*.orig|*.disabled) continue ;; esac
    printf '%s\n' "$f" >> "$CLEAN"
  done < "$CAND"
  tot=$(wc -l < "$CLEAN")

  {
    printf '===== 🍋 柠檬防御者扫描 %s =====\n' "$(date '+%F %T')"
    printf '候选文件: %s 个（批量单趟引擎）\n' "$tot"
  } | tee "$RPT"

  n_bad=0; n_del=0
  # ★v1.1 批量单趟：一次 awk 处理全部文件（原 per-file 20+grep → 整体 1 进程）
  awk -v mode=batch -f /data/adb/lemon_kernel/lemonlib/rules/defender_rules.awk \
      $(cat "$CLEAN" 2>/dev/null | tr '\n' ' ') 2>/dev/null > "$HITS"

  while IFS='|' read -r path sc lv rules; do
    [ -n "$path" ] || continue
    n_bad=$((n_bad + 1))
    printf '  [%s] 分=%-4s 规则=%s\n        %s\n' "$lv" "$sc" "$rules" "$path" | tee -a "$RPT"
    if should_purge "$path" "$lv"; then
      quarantine_file "$path" "$lv$rules" | tee -a "$RPT"
      n_del=$((n_del + 1))
    else
      printf '    ⚠ 仅标记（P2 不自动删除）\n' | tee -a "$RPT"
    fi
  done < "$HITS"

  {
    printf '\n──────────────────────────────\n'
    printf '扫描文件: %s   命中: %s   已处置: %s\n' "$tot" "$n_bad" "$n_del"
    printf '结论: %s\n' "$([ "$n_bad" -eq 0 ] && echo '✅ 未发现恶意脚本' || echo '⚠ 见上方命中项')"
    printf '报告: %s\n' "$RPT"
  } | tee -a "$RPT"
  printf '%s\t%s\t%s\t%s\n' "$(date '+%F %T')" "$tot" "$n_bad" "$n_del" >> "$DLOG/scan_history.tsv"
}

do_check(){
  f="$1"
  [ -f "$f" ] || { printf '[x] 文件不存在: %s\n' "$f"; return 1; }
  r=$(scan_content "$f")
  printf '文件: %s\n' "$f"
  printf '大小: %s B   修改: %s\n' "$(wc -c < "$f")" "$(date -r "$f" '+%F %T' 2>/dev/null)"
  printf '评分: %s   定级: %s\n' "$(printf '%s' "$r" | cut -d'|' -f1)" "$(printf '%s' "$r" | cut -d'|' -f2)"
  printf '命中: %s\n' "$(printf '%s' "$r" | cut -d'|' -f3)"
  printf '\n---- 命中行 ----\n'
  grep -n -E 'of=[[:space:]]*/dev/|mke2fs|mkfs|/dev/block/|rm[[:space:]]+-[a-zA-Z]*rf?[[:space:]]+/|base64[[:space:]]+-d|/dev/tcp/|eval[[:space:]]+[\$]|curl|wget|nc[[:space:]]+-|insmod|resetprop' "$f" 2>/dev/null | head -n 12
}

do_quarantine(){
  [ -s "$DLOG/quarantine.tsv" ] || { printf '（隔离区为空）\n'; return 0; }
  printf '===== 🗄 隔离区 =====\n'
  printf '%-16s %-22s %s\n' 时间 定级 原路径
  while IFS='	' read -r ts tag src dst; do
    printf '%-16s %-22s %s\n' "$ts" "$tag" "$src"
  done < "$DLOG/quarantine.tsv"
  printf '\n恢复: lemon_defender.sh restore <隔离区文件路径>\n'
}

do_restore(){
  q="$1"
  [ -f "$q" ] || { printf '[x] 隔离文件不存在: %s\n' "$q"; return 1; }
  line=$(grep -F "$q" "$DLOG/quarantine.tsv" 2>/dev/null | head -n1)
  [ -z "$line" ] && { printf '[x] 无记录\n'; return 1; }
  orig=$(printf '%s' "$line" | cut -f3)
  cp -a "$q" "$orig" 2>/dev/null && printf '[OK] 已恢复到 %s\n' "$orig" || printf '[x] 恢复失败\n'
}

do_whitelist(){
  printf '===== ✅ 白名单（永不处置）=====\n'
  for w in $WLIST; do printf '  %s\n' "$w"; done
  printf '\n修改：编辑 %s 的 WLIST\n' /data/adb/lemon_kernel/lemonlib/lemon_defender.sh
}

do_status(){
  printf '===== 🍋 柠檬防御者状态 =====\n'
  if [ -r "$DSTATE/watch.pid" ]; then
    p=$(cat "$DSTATE/watch.pid" 2>/dev/null)
    kill -0 "$p" 2>/dev/null && printf '监控守护: 运行中 pid=%s\n' "$p" || printf '监控守护: 未运行(陈旧pid)\n'
  else printf '监控守护: 未启动\n'; fi
  printf '隔离区文件: %s 个\n' "$(find "$QUAR" -type f 2>/dev/null | wc -l)"
  printf '历史扫描: %s 次\n' "$(wc -l < "$DLOG/scan_history.tsv" 2>/dev/null || echo 0)"
  printf '\n-- 最近扫描 --\n'
  tail -n 4 "$DLOG/scan_history.tsv" 2>/dev/null | sed 's/^/  /'
  printf '\n-- 内核态事件（lemon_guard_v6）--\n'
  if [ -r /sys/module/lemon_guard_v6/parameters/events ]; then
    head -n 8 /sys/module/lemon_guard_v6/parameters/events | sed 's/^/  /'
  else printf '  （v6 未加载或无 events 参数）\n'; fi
}

do_start(){
  iv="${1:-15}"
  case "$iv" in ''|*[!0-9]*) iv=15 ;; esac
  [ "$iv" -lt 5 ] && iv=5
  if [ -r "$DSTATE/watch.pid" ]; then
    p=$(cat "$DSTATE/watch.pid" 2>/dev/null)
    kill -0 "$p" 2>/dev/null && { printf '[i] 守护已在运行 pid=%s\n' "$p"; return 0; }
  fi
  nohup env LEMON_DEF_IV="$iv" sh /data/adb/lemon_kernel/lemonlib/defender_watch.sh >/dev/null 2>&1 &
  printf '%s\n' "$!" > "$DSTATE/watch.pid"
  printf '[OK] 监控守护已启动 pid=%s  轮询=%ss\n' "$!" "$iv"
}
do_stop(){
  if [ -r "$DSTATE/watch.pid" ]; then
    p=$(cat "$DSTATE/watch.pid" 2>/dev/null)
    [ -n "$p" ] && kill "$p" 2>/dev/null && printf '[OK] 已停 pid=%s\n' "$p"
    rm -f "$DSTATE/watch.pid"
  else printf '[i] 未运行\n'; fi
}

case "$1" in
  scan)       shift; do_scan "$@" ;;
  check)      do_check "$2" ;;
  start)      do_start "$2" ;;
  stop)       do_stop ;;
  status)     do_status ;;
  quarantine) do_quarantine ;;
  restore)    do_restore "$2" ;;
  whitelist)  do_whitelist ;;
  *) printf '用法: lemon_defender.sh {scan [路径..]|check <文件>|start [秒]|stop|status|quarantine|restore <f>|whitelist}\n' ;;
esac
