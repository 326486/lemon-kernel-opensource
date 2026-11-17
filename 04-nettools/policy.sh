#!/system/bin/sh
# ============================================================
# lemonlib · policy —— 统一策略中心  v1.1
#   2026-09-29  小柠檬本体
# ------------------------------------------------------------
#   一份 JSON 定义，一条命令 应用 / 校验 / 回滚
#   覆盖域：file_protect(fslock) / bpf_track(eBPF)
#           kprobe(khook) / guard(lemon_guard 参数一致性)
#   特性：零内核改动 · 零砖风险 · 幂等 · 带状态快照
#   用法：sh policy.sh status|check|apply|revert|history|path|help
# ------------------------------------------------------------
#   防空转(#249)：循环带推进哨兵；外部调用一律 timeout；
#                日志上限截断，禁无上限追加
# ============================================================
LK=/data/adb/lemon_kernel
LB=/data/adb/lemonbpf
POL=$LK/conf/policy.json
STD=$LK/conf/policy.state
LOG=$LK/conf/policy.log
PY=/data/data/com.termux/files/usr/bin/python3
TMO=15
MAXITEM=200
KEEP=5

[ -x "$PY" ] || PY=python3
[ -f "$POL" ] || { echo "缺少策略文件: $POL"; exit 2; }

log(){
  echo "[$(date '+%F %T')] $*" >> "$LOG" 2>/dev/null
  n=$(wc -l < "$LOG" 2>/dev/null)
  if [ "${n:-0}" -gt 500 ]; then
    tail -n 300 "$LOG" > "$LOG.tmp" 2>/dev/null
    mv -f "$LOG.tmp" "$LOG" 2>/dev/null
  fi
}

# ---------- 策略解析（python3 读 JSON，不假手 shell） ----------
pyflat(){
  timeout $TMO "$PY" - "$POL" <<'PYEOF' 2>/dev/null
import json,sys
try:
    d=json.load(open(sys.argv[1]))
except Exception as e:
    print("__error__=%s" % e); sys.exit(0)
def emit(k,v):
    if v is True:    v="true"
    elif v is False: v="false"
    print("%s=%s"%(k,v))
emit("version", d.get("version",""))
emit("updated", d.get("updated",""))
fp=d.get("file_protect") or {}
emit("file_protect.enable", fp.get("enable", False))
for x in (fp.get("paths") or []): emit("file_protect.path", x)
bt=d.get("bpf_track") or {}
emit("bpf_track.enable", bt.get("enable", False))
for x in (bt.get("targets") or []): emit("bpf_track.target", x)
kp=d.get("kprobe") or {}
emit("kprobe.enable", kp.get("enable", False))
for x in (kp.get("probes") or []):
    if isinstance(x, dict):
        emit("kprobe.probe", "%s|%s|%s"%(x.get("name",""),x.get("func",""),x.get("args","")))
    else:
        emit("kprobe.probe", str(x))
g=d.get("guard") or {}
for k in ("dry_run","protect_disks","sys_protected"):
    if k in g: emit("guard."+k, g[k])
PYEOF
}

val(){ printf '%s\n' "$FLAT" | awk -v k="$1" '{i=index($0,"="); if(i>0 && substr($0,1,i-1)==k){print substr($0,i+1); exit}}'; }
lst(){ printf '%s\n' "$FLAT" | awk -v k="$1" '{i=index($0,"="); if(i>0 && substr($0,1,i-1)==k) print substr($0,i+1)}'; }
cnt(){ printf '%s\n' "$FLAT" | awk -v k="$1" '{i=index($0,"="); if(i>0 && substr($0,1,i-1)==k) n++} END{print n+0}'; }

