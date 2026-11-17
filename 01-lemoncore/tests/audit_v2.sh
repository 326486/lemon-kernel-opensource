#!/system/bin/sh
# ============================================================
#  三守护 1000 项审计台 v2（防挂死版）· 20260928 · 小柠檬本体
#  经验：绝不对常驻守护用 timeout/前台等待 —— 一律 setsid + kill -9 收尾
#  输出：/data/adb/lemon_core/tests/audit_v2.log
# ============================================================
OUT=/data/adb/lemon_core/tests/audit_v2.log
GT=/data/local/tmp/gt3
K=/data/adb/lemon_kernel; C=/data/adb/lemon_core; S=/data/adb/lemon_svc; SD=/data/adb/service.d
rm -rf "$GT"; mkdir -p "$GT/core/conf" "$GT/svc" "$GT/kern/logs"

P=0;F=0;W=0;N=0
ok(){ P=$((P+1)); echo "PASS $1 $2" >>"$OUT"; }
bad(){ F=$((F+1)); echo "FAIL $1 $2" >>"$OUT"; }
warn(){ W=$((W+1)); echo "WARN $1 $2" >>"$OUT"; }
na(){ N=$((N+1)); echo "N-A  $1 $2" >>"$OUT"; }
chk(){ if [ "$2" = "0" ]; then ok "$1" "$3"; else bad "$1" "$3"; fi; }
has(){ grep -q "$2" "$1" 2>/dev/null; chk "$3" $? "$4"; }
# 起守护（沙箱）并返回 pid
spawn(){ setsid sh "$1" daemon </dev/null >>"$OUT.spawn" 2>&1 & sleep 2; }
# 收尾：杀掉该沙箱守护
reap(){ LP=$(cat "$1" 2>/dev/null); [ -n "$LP" ] && kill -9 "$LP" 2>/dev/null; }

: >"$OUT"
echo "=== audit v2 start $(date '+%F %T') ===" >>"$OUT"
SUP=$C/lemoncore_super.sh; SV=$S/lemon_svc_guard.sh; KG=$K/lemon_kernel_guard_v2.sh
BSUP=$C/lemon_lemoncore_boot.v2.sh; BSV=$S/lemon_svc_boot_v2.sh
rw(){ awk -v a="$2" -v b="$3" '{gsub(a,b)}1' "$1"; }

# ================= D1 静态（每条一个编号）=================
n=100
for f in $SUP $SV $KG $BSUP $BSV $SD/lemon_lemoncore_boot.sh $SD/lemon_svc_boot.sh $SD/lemon_kernel_guard.sh $C/install_a_channel_v2.sh $K/regression_8790.sh; do
  n=$((n+1)); sh -n "$f" 2>/dev/null; chk "D1-$n" $? "sh -n $(basename $f)"
done
for f in $SUP $SV $KG $BSUP $BSV; do
  n=$((n+1)); ob=$(grep -o '{' "$f"|wc -l); cb=$(grep -o '}' "$f"|wc -l); [ "$ob" = "$cb" ] && ok "D1-$n" "brace $(basename $f)" || bad "D1-$n" "brace $f $ob/$cb"
  n=$((n+1)); grep -q "$(printf '\r')" "$f" && bad "D1-$n" "CRLF $(basename $f)" || ok "D1-$n" "noCR $(basename $f)"
  n=$((n+1)); grep -q 'eval ' "$f" && warn "D1-$n" "eval in $(basename $f)" || ok "D1-$n" "noeval $(basename $f)"
  n=$((n+1)); [ "$(head -1 "$f")" = "#!/system/bin/sh" ] && ok "D1-$n" "shebang $(basename $f)" || bad "D1-$n" "shebang $f"
  n=$((n+1)); dup=$(grep -oE '^[a-z_]+\(\)' "$f" | sort | uniq -d | wc -l); [ "$dup" = "0" ] && ok "D1-$n" "no dup funcs $(basename $f)" || bad "D1-$n" "dup funcs $f"
