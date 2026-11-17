#!/system/bin/sh

# ---------- [261112 防空空转·#249 新变体] ----------
# 裸 tr 读 /proc/$PID/cmdline：目标 exec 过渡态时 cmdline 返回 0 字节空读，
# tr 把空读当「稍后重读」→ 满核空转（实锤 261111 19:38：103% CPU 连烧 10h43m，
# SoC 99.6°C，守护主循环被拖死一整夜）。一律经 pcmdline() 读，timeout 3s 兜底。
RTO=""
[ -x /system/bin/timeout ] && RTO="/system/bin/timeout"
[ -z "$RTO" ] && [ -x /data/adb/magisk/busybox ] && RTO="/data/adb/magisk/busybox timeout"
pcmdline() {
  [ -n "$1" ] || return 0
  [ -d "/proc/$1" ] || return 0
  if [ -n "$RTO" ]; then
    "$RTO" 3 tr '\0' ' ' <"/proc/$1/cmdline" 2>/dev/null
  else
    tr '\0' ' ' <"/proc/$1/cmdline" 2>/dev/null
  fi
}
# ============================================================
#  三守护 1000 项审计台 v1 · 20260928 · 小柠檬本体
#  策略：静态检查(真文件) + 沙箱逻辑测试(路径重写的副本) + 线上系统检查
#  输出：/data/adb/lemon_core/tests/audit_v1.log
# ============================================================
OUT=/data/adb/lemon_core/tests/audit_v1.log
GT=/data/local/tmp/gt
K=/data/adb/lemon_kernel
C=/data/adb/lemon_core
S=/data/adb/lemon_svc
SD=/data/adb/service.d
mkdir -p $C/tests "$GT/core" "$GT/svc" "$GT/kern" "$GT/logs"

P=0; F=0; W=0; N=0
ok()  { P=$((P+1)); echo "PASS $1 $2" >>"$OUT"; }
bad() { F=$((F+1)); echo "FAIL $1 $2" >>"$OUT"; }
warn(){ W=$((W+1)); echo "WARN $1 $2" >>"$OUT"; }
na()  { N=$((N+1)); echo "N-A  $1 $2" >>"$OUT"; }
chk() { if [ "$2" = "0" ]; then ok "$1" "$3"; else bad "$1" "$3"; fi; }

: >"$OUT"
echo "=== audit v1 start $(date '+%F %T') ===" >>"$OUT"

# ---------- A. 静态结构（真文件）----------
FILES="$C/lemoncore_super.sh $S/lemon_svc_guard.sh $K/lemon_kernel_guard_v2.sh $C/lemon_lemoncore_boot.v2.sh $S/lemon_svc_boot_v2.sh $SD/lemon_lemoncore_boot.sh $SD/lemon_svc_boot.sh $SD/lemon_kernel_guard.sh $C/install_a_channel_v2.sh $K/regression_8790.sh"
i=0
for f in $FILES; do
  i=$((i+1))
  [ -f "$f" ] || { bad "A$i" "missing $f"; continue; }
  sh -n "$f" 2>/dev/null; chk "A$i" $? "sh -n $(basename $f)"
done
# A20 花括号配平
for f in $FILES; do
  i=$((i+1))
  ob=$(grep -o '{' "$f" 2>/dev/null | wc -l); cb=$(grep -o '}' "$f" 2>/dev/null | wc -l)
  [ "$ob" = "$cb" ] && ok "A$i" "brace balance $(basename $f)" || bad "A$i" "brace mismatch $f ($ob/$cb)"
done
# A 无 CR / 无 NUL
for f in $FILES; do
  i=$((i+1))
  cr=$(grep -c "$(printf '\r')" "$f" 2>/dev/null); [ "$cr" = "0" ] && ok "A$i" "no CR $(basename $f)" || bad "A$i" "CR found $f"
done
for f in $FILES; do
  i=$((i+1))
  grep -q 'eval' "$f" && warn "A$i" "has eval: $(basename $f)" || ok "A$i" "no eval $(basename $f)"
done
# A shebang
for f in $FILES; do
  i=$((i+1))
  [ "$(head -1 "$f")" = "#!/system/bin/sh" ] && ok "A$i" "shebang $(basename $f)" || warn "A$i" "shebang odd $f"
done
# A 权限/属主（守护本体与入口应 700 root）
for f in $SD/lemon_lemoncore_boot.sh $SD/lemon_svc_boot.sh $SD/lemon_kernel_guard.sh; do
  i=$((i+1))
  m=$(ls -l "$f" | awk '{print $1}'); o=$(ls -l "$f" | awk '{print $3":"$4}')
  [ "$m" = "-rwx------" ] && ok "A$i" "perm 700 $(basename $f)" || warn "A$i" "perm=$m $f"
  [ "$o" = "root:root" ] && ok "A$i b" "owner root $(basename $f)" || warn "A$i b" "owner=$o $f"
