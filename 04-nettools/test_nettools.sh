#!/system/bin/sh
# test_nettools.sh — 联网搜索/抓取验收（TDD）
N=/data/lemonbrain/nettools
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  PASS $1"; }
no(){ FAIL=$((FAIL+1)); echo "  FAIL $1"; }
chk(){ if [ "$1" = 0 ]; then ok "$2"; else no "$2"; fi; }

echo '== N01 语法 =='
sh -n "$N/web_search.sh" && sh -n "$N/web_fetch.sh"; chk $? 'N01 包装脚本语法'

echo '== N02 搜索出结果 =='
OUT=$(sh "$N/web_search.sh" '一加Ace6 参数' 2>&1)
echo "$OUT" | grep -q 'engine=' && echo "$OUT" | grep -qE 'https?://'
chk $? 'N02 搜索含引擎与链接'

echo '== N03 空查询拒绝 =='
sh "$N/web_search.sh" '' >/dev/null 2>&1; RC=$?
[ $RC != 0 ]; chk $? 'N03 空查询拒绝'

echo '== N04 抓取正文 =='
OUT=$(sh "$N/web_fetch.sh" 'https://www.baidu.com' 2>&1)
echo "$OUT" | grep -q 'web_fetch' && [ ${#OUT} -gt 200 ] && ! echo "$OUT" | grep -q '<style' && ! echo "$OUT" | grep -q 'font-size'
chk $? 'N04 抓取有正文且无CSS泄漏'

echo '== N05 SSRF环回 =='
OUT=$(sh "$N/web_fetch.sh" 'http://127.0.0.1:8788/' 2>&1); RC=$?
[ $RC = 3 ] && echo "$OUT" | grep -q 'BLOCKED'
chk $? 'N05 环回地址拦截'

echo '== N06 SSRF内网 =='
sh "$N/web_fetch.sh" 'http://192.168.1.1/' >/dev/null 2>&1; RC=$?
[ $RC = 3 ]; chk $? 'N06 私网地址拦截'

echo '== N07 协议限制 =='
sh "$N/web_fetch.sh" 'file:///system/build.prop' >/dev/null 2>&1; RC=$?
[ $RC = 3 ]; chk $? 'N07 file协议拦截'

echo '== N08 中文查询相关性 =='
OUT=$(sh "$N/web_search.sh" '一加Ace6 屏幕刷新率' 2>&1)
echo "$OUT" | grep '^\[1\]' | grep -q '一加'
chk $? 'N08 首条结果与中文查询相关'

echo '== N09 混合查询相关性 =='
OUT=$(sh "$N/web_search.sh" '骁龙8至尊版 跑分' 2>&1)
echo "$OUT" | grep '^\[1\]' | grep -q '骁龙'
chk $? 'N09 中英混合查询首条相关'

echo '== N10 小浣熊AI搜索 =='
OUT=$(sh "$N/web_search.sh" '长沙今天天气' 2>&1)
echo "$OUT" | grep -q 'engine=raccoon-ai' && echo "$OUT" | grep -qE 'https?://'
chk $? 'N10 AI搜索主引擎出结果带链接'

echo '== N11 网关故障回退 =='
OUT=$(RACCOON_URL='http://127.0.0.1:9' sh "$N/web_search.sh" '一加Ace6 参数' 2>&1)
echo "$OUT" | grep -q 'engine=' && ! echo "$OUT" | grep -q 'engine=raccoon-ai' && echo "$OUT" | grep -q 'fallback=raccoon'
chk $? 'N11 网关不可用回退爬虫链'

echo '─────'
echo "PASS=$PASS FAIL=$FAIL"
[ $FAIL = 0 ]