# ---------- 实际状态探测 ----------
fslock_state(){
  o=$(timeout $TMO "$LB/lemonbpf" fslock status "$1" 2>/dev/null)
  if printf '%s' "$o" | grep -Fq "未锁定"; then echo unlocked
  elif printf '%s' "$o" | grep -Fq "已锁定"; then echo locked
  else echo unknown; fi
}
guard_mod(){ m=$(awk '/^lemon_guard/{print $1; exit}' /proc/modules 2>/dev/null); if [ -n "$m" ]; then echo "$m"; elif [ -d /sys/module/lemon_guard_v6/parameters ]; then echo lemon_guard_v6; fi; }
guard_param(){ timeout $TMO cat "/sys/module/$1/parameters/$2" 2>/dev/null; }
probe_names(){
  timeout $TMO cat /sys/kernel/tracing/kprobe_events 2>/dev/null | awk -F/ '/^[pr]:/{print $2}' | awk '{print $1}'
}
has_probe(){ probe_names | awk -v n="$1" 'index($0,n)==1 && length($0)==length(n){f=1} END{exit !f}'; }
bpf_loaded(){ timeout $TMO "$LB/lemonbpf" status 2>/dev/null | awk -v m="$1" 'index($0,"已装载")>0 && index($0,m)>0 {f=1} END{exit !f}'; }

# ---------- 正文（只输出 4 个域的对照正文） ----------
body(){
  FLAT=$(pyflat)
  if printf '%s' "$FLAT" | grep -Fq "__error__="; then
    echo "  ✗ policy.json 解析失败"
    return
  fi

  echo "[文件保护 fslock]"
  e=$(val file_protect.enable); n=$(cnt file_protect.path)
  if [ "$e" = "true" ]; then echo "  开关: 开   定义 $n 条（上锁）"
  else echo "  开关: 关   定义 $n 条（收敛为解锁）"; fi
  [ "$n" = "0" ] && echo "  (未定义路径)"
  lst file_protect.path | awk -v mx="$MAXITEM" 'NR>mx{exit} length($0)>0{print} {if(NR>=mx) exit}' | while IFS= read -r p; do
    a=$(fslock_state "$p")
    if [ "$e" = "true" ]; then
      if [ "$a" = "locked" ]; then echo "  ✓ $p  [已锁定]"
      else echo "  ✗ $p  [期望锁定，实际 $a]"; fi
    else
      if [ "$a" = "unlocked" ]; then echo "  ✓ $p  [未锁定]"
      else echo "  ✗ $p  [期望解锁，实际 $a]"; fi
    fi
  done
  echo

  echo "[进程追踪 eBPF]"
  e=$(val bpf_track.enable); n=$(cnt bpf_track.target)
  if [ "$e" = "true" ]; then echo "  开关: 开   目标 $n 个"
  else echo "  开关: 关   目标 $n 个"; fi
  [ "$n" = "0" ] && echo "  (未定义目标)"
  lst bpf_track.target | awk -v mx="$MAXITEM" 'NR>mx{exit} length($0)>0{print} {if(NR>=mx) exit}' | while IFS= read -r t; do
    if bpf_loaded pidcount_map; then echo "  ✓ 目标 $t  [pidcount 程序在线]"
    else echo "  ✗ 目标 $t  [pidcount 程序未装载]"; fi
  done
  echo

  echo "[内核探针 khook]"
  e=$(val kprobe.enable); n=$(cnt kprobe.probe)
  if [ "$e" = "true" ]; then echo "  开关: 开   定义 $n 条（挂载）"
  else echo "  开关: 关   定义 $n 条（收敛为卸载）"; fi
  [ "$n" = "0" ] && echo "  (未定义探针)"
  lst kprobe.probe | awk -v mx="$MAXITEM" 'NR>mx{exit} length($0)>0{print} {if(NR>=mx) exit}' | while IFS= read -r s; do
    nm=$(printf '%s' "$s" | awk -F'|' '{print $1}')
    [ -z "$nm" ] && continue
    if has_probe "$nm"; then echo "  ✓ $nm  [已挂载]"
    else echo "  ✗ $nm  [期望挂载，实际未挂]"; fi
  done
  echo

  echo "[防格机模块 guard]"
  gm=$(guard_mod)
  if [ -z "$gm" ]; then
    echo "  ✗ lemon_guard 未加载"
  else
    echo "  模块: $gm"
    for k in dry_run protect_disks sys_protected; do
      want=$(val "guard.$k")
      [ -z "$want" ] && continue
      got=$(guard_param "$gm" "$k")
      if [ "$got" = "$want" ]; then echo "  ✓ $k=$got"
      else echo "  ✗ $k=$got  (期望 $want)"; fi
    done
  fi
  echo
}