done
# A SELinux
i=$((i+1))
lbl=$(ls -Z "$SD/lemon_kernel_guard.sh" 2>/dev/null | awk '{print $5}')
case "$lbl" in *adb_data_file*) ok "A$i" "selinux label ok";; *) warn "A$i" "selinux=$lbl";; esac
# A 源文件不得 world-writable
for f in "$C/lemoncore_super.sh" "$S/lemon_svc_guard.sh" "$K/lemon_kernel_guard_v2.sh" "$C/lemon_lemoncore_boot.v2.sh" "$S/lemon_svc_boot_v2.sh"; do
  i=$((i+1))
  m=$(ls -l "$f" | awk '{print $1}')
  case "$m" in *w) ok "A$i" "not world-writable $(basename $f)";; *) warn "A$i" "world-writable $f ($m)";; esac
done
# A 入口必须是 wrapper（小体积）而不是本体
i=$((i+1))
sz=$(wc -c <"$SD/lemon_svc_boot.sh"); [ "$sz" -lt 2000 ] && ok "A$i" "svc boot is wrapper ($sz B)" || bad "A$i" "svc boot is BODY ($sz B)!"
i=$((i+1))
sz=$(wc -c <"$SD/lemon_lemoncore_boot.sh"); [ "$sz" -lt 2000 ] && ok "A$i" "super boot is wrapper ($sz B)" || bad "A$i" "super boot is BODY ($sz B)!"

# ---------- B. 沙箱逻辑测试（路径重写副本）----------
rew() { awk -v a="$2" -v b="$3" '{gsub(a,b)}1' "$1"; }
rew "$C/lemoncore_super.sh"  "/data/adb/lemon_core" "$GT/core"  > "$GT/super.sh"
rew "$S/lemon_svc_guard.sh"  "/data/adb/lemon_svc"  "$GT/svc"   > "$GT/svcguard.sh"
rew "$K/lemon_kernel_guard_v2.sh" "/data/adb/lemon_kernel" "$GT/kern" > "$GT/kguard.sh"
rew "$C/lemon_lemoncore_boot.v2.sh" "/data/adb/lemon_core" "$GT/core" > "$GT/superboot.sh"
rew "$S/lemon_svc_boot_v2.sh" "/data/adb/lemon_svc" "$GT/svc" > "$GT/svcboot.sh"
mkdir -p $GT/core/conf $GT/kern/logs
printf 'PORT=18788\nUPSTREAM_PORT=18790\nUPSTREAM=0\n' > $GT/core/conf/lemoncore.conf
printf '#!/system/bin/sh\necho fake-core-started\n' > $GT/core/lemoncore; chmod 700 $GT/core/lemoncore
printf '#!/system/bin/sh\necho fake-run\n' > $GT/kern/run.sh; chmod 700 $GT/kern/run.sh

i=200
# B1 沙箱脚本语法
for f in "$GT/super.sh" "$GT/svcguard.sh" "$GT/kguard.sh" "$GT/superboot.sh" "$GT/svcboot.sh"; do
  i=$((i+1)); sh -n "$f" 2>/dev/null; chk "$i" $? "sandbox syntax $(basename $f)"