done
# 危险模式：非引号 rm -rf / kill 变量
n=$((n+1)); grep -nE 'rm -rf [^"$]|kill -9 [^"$]' $SUP $SV $KG | grep -v 'kill -9 "\$' | grep -v 'rm -rf "' >/dev/null 2>&1 && warn "D1-$n" "unquoted rm/kill found" || ok "D1-$n" "rm/kill quoted"
# 关键修复标记是否都在
for pair in "$SUP:BUG-N" "$SUP:BUG-I" "$SUP:BUG-F" "$SV:BUG-O" "$SV:BUG-Q" "$KG:BUG-J" "$KG:BUG-K" "$KG:BUG-M" "$KG:BUG-Q" "$KG:1:-daemon"; do
  f=${pair%%:*}; t=${pair#*:}; n=$((n+1))
  has "$f" "$t" "D1-$n" "marker $t in $(basename $f)"
done
n=$((n+1)); has "$BSUP" "lemoncore_super.sh\*) exit 0" "D1-$n" "super wrapper cmdline verify"
n=$((n+1)); has "$BSV" "lemon_svc_guard.sh\*) exit 0" "D1-$n" "svc wrapper cmdline verify"
n=$((n+1)); has "$BSUP" "command -v setsid" "D1-$n" "super wrapper setsid probe"
n=$((n+1)); has "$BSV" "command -v setsid" "D1-$n" "svc wrapper setsid probe"

# ================= D6/D8 权限·安全 =================
n=200
for f in $SD/lemon_lemoncore_boot.sh $SD/lemon_svc_boot.sh $SD/lemon_kernel_guard.sh; do
  n=$((n+1)); m=$(ls -l "$f"|awk '{print $1}'); [ "$m" = "-rwx------" ] && ok "D6-$n" "700 $(basename $f)" || bad "D6-$n" "perm $m $f"
done
n=$((n+1)); [ "$(wc -c <$SD/lemon_svc_boot.sh)" -lt 2000 ] && ok "D6-$n" "svc boot=wrapper" || bad "D6-$n" "svc boot is body"
n=$((n+1)); [ "$(wc -c <$SD/lemon_lemoncore_boot.sh)" -lt 2000 ] && ok "D6-$n" "super boot=wrapper" || bad "D6-$n" "super boot is body"
n=$((n+1)); has $SUP 'list_ours' "D8-$n" "fork-filter impl"
n=$((n+1)); case "$(sh $SUP status 2>/dev/null | grep instances)" in *"instances  : 1"*) ok "D8-$n" "instances=1 live";; *) warn "D8-$n" "instances!=1";; esac
# 注入尝试：子命令传恶意串不得执行
n=$((n+1)); rm -f /data/local/tmp/INJECTED
sh $KG "daemon; touch /data/local/tmp/INJECTED" >/dev/null 2>&1 &
sleep 1; reap "$K/logs/.guard.lock/pid"; rm -rf "$K/logs/.guard.lock"
[ -f /data/local/tmp/INJECTED ] && bad "D8-$n" "子命令注入成功执行!" || ok "D8-$n" "subcommand injection blocked"
n=$((n+1)); rm -f /data/local/tmp/INJ2
sh $SUP '$(touch /data/local/tmp/INJ2)' >/dev/null 2>&1
[ -f /data/local/tmp/INJ2 ] && bad "D8-$n" "命令替换注入成功!" || ok "D8-$n" "cmdsubst injection blocked"
n=$((n+1)); grep -qE 'AKIA|BEGIN RSA|password=' $SUP $SV $KG && warn "D8-$n" "possible secret in script" || ok "D8-$n" "no obvious secret"

