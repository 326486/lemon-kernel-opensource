#!/system/bin/sh
# test_github.sh — GitHub 直连工具离线验收（无需令牌）
N=/data/lemonbrain/nettools
PY=/data/data/com.termux/files/usr/bin/python3
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  PASS $1"; }
no(){ FAIL=$((FAIL+1)); echo "  FAIL $1"; }
chk(){ if [ "$1" = 0 ]; then ok "$2"; else no "$2"; fi; }

echo '== G01 语法 =='
sh -n "$N/github_api.sh" && "$PY" -m py_compile "$N/github_api.py"; chk $? 'G01 语法'

echo '== G02 缺令牌拒绝 =='
OUT=$(GITHUB_TOKEN='<placeholder>' sh "$N/github_api.sh" '{"action":"user"}' 2>&1); RC=$?
[ $RC = 3 ] && echo "$OUT" | grep -q 'GITHUB_TOKEN'
chk $? 'G02 缺令牌exit3'

echo '== G03 非法JSON =='
sh "$N/github_api.sh" 'notjson' >/dev/null 2>&1; RC=$?
[ $RC = 1 ]; chk $? 'G03 非法JSON拒绝'

echo '== G04 未知action =='
OUT=$(sh "$N/github_api.sh" '{"action":"nope"}' 2>&1); RC=$?
[ $RC = 1 ] && echo "$OUT" | grep -q '未知 action'
chk $? 'G04 未知action拒绝'

echo '== G05 凭据排除 =='
OUT=$("$PY" -c "import sys; sys.path.insert(0,'$N'); import github_api as g; print(g.is_secret('.token'), g.is_secret('files/ai.conf'), g.is_secret('search.conf'), g.is_secret('x.pyc'), g.is_secret('lib/00_core.sh'), g.is_secret('files/ai.conf.example'))")
[ "$OUT" = "True True True True False False" ]; chk $? 'G05 凭据排除正确'

echo '─────'
echo "PASS=$PASS FAIL=$FAIL"
[ $FAIL = 0 ]