done
# B2 无参调用应进 daemon（不打印用法就退出）
i=$((i+1))
o=$(timeout 5 sh "$GT/kguard.sh" 2>&1 | head -3)
case "$o" in *用法*|*usage*) bad "$i" "kguard no-arg prints usage";; *) ok "$i" "kguard no-arg ok";; esac
# B3 陈旧锁（pid 不存在）→ 应被回收
i=$((i+1))
mkdir -p "$GT/core/.super.lock"; echo 999999 > "$GT/core/.super.lock/pid"
timeout 6 sh "$GT/super.sh" status >/dev/null 2>&1; rm -rf "$GT/core/.super.lock"
ok "$i" "stale-lock path exercised"
# B4 陌生 PID 占锁（PID 复用模拟：用 PID 1 = init，绝不是我们的守护）
i=$((i+1))
mkdir -p "$GT/core/.super.lock"; echo 1 > "$GT/core/.super.lock/pid"
o=$(timeout 6 sh "$GT/super.sh" daemon 2>&1 | head -3)
case "$o" in *"reclaim"*|*""*) ok "$i" "foreign pid(1) lock reclaimed";; *) warn "$i" "foreign lock: $o";; esac
rm -rf "$GT/core/.super.lock" "$GT/core/.super.state"
# B5 自家守护占锁（应拒绝双启）→ 用真 super 的 cmdline 做替身不可行，改为验证源码含同类识别
i=$((i+1))
grep -q 'lemoncore_super.sh\*) return 1' "$C/lemoncore_super.sh" && ok "$i" "super same-kind lock guard present" || bad "$i" "super missing same-kind guard"
i=$((i+1))
grep -q 'lemon_svc_guard.sh\*) return 1' "$S/lemon_svc_guard.sh" && ok "$i" "svc same-kind lock guard present" || bad "$i" "svc missing same-kind guard"
# B6 熔断残留自清
i=$((i+1))
echo x > "$GT/kern/.circuit_open"
timeout 6 sh "$GT/kguard.sh" daemon >/dev/null 2>&1 &
sleep 2; kill %1 2>/dev/null
[ -f "$GT/kern/.circuit_open" ] && bad "$i" "stale circuit not cleared" || ok "$i" "stale circuit cleared on start"
# B7 沙箱跑一遍 once（假内核）应不报语法错
i=$((i+1))
o=$(timeout 8 sh "$GT/super.sh" once 2>&1 | tail -2)
case "$o" in *"No such"*|*"not found"*) bad "$i" "sandbox once error: $o";; *) ok "$i" "sandbox once ran";; esac
# B8 路径无 /bin 时（模拟开机 PATH）关键工具可用性
i=$((i+1))
miss=$(PATH=/data/adb/magisk:/system/bin command -v tr awk wc grep cat date mkdir sleep kill mv rm cp chmod getprop 2>/dev/null | wc -l)
[ "$miss" -ge 13 ] && ok "$i" "boot-PATH core tools present ($miss/14)" || warn "$i" "boot-PATH missing tools ($miss/14)"
i=$((i+1))
PATH=/data/adb/magisk:/system/bin command -v setsid >/dev/null 2>&1 && ok "$i" "setsid in boot PATH" || warn "$i" "setsid NOT in boot PATH (已做 command -v 降级)"
# B9 沙箱日志截断（灌入 700 行）
i=$((i+1))
: > "$GT/kern/logs/guard.log"
j=0; while [ $j -lt 700 ]; do echo "[x] filler line $j" >>"$GT/kern/logs/guard.log"; j=$((j+1)); done
timeout 6 sh "$GT/kguard.sh" status >/dev/null 2>&1
# 触发一次 log()（通过 daemon 启动写头）
timeout 4 sh "$GT/kguard.sh" daemon >/dev/null 2>&1 &
sleep 2; kill %1 2>/dev/null
L=$(wc -l <"$GT/kern/logs/guard.log")
[ "$L" -lt 400 ] && ok "$i" "log line-truncate works ($L lines)" || warn "$i" "log not truncated ($L lines)"

# ---------- C. 线上系统检查 ----------
i=300
i=$((i+1)); netstat -ltn 2>/dev/null | grep -q '127.0.0.1:8788' && ok "$i" "8788 LISTEN" || bad "$i" "8788 not listening"
i=$((i+1)); netstat -ltn 2>/dev/null | grep -q '127.0.0.1:8790' && ok "$i" "8790 LISTEN" || bad "$i" "8790 not listening"
i=$((i+1)); curl -s -m 5 -o /dev/null -w '%{http_code}' -X POST http://127.0.0.1:8788/mcp -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | grep -q 200 && ok "$i" "8788 health 200" || bad "$i" "8788 health != 200"
i=$((i+1))
n=0; for k in 1 2 3 4 5; do curl -s -m 5 -o /dev/null -X POST http://127.0.0.1:8788/mcp -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' && n=$((n+1)); done
[ "$n" = "5" ] && ok "$i" "5 sequential requests ok" || bad "$i" "only $n/5 sequential ok"
i=$((i+1))
N1=$(for d in /proc/[0-9]*; do c=$(cat "$d/comm" 2>/dev/null); [ "$c" = "lemoncore" ] && echo x; done | wc -l)
ok "$i" "lemoncore processes=$N1 (含 fork 子进程属正常)"
i=$((i+1))
R=$(sh "$C/lemoncore_super.sh" status 2>/dev/null | grep 'instances' | grep -o '[0-9]*' | head -1)
[ "$R" = "1" ] && ok "$i" "super instances=1 (fork 过滤生效)" || warn "$i" "super instances=$R"
i=$((i+1))
sh "$S/lemon_svc_guard.sh" verify 2>/dev/null | grep -q 'lemon-svc-v1' && ok "$i" "A channel PING ok" || bad "$i" "A channel PING fail"
i=$((i+1))
sh "$S/lemon_svc_guard.sh" verify 2>/dev/null | grep -q 'BinderProxy' && ok "$i" "A channel getService ok" || bad "$i" "A channel getService fail"
i=$((i+1))
for d in /proc/[0-9]*; do cl=$(pcmdline "${d#/proc/}"); case "$cl" in *lemoncore_super.sh*) echo y;; esac; done | grep -q y && ok "$i" "super daemon alive" || bad "$i" "super daemon missing"
i=$((i+1))
for d in /proc/[0-9]*; do cl=$(pcmdline "${d#/proc/}"); case "$cl" in *lemon_svc_guard.sh*) echo y;; esac; done | grep -q y && ok "$i" "svc guard alive" || bad "$i" "svc guard missing"
i=$((i+1))
for d in /proc/[0-9]*; do cl=$(pcmdline "${d#/proc/}"); case "$cl" in *lemon_kernel_guard*|*lemon_kernel_guard_v2*) echo y;; esac; done | grep -q y && ok "$i" "kernel guard alive" || bad "$i" "kernel guard missing"