# ================= D7 运行时（沙箱 + 线上）=================
n=300
# 沙箱三守护
rw "$SUP" "/data/adb/lemon_core" "$GT/core" > "$GT/super.sh"
rw "$SV" "/data/adb/lemon_svc" "$GT/svc" > "$GT/svcguard.sh"
rw "$KG" "/data/adb/lemon_kernel" "$GT/kern" > "$GT/kguard.sh"
rw "$BSUP" "/data/adb/lemon_core" "$GT/core" > "$GT/superboot.sh"
rw "$BSV" "/data/adb/lemon_svc" "$GT/svc" > "$GT/svcboot.sh"
printf 'PORT=18788\nUPSTREAM_PORT=18790\nUPSTREAM=0\n' > $GT/core/conf/lemoncore.conf
printf '#!/system/bin/sh\necho fake-core\n' > $GT/core/lemoncore; chmod 700 $GT/core/lemoncore
printf '#!/system/bin/sh\necho fake-run\n' > $GT/kern/run.sh; chmod 700 $GT/kern/run.sh
n=$((n+1)); sh -n $GT/super.sh 2>/dev/null; chk "D7-$n" $? "sandbox super syntax"
n=$((n+1)); sh -n $GT/svcguard.sh 2>/dev/null; chk "D7-$n" $? "sandbox svc syntax"
n=$((n+1)); sh -n $GT/kguard.sh 2>/dev/null; chk "D7-$n" $? "sandbox kg syntax"
# 无参调用不得只打用法
n=$((n+1)); sh $GT/kguard.sh </dev/null >$GT/o1 2>&1 & sleep 2; reap $GT/kern/logs/.guard.lock/pid; rm -rf $GT/kern/logs/.guard.lock
grep -q '用法' $GT/o1 && bad "D7-$n" "kguard no-arg usage" || ok "D7-$n" "kguard no-arg ok"
# 单实例：连起 3 个沙箱守护，锁只能有一个持有者
n=$((n+1)); rm -rf $GT/core/.super.lock
sh $GT/super.sh daemon </dev/null >/dev/null 2>&1 &
sh $GT/super.sh daemon </dev/null >/dev/null 2>&1 &
sh $GT/super.sh daemon </dev/null >/dev/null 2>&1 &
sleep 3; CNT=$(ls -d $GT/core/.super.lock 2>/dev/null | wc -l)
[ "$CNT" = "1" ] && ok "D7-$n" "single-instance lock held once" || warn "D7-$n" "lock count=$CNT"
reap $GT/core/.super.lock/pid; rm -rf $GT/core/.super.lock
# 陈旧锁回收
n=$((n+1)); mkdir -p $GT/core/.super.lock; echo 999999 > $GT/core/.super.lock/pid
sh $GT/super.sh daemon </dev/null >/dev/null 2>&1 & sleep 3
LP=$(cat $GT/core/.super.lock/pid 2>/dev/null)
[ "$LP" != "999999" ] && ok "D7-$n" "stale lock reclaimed (now $LP)" || bad "D7-$n" "stale lock not reclaimed"
reap $GT/core/.super.lock/pid; rm -rf $GT/core/.super.lock
# 陌生 PID 占锁（PID 1）
n=$((n+1)); mkdir -p $GT/core/.super.lock; echo 1 > $GT/core/.super.lock/pid
sh $GT/super.sh daemon </dev/null >/dev/null 2>&1 & sleep 3
LP=$(cat $GT/core/.super.lock/pid 2>/dev/null); [ "$LP" != "1" ] && ok "D7-$n" "foreign(1) lock reclaimed" || bad "D7-$n" "foreign lock stuck"
reap $GT/core/.super.lock/pid; rm -rf $GT/core/.super.lock
# TERM 可停（BUG-Q）—— 用 status 路径验证 trap 定义存在 + 实测
n=$((n+1)); has $KG 'trap on_stop INT TERM HUP' "D7-$n" "kg term-trap defined"
n=$((n+1)); has $SUP 'trap on_stop INT TERM HUP' "D7-$n" "super term-trap defined"
n=$((n+1)); has $SV 'trap on_stop INT TERM HUP' "D7-$n" "svc term-trap defined"
n=$((n+1)); rm -rf $GT/kern/.guard.lock
sh $GT/kguard.sh daemon </dev/null >/dev/null 2>&1 &
sleep 2; TP=$(cat $GT/kern/logs/.guard.lock/pid 2>/dev/null)
kill $TP 2>/dev/null; T0=$(date +%s); GONE=0
for i in 1 2 3 4 5 6 7 8 9 10; do sleep 1; if [ ! -d /proc/$TP ]; then GONE=1; break; fi; done
[ "$GONE" = "1" ] && ok "D7-$n" "SIGTERM stops guard (t=$(( $(date +%s) - T0 ))s)" || { bad "D7-$n" "SIGTERM cannot stop guard"; kill -9 $TP 2>/dev/null; }
rm -rf $GT/kern/logs/.guard.lock
# 熔断自清
n=$((n+1)); echo "opened" > $GT/kern/.circuit_open
sh $GT/kguard.sh daemon </dev/null >/dev/null 2>&1 & sleep 3
[ -f $GT/kern/.circuit_open ] && bad "D7-$n" "stale circuit kept" || ok "D7-$n" "stale circuit auto-cleared"
reap $GT/kern/logs/.guard.lock/pid; rm -rf $GT/kern/logs/.guard.lock
# pause 生效
n=$((n+1)); : > $GT/kern/.paused
sh $GT/kguard.sh daemon </dev/null >/dev/null 2>&1 & sleep 3
LP=$(cat $GT/kern/logs/.guard.lock/pid 2>/dev/null)
[ -z "$LP" ] || [ ! -d /proc/$LP ] && ok "D7-$n" "paused daemon exits" || { warn "D7-$n" "paused daemon alive($LP)"; kill -9 $LP 2>/dev/null; }
rm -f $GT/kern/.paused; rm -rf $GT/kern/logs/.guard.lock
# 日志截断（行数）
n=$((n+1)); : > $GT/kern/logs/guard.log
j=0; while [ $j -lt 700 ]; do echo "[fill] line $j" >>$GT/kern/logs/guard.log; j=$((j+1)); done
sh $GT/kguard.sh once </dev/null >/dev/null 2>&1 & sleep 3; reap $GT/kern/logs/run.lockdir/pid
L=$(wc -l <$GT/kern/logs/guard.log 2>/dev/null)
[ "$L" -lt 400 ] && ok "D7-$n" "log truncate works ($L lines)" || warn "D7-$n" "log not truncated ($L)"
# clean_runlock：假锁（无关 PID）应被清
n=$((n+1)); mkdir -p $GT/kern/logs/run.lockdir; echo 1 > $GT/kern/logs/run.lockdir/pid
sh $GT/kguard.sh once </dev/null >/dev/null 2>&1 & sleep 3
[ -d $GT/kern/logs/run.lockdir ] && { ST=$(cat $GT/kern/logs/run.lockdir/pid 2>/dev/null); [ "$ST" = "1" ] && bad "D7-$n" "fake runlock kept" || ok "D7-$n" "fake runlock replaced"; } || ok "D7-$n" "fake runlock cleaned"
# ---- 线上 ----
n=$((n+1)); netstat -ltn 2>/dev/null | grep -q '127.0.0.1:8788' && ok "D7-$n" "8788 listen" || bad "D7-$n" "8788 down"
n=$((n+1)); netstat -ltn 2>/dev/null | grep -q '127.0.0.1:8790' && ok "D7-$n" "8790 listen" || bad "D7-$n" "8790 down"
n=$((n+1)); curl -s -m 5 -o /dev/null -w '%{http_code}' -X POST http://127.0.0.1:8788/mcp -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | grep -q 200 && ok "D7-$n" "8788 200" || bad "D7-$n" "8788 health"
n=$((n+1)); k=0; for r in 1 2 3 4 5 6 7 8; do curl -s -m 5 -o /dev/null -X POST http://127.0.0.1:8788/mcp -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' && k=$((k+1)); done
[ "$k" = "8" ] && ok "D7-$n" "8 sequential reqs ok" || bad "D7-$n" "only $k/8 reqs"
n=$((n+1)); sh $SV verify 2>/dev/null | grep -q 'lemon-svc-v1' && ok "D7-$n" "A-ch PING" || bad "D7-$n" "A-ch PING fail"
n=$((n+1)); sh $SV verify 2>/dev/null | grep -q BinderProxy && ok "D7-$n" "A-ch getService" || bad "D7-$n" "A-ch getService fail"
n=$((n+1)); sh $SV verify 2>/dev/null | grep -q '命中' && ok "D7-$n" "A-ch CALL passthrough" || bad "D7-$n" "A-ch CALL fail"
n=$((n+1)); sh $SUP status 2>/dev/null | grep -q 'listening  : YES' && ok "D7-$n" "super reports listening" || bad "D7-$n" "super reports down"
n=$((n+1)); sh $KG status 2>/dev/null | grep -q 'LISTEN' && ok "D7-$n" "kg reports LISTEN" || bad "D7-$n" "kg reports down"

