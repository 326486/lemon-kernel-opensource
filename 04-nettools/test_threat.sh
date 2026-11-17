#!/system/bin/sh
# test_threat.sh — 威胁情报工具离线验收（无需 key）
N=/data/lemonbrain/nettools
PY=/data/data/com.termux/files/usr/bin/python3
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  PASS $1"; }
no(){ FAIL=$((FAIL+1)); echo "  FAIL $1"; }
chk(){ if [ "$1" = 0 ]; then ok "$2"; else no "$2"; fi; }

echo '== TH01 语法 =='
sh -n "$N/threat_check.sh" && "$PY" -m py_compile "$N/threat_check.py"; chk $? 'TH01 语法'

echo '== TH02 SHA256正确 =='
TF=/data/local/tmp/threat_test_$$
printf 'abc' > "$TF"
OUT=$("$PY" -c "import sys;sys.path.insert(0,'$N');import threat_check as t;print(t.sha256_file('$TF'))")
[ "$OUT" = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad" ]; chk $? 'TH02 SHA256(abc)正确'
rm -f "$TF"

echo '== TH03 无key优雅降级 =='
OUT=$(ABUSE_AUTH_KEY='<placeholder>' sh "$N/threat_check.sh" '{"action":"hash","sha256":"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"}' 2>&1)
echo "$OUT" | grep -q 'no_key'; chk $? 'TH03 无key返回no_key'

echo '== TH04 非法哈希 =='
sh "$N/threat_check.sh" '{"action":"hash","sha256":"xyz"}' >/dev/null 2>&1; RC=$?
[ $RC = 1 ]; chk $? 'TH04 非法哈希拒绝'

echo '== TH05 未知action =='
sh "$N/threat_check.sh" '{"action":"nope"}' >/dev/null 2>&1; RC=$?
[ $RC = 1 ]; chk $? 'TH05 未知action拒绝'

echo '== TH06 不存在文件 =='
sh "$N/threat_check.sh" '{"action":"file","path":"/no/such/file"}' >/dev/null 2>&1; RC=$?
[ $RC = 2 ]; chk $? 'TH06 不存在文件exit2'

echo '─────'
echo "PASS=$PASS FAIL=$FAIL"
[ $FAIL = 0 ]