counts(){
  printf '%s\n' "$1" | awk '{ if (index($0,"  ✓")==1 || index($0,"  ✗")==1) m++
                              if (index($0,"  ✗")==1) d++ } END{ print m+0" "d+0 }'
}
header(){
  echo "=================================================="
  echo " 🍋 统一策略中心 v1.1   policy.json v1.1"
  echo " $(date '+%F %T')   $POL"
  echo "=================================================="
  echo
}
finish(){
  IT=$(counts "$1"); ITEMS=${IT%% *}; DRIFT=${IT##* }
  echo "--------------------------------------------------"
  echo " 策略项: $ITEMS   漂移: $DRIFT"
  if [ "$DRIFT" = "0" ]; then echo " 结论: 策略与实际一致 ✅"
  else echo " 结论: 有 $DRIFT 项漂移 ⚠️   (执行 apply 收敛)"; fi
  echo "=================================================="
}

# ---------- 命令 ----------
cmd_status(){
  header
  B=$(body)
  printf '%s\n' "$B"
  finish "$B"
}

cmd_check(){
  B=$(body)
  header
  printf '%s\n' "$B"
  finish "$B"
  IT=$(counts "$B"); DRIFT=${IT##* }
  [ "$DRIFT" = "0" ] && return 0 || return 1
}

prune_state(){
  ls -1 "$STD"/policy-*.json 2>/dev/null | sort > /data/local/tmp/lemon_pol_b.$$.tmp
  n=$(wc -l < /data/local/tmp/lemon_pol_b.$$.tmp 2>/dev/null)
  i=0
  while IFS= read -r f; do
    i=$((i+1))
    [ "${n:-0}" -le "$KEEP" ] && break
    [ "$i" -le $((n-KEEP)) ] && rm -f "$f" 2>/dev/null
  done < /data/local/tmp/lemon_pol_b.$$.tmp
  rm -f /data/local/tmp/lemon_pol_b.$$.tmp 2>/dev/null
}

cmd_apply(){
  FLAT=$(pyflat)
  ts=$(date '+%Y%m%d_%H%M%S')
  mkdir -p "$STD" 2>/dev/null
  cp -f "$POL" "$STD/policy-$ts.json" 2>/dev/null
  cp -f "$POL" "$POL.bak" 2>/dev/null
  prune_state
  log "apply start snapshot=policy-$ts.json"

  changed=0

  e=$(val file_protect.enable)
  lst file_protect.path | awk -v mx="$MAXITEM" 'NR>mx{exit} length($0)>0{print}' > /data/local/tmp/lemon_pol_a.$$.tmp
  i=0
  while IFS= read -r p; do
    i=$((i+1)); [ "$i" -gt "$MAXITEM" ] && break
    [ -z "$p" ] && continue
    a=$(fslock_state "$p")
    if [ "$e" = "true" ]; then
      if [ "$a" != "locked" ]; then
        timeout $TMO "$LB/lemonbpf" fslock on "$p" >/dev/null 2>&1
        echo "  + 上锁 $p"; changed=$((changed+1))
      fi
    else
      if [ "$a" = "locked" ]; then
        timeout $TMO "$LB/lemonbpf" fslock off "$p" >/dev/null 2>&1
        echo "  - 解锁 $p"; changed=$((changed+1))
      fi
    fi
  done < /data/local/tmp/lemon_pol_a.$$.tmp

  e=$(val bpf_track.enable)
  if [ "$e" = "true" ]; then
    lst bpf_track.target | awk -v mx="$MAXITEM" 'NR>mx{exit} length($0)>0{print}' > /data/local/tmp/lemon_pol_a.$$.tmp
    i=0
    while IFS= read -r t; do
      i=$((i+1)); [ "$i" -gt "$MAXITEM" ] && break
      [ -z "$t" ] && continue
      timeout $TMO "$LB/lemonbpf" track "$t" >/dev/null 2>&1 && { echo "  + 追踪 $t"; changed=$((changed+1)); }
    done < /data/local/tmp/lemon_pol_a.$$.tmp
  fi

  e=$(val kprobe.enable)
  lst kprobe.probe | awk -v mx="$MAXITEM" 'NR>mx{exit} length($0)>0{print}' > /data/local/tmp/lemon_pol_a.$$.tmp
  i=0
  while IFS= read -r s; do
    i=$((i+1)); [ "$i" -gt "$MAXITEM" ] && break
    [ -z "$s" ] && continue
    nm=$(printf '%s' "$s" | awk -F'|' '{print $1}')
    fc=$(printf '%s' "$s" | awk -F'|' '{print $2}')
    ar=$(printf '%s' "$s" | awk -F'|' '{print $3}')
    [ -z "$nm" ] && continue
    if [ "$e" = "true" ]; then
      if ! has_probe "$nm"; then
        timeout $TMO sh "$LK/khook/khook.sh" probe_add "$nm" "$fc" "$ar" >/dev/null 2>&1 && { echo "  + 探针 $nm"; changed=$((changed+1)); }
      fi
    else
      if has_probe "$nm"; then
        timeout $TMO sh "$LK/khook/khook.sh" probe_del "$nm" >/dev/null 2>&1 && { echo "  - 探针 $nm"; changed=$((changed+1)); }
      fi
    fi
  done < /data/local/tmp/lemon_pol_a.$$.tmp
  rm -f /data/local/tmp/lemon_pol_a.$$.tmp 2>/dev/null

  log "apply done changed=$changed"
  echo "[apply] 变更 $changed 项"
  echo
  B=$(body)
  header
  printf '%s\n' "$B"
  finish "$B"
}

cmd_revert(){
  last=$(ls -1 "$STD"/policy-*.json 2>/dev/null | sort | tail -n 1)
  if [ -z "$last" ]; then echo "无可回滚快照（$STD 为空）"; return 2; fi
  bn=$(printf '%s' "$last" | awk -F/ '{print $NF}')
  cp -f "$POL" "$STD/policy-prerevert-$(date '+%Y%m%d_%H%M%S').json" 2>/dev/null
  cp -f "$last" "$POL" 2>/dev/null
  echo "[revert] 已恢复策略快照: $bn"
  log "revert from $bn"
  cmd_apply
}

cmd_history(){
  echo "快照目录: $STD"
  ls -1 "$STD" 2>/dev/null | sort | tail -n 10 | sed 's/^/  /'
  n=$(ls -1 "$STD" 2>/dev/null | wc -l)
  echo "(共 ${n:-0} 个，最多保留 $KEEP 个)"
}

cmd_brief(){
  B=$(body)
  IT=$(counts "$B"); ITEMS=${IT%% *}; DRIFT=${IT##* }
  echo "POLICY_ITEMS=$ITEMS"
  echo "POLICY_DRIFT=$DRIFT"
}

case "$1" in
  status)  cmd_status ;;
  check)   cmd_check ;;
  brief)   cmd_brief ;;
  apply)   cmd_apply ;;
  revert)  cmd_revert ;;
  history) cmd_history ;;
  path|edit) echo "$POL" ;;
  ""|help|-h|--help)
     echo "lemon_policy v1.1 · 统一策略中心"
     echo "用法: sh policy.sh <命令>"
     echo "  status    策略 vs 实际 一屏对照"
     echo "  check     只校验不改动；有漂移 exit=1（供体检/开机调用）"
     echo "  apply     把实际状态收敛到 policy.json（幂等 + 自动快照）"
     echo "  revert    回滚到上一个快照并重新应用"
     echo "  history   列出快照"
     echo "  path      打印策略文件路径"
     ;;
  *) echo "未知命令: $1（用 help 看用法）"; exit 2 ;;
esac