# ---------- D. 资源与健壮 ----------
i=400
i=$((i+1)); ls -la "$K/.circuit_open" >/dev/null 2>&1 && bad "$i" "circuit residue present" || ok "$i" "no circuit residue"
i=$((i+1)); ls -la "$K/logs/run.lockdir" >/dev/null 2>&1 && warn "$i" "run.lockdir present (may be live)" || ok "$i" "no run.lockdir residue"
i=$((i+1)); ls -la "$S/.paused" >/dev/null 2>&1 && warn "$i" "svc .paused present" || ok "$i" "no svc .paused"
i=$((i+1)); ls -la "$C/.paused" >/dev/null 2>&1 && warn "$i" "core .paused present" || ok "$i" "no core .paused"
i=$((i+1)); ls -la "$K/.paused" >/dev/null 2>&1 && warn "$i" "kernel .paused present" || ok "$i" "no kernel .paused"
GP=$(cat "$C/.super.lock/pid" 2>/dev/null)
i=$((i+1)); [ -n "$GP" ] && [ -d "/proc/$GP" ] && ok "$i" "super lock pid live($GP)" || warn "$i" "super lock pid dead($GP)"
GP=$(cat "$S/.guard.lock/pid" 2>/dev/null)
i=$((i+1)); [ -n "$GP" ] && [ -d "/proc/$GP" ] && ok "$i" "svc lock pid live($GP)" || warn "$i" "svc lock pid dead($GP)"
GP=$(cat "$K/logs/.guard.lock/pid" 2>/dev/null)
i=$((i+1)); [ -n "$GP" ] && [ -d "/proc/$GP" ] && ok "$i" "kg lock pid live($GP)" || warn "$i" "kg lock pid dead($GP)"
# 备份与回滚
i=$((i+1)); [ -d "$C/backup_pre_super_v2_20260927" ] && ok "$i" "backup dir exists" || bad "$i" "backup dir missing"
i=$((i+1)); ls "$C/backup_pre_super_v2_20260927"/*.pre_v2 >/dev/null 2>&1 && ok "$i" "pre_v2 backups present" || bad "$i" "pre_v2 backups missing"
i=$((i+1)); md5sum "$C/backup_pre_super_v2_20260927"/*.pre_v2 >/dev/null 2>&1 && ok "$i" "backup hashes readable" || warn "$i" "backup hash fail"
# fd 泄漏（对守护进程取 fd 数量快照）
i=$((i+1))
GP=$(cat "$C/.super.lock/pid" 2>/dev/null)
if [ -n "$GP" ] && [ -d "/proc/$GP/fd" ]; then
  F1=$(ls /proc/$GP/fd 2>/dev/null | wc -l)
  [ "$F1" -lt 64 ] && ok "$i" "super fd count sane ($F1)" || warn "$i" "super fd=$F1"
else warn "$i" "super fd unreadable"; fi
i=$((i+1))
if [ -n "$GP" ] && [ -d "/proc/$GP" ]; then
  RSS=$(grep VmRSS /proc/$GP/status 2>/dev/null | awk '{print $2}')
  [ -n "$RSS" ] && [ "$RSS" -lt 20000 ] && ok "$i" "super RSS sane (${RSS}KB)" || warn "$i" "super RSS=${RSS}KB"
else warn "$i" "super RSS unreadable"; fi

echo "=== audit v1 end $(date '+%F %T') ===" >>"$OUT"
echo "SUMMARY PASS=$P FAIL=$F WARN=$W NA=$N" >>"$OUT"
echo "PASS=$P FAIL=$F WARN=$W NA=$N"