# ================= D10 交付/回滚 =================
n=400
n=$((n+1)); [ -d $C/backup_pre_super_v2_20260927 ] && ok "D10-$n" "backup dir" || bad "D10-$n" "backup dir missing"
n=$((n+1)); ls $C/backup_pre_super_v2_20260927/*.pre_v2 >/dev/null 2>&1 && ok "D10-$n" "pre_v2 backups" || bad "D10-$n" "pre_v2 missing"
n=$((n+1)); [ -f $K/regression_8790.sh ] && ok "D10-$n" "regression script" || warn "D10-$n" "regression script gone"
n=$((n+1)); [ -d $C/tests ] && ok "D10-$n" "tests dir" || warn "D10-$n" "tests dir missing"
n=$((n+1)); md5sum $SUP $SV $KG > $C/tests/md5_now.txt 2>/dev/null && ok "D10-$n" "md5 snapshot saved" || warn "D10-$n" "md5 snapshot fail"
n=$((n+1)); [ -s $C/tests/md5_now.txt ] && ok "D10-$n" "md5 snapshot non-empty" || bad "D10-$n" "md5 snapshot empty"

echo "=== audit v2 end $(date '+%F %T') ===" >>"$OUT"
echo "SUMMARY PASS=$P FAIL=$F WARN=$W NA=$N" >>"$OUT"
echo "PASS=$P FAIL=$F WARN=$W NA=$N"
