#!/system/bin/sh
# test_sherry.sh — 雪莉复活 P1+P2 验收测试（TDD）
K=/data/lemonbrain/sherry_keeper
A="$K/sherry_agent.sh"
ST='/storage/emulated/0/雪莉工作室'
PY=/data/data/com.termux/files/usr/bin/python3
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  PASS $1"; }
no(){ FAIL=$((FAIL+1)); echo "  FAIL $1"; }
chk(){ if [ "$1" = "0" ]; then ok "$2"; else no "$2"; fi; }

echo "== T01 模块存在 =="
[ -f "$A" ]; chk $? "T01 agent入口存在"

echo "== T02 全库语法 =="
S=0
for f in "$A" "$K"/lib/*.sh; do
  [ -f "$f" ] || { S=1; continue; }
  sh -n "$f" 2>/dev/null || S=1
done
chk $S "T02 sh -n 全通过"

echo "== T03 status输出 =="
OUT=$(sh "$A" status 2>&1)
echo "$OUT" | grep -q 'sherry' && echo "$OUT" | grep -q 'health' && echo "$OUT" | grep -q 'disk'
chk $? "T03 status含sherry/health/disk"

echo "== T04 白名单10例 =="
if [ -f "$K/lib/10_safety.sh" ]; then
  . "$K/lib/00_core.sh"
  . "$K/lib/10_safety.sh"
  W=0
  sherry_path_allowed '/storage/emulated/0/Download/a.tmp'; [ $? = 0 ] || W=1
  sherry_path_allowed '/storage/emulated/0/DCIM/b.jpg'; [ $? = 0 ] || W=1
  sherry_path_allowed '/storage/emulated/0/Pictures/c.png'; [ $? = 0 ] || W=1
  sherry_path_allowed '/storage/emulated/0/Android/data/d/e.log'; [ $? = 0 ] || W=1
  sherry_path_allowed '/data/local/tmp/f.tmp'; [ $? = 0 ] || W=1
  sherry_path_allowed '/system/build.prop'; [ $? != 0 ] || W=1
  sherry_path_allowed '/data/adb/modules/x'; [ $? != 0 ] || W=1
  sherry_path_allowed '/data/data/com.x/y'; [ $? != 0 ] || W=1
  sherry_path_allowed '$LEMON_DATA/记忆中心/z.md'; [ $? != 0 ] || W=1
  sherry_path_allowed '/data/lemonbrain/core/k.py'; [ $? != 0 ] || W=1
  chk $W "T04 白名单10例"
else
  no "T04 白名单10例(库缺失)"
fi

echo "== T05 clean --dry 不动文件 =="
FIX=/data/local/tmp/sherry_fix_$$
mkdir -p "$FIX"
echo x > "$FIX/junk.tmp"
sh "$A" clean --dry "$FIX" >/dev/null 2>&1
[ -f "$FIX/junk.tmp" ]; chk $? "T05 dry-run后文件仍在"

echo "== T06 clean 真清理入回收站 =="
sh "$A" clean "$FIX" >/dev/null 2>&1
[ ! -f "$FIX/junk.tmp" ] && grep -rq 'junk.tmp' '/storage/emulated/0/分类文件夹/回收站/' 2>/dev/null
chk $? "T06 文件移入回收站且manifest留痕"

echo "== T07 organize 归类 =="
FIX2=/data/local/tmp/sherry_fix2_$$
mkdir -p "$FIX2"
echo x > "$FIX2/p.jpg"; echo x > "$FIX2/s.mp3"; echo x > "$FIX2/d.pdf"
sh "$A" organize "$FIX2" >/dev/null 2>&1
[ -f "$FIX2/Images/p.jpg" ] && [ -f "$FIX2/Audio/s.mp3" ] && [ -f "$FIX2/Docs/d.pdf" ]
chk $? "T07 按类型归类"

echo "== T08 deep_scan 只扫不删 =="
FIX3=/data/local/tmp/sherry_fix3_$$
mkdir -p "$FIX3"
echo x > "$FIX3/keep.tmp"
sh "$A" deep_scan "$FIX3" >/dev/null 2>&1
[ -f "$FIX3/keep.tmp" ] && ls "$ST/运行状态/" 2>/dev/null | grep -q 'scan'
chk $? "T08 深扫出报告且不删"

echo "== T09 chat 输出 =="
OUT=$(sh "$A" chat '你好' 2>&1)
echo "$OUT" | grep -q 'sherry' && [ ${#OUT} -gt 30 ]
chk $? "T09 chat含标记且内容完整"

echo "== T10 单实例锁 =="
mkdir -p "$K/files/.lock" 2>/dev/null
OUT=$(sh "$A" status 2>&1); RC=$?
rmdir "$K/files/.lock" 2>/dev/null
[ $RC != 0 ] && echo "$OUT" | grep -q 'busy'
chk $? "T10 锁占用时拒绝并提示busy"

echo "== T11 计数器 =="
OUT=$(sh "$A" status 2>&1)
echo "$OUT" | grep -qE 'recycled[^0-9]*[1-9]'
chk $? "T11 回收计数>=1"

echo "== T12 deep_scan 默认用户区 =="
OUT=$(sh "$A" deep_scan 2>&1); RC=$?
[ $RC = 0 ] && echo "$OUT" | grep -q 'scan done'
chk $? "T12 deep_scan默认用户区放行"

echo "== T13 云脑可用 =="
. "$K/lib/95_ai_judge.sh"
ai_available; chk $? "T13 ai_available网关在线"

echo "== T14 AI判断白名单内tmp =="
FIX4=/data/local/tmp/sherry_fix4_$$
mkdir -p "$FIX4"
echo testdata > "$FIX4/ai_junk.tmp"
V=$(ai_judge_file "$FIX4/ai_junk.tmp")
[ "$V" = "safe" ]; chk $? "T14 AI判safe(实际:$V)"

echo "== T15 白名单优先于AI =="
V=$(ai_judge_file '/system/build.prop')
[ "$V" = "dangerous" ]; chk $? "T15 禁区直接dangerous不走AI"

echo "== T16 判断缓存 =="
V2=$(ai_judge_file "$FIX4/ai_junk.tmp")
N=$(grep -c "$FIX4/ai_junk.tmp" "$ST/运行状态/ai_verdict/cache.tsv" 2>/dev/null)
[ "$V2" = "safe" ] && [ "$N" = "1" ]; chk $? "T16 二次判断走缓存(行数:$N)"

echo "== T17 ai_clean --dry =="
sh "$A" ai_clean --dry "$FIX4" >/dev/null 2>&1
[ -f "$FIX4/ai_junk.tmp" ]; chk $? "T17 ai dry-run不动文件"

echo "== T18 ai_clean 真清理 =="
OUT=$(sh "$A" ai_clean "$FIX4" 2>&1)
[ ! -f "$FIX4/ai_junk.tmp" ] && echo "$OUT" | grep -q 'recycled=1'
chk $? "T18 AI判safe后回收"

echo "== T19 ReAct闭环 =="
OUT=$(sh "$A" react '报告/data磁盘使用率，给出已用G/总量G/百分比' 2>&1)
echo "$OUT" | grep -q 'sherry' && echo "$OUT" | grep -qE '[0-9]+([.,][0-9]+)? ?G'
chk $? "T19 ReAct自主取数并FINAL"

echo "== T20 dispatch派活 =="
OUT=$(sh "$A" dispatch '用一句话报告当前回收站累计回收件数' 2>&1)
echo "$OUT" | grep -q 'sherry' && echo "$OUT" | grep -qE '[0-9]'
chk $? "T20 dispatch走ReAct出结果"

echo "== T21 ReAct非法JSON修复调用 =="
. "$K/lib/98_react.sh"
OUT=$(react_exec 'mcp:sherry_status|{x:1}')
echo "$OUT" | grep -q 'sherry'
chk $? "T21 非法JSON修复后轻量工具调用成功"

echo "== T22 工作室落地 =="
ST='/storage/emulated/0/雪莉工作室'
sh "$A" deep_scan "$FIX3" >/dev/null 2>&1
[ -f "$ST/日志/sherry.log" ] && ls "$ST/运行状态/" 2>/dev/null | grep -q 'count'
chk $? "T22 日志与运行状态在工作室"

echo "== T23 非法JSON修复器 =="
OUT=$(printf '%s' '{path:/data}' | "$PY" "$K/lib/json_repair.py" 2>/dev/null)
echo "$OUT" | grep -q '"path"' && echo "$OUT" | grep -q '/data'
chk $? "T23 非法JSON修复为合法参数"

echo "== T24 15类+回收站目录 =="
sh "$A" auto_classify --dry --skip-root >/dev/null 2>&1
C=0
for c in 01-安装包 02-音乐 03-视频 04-图片 05-文档 06-压缩包 07-电子书 08-字体 09-代码脚本 10-种子 11-镜像 12-录音 13-数据库 14-配置备份 15-其他 回收站; do
  [ -d "/storage/emulated/0/分类文件夹/$c" ] || C=1
done
chk $C "T24 15类+回收站齐全"

echo "== T25 分类映射 =="
. "$K/lib/70_classify.sh"
M=0
[ "$(classify_cat x.apk)" = '01-安装包' ] || M=1
[ "$(classify_cat x.mp3)" = '02-音乐' ] || M=1
[ "$(classify_cat x.pdf)" = '05-文档' ] || M=1
[ "$(classify_cat x.unknown)" = '15-其他' ] || M=1
chk $M "T25 扩展名映射正确"

echo "== T26 分类dry-run不动文件 =="
CLS=/data/local/tmp/sherry_cls_$
mkdir -p "$CLS"
echo a > "$CLS/a.apk"; echo b > "$CLS/b.mp3"; echo c > "$CLS/c.pdf"; echo d > "$CLS/d.xyz"
sh "$A" auto_classify --dry --src "$CLS" --skip-root >/dev/null 2>&1
[ -f "$CLS/a.apk" ] && [ -f "$CLS/b.mp3" ]
chk $? "T26 dry-run文件仍在原处"

echo "== T27 真分类入类+manifest =="
sh "$A" auto_classify --src "$CLS" --skip-root >/dev/null 2>&1
CF='/storage/emulated/0/分类文件夹'
[ -f "$CF/01-安装包/a.apk" ] && [ -f "$CF/02-音乐/b.mp3" ] && [ -f "$CF/05-文档/c.pdf" ] && [ -f "$CF/15-其他/d.xyz" ] && grep -q 'a.apk' "$CF/分类manifest.tsv"
chk $? "T27 四类文件入正确分类且留痕"

echo "== T28 分类可恢复 =="
sh "$A" restore_classify 4 >/dev/null 2>&1
[ -f "$CLS/a.apk" ] && [ -f "$CLS/b.mp3" ] && [ -f "$CLS/c.pdf" ] && [ -f "$CLS/d.xyz" ]
chk $? "T28 恢复回原路径"

echo "== T29 回收站在分类文件夹可见 =="
echo j > "$CLS/junk.tmp"
. "$K/lib/00_core.sh"
. "$K/lib/10_safety.sh"
safe_rm "$CLS/junk.tmp"
[ ! -f "$CLS/junk.tmp" ] && [ -n "$(find "$CF/回收站" -name 'junk.tmp' 2>/dev/null)" ]
chk $? "T29 回收文件落入可见回收站"

echo "== T30 自主清理管线 =="
sh -n "$K/sherry_autoclean.sh" && OUT=$(sh "$A" auto --dry --skip-root 2>&1)
echo "$OUT" | grep -q 'classify dry-run'
chk $? "T30 auto管线dry-run通过"

echo "== T31-T33 回收站30天保留期 =="
. "$K/lib/00_core.sh"
. "$K/lib/10_safety.sh"
OLDTS=$(date -d "@$(( $(date +%s) - 31*86400 ))" +%y%m%d-%H%M%S)
NOWTS=$(date +%y%m%d-%H%M%S)
mkdir -p "$SK_RECYCLE/rt_old" "$SK_RECYCLE/rt_new"
echo o > "$SK_RECYCLE/rt_old/old.tmp"
echo n > "$SK_RECYCLE/rt_new/new.tmp"
printf '%s\t/data/local/tmp/rt_old.tmp\t%s\n' "$OLDTS" "$SK_RECYCLE/rt_old/old.tmp" >> "$SK_RECYCLE/manifest.tsv"
printf '%s\t/data/local/tmp/rt_new.tmp\t%s\n' "$NOWTS" "$SK_RECYCLE/rt_new/new.tmp" >> "$SK_RECYCLE/manifest.tsv"
sh "$A" recycle_retention --dry >/dev/null 2>&1
[ -f "$SK_RECYCLE/rt_old/old.tmp" ]; chk $? "T31 保留期dry-run不删"
sh "$A" recycle_retention >/dev/null 2>&1
[ ! -f "$SK_RECYCLE/rt_old/old.tmp" ] && [ -f "$SK_RECYCLE/rt_new/new.tmp" ]; chk $? "T32 超期清除未超期保留"
grep -q 'rt_old' "$SK_LOGS/recycle_retention_purge.tsv" 2>/dev/null && ! grep -q 'rt_old' "$SK_RECYCLE/manifest.tsv" 2>/dev/null; chk $? "T33 审计留痕且manifest更新"
rm -rf "$SK_RECYCLE/rt_new"
grep -v 'rt_new' "$SK_RECYCLE/manifest.tsv" > "$SK_RECYCLE/.m_tmp" 2>/dev/null && mv "$SK_RECYCLE/.m_tmp" "$SK_RECYCLE/manifest.tsv"

echo "== T34 ReAct联网调研 =="
OUT=$(sh "$A" dispatch '用web_search搜索一加Ace6的电池容量，把搜到的具体mAh数字告诉我' 2>&1)
echo "$OUT" | grep -q 'sherry' && echo "$OUT" | grep -qE '[0-9]{4}'
chk $? "T34 ReAct自主联网搜索出数据"

rm -rf "$FIX" "$FIX2" "$FIX3" "$FIX4" "$CLS" 2>/dev/null
echo "─────"
echo "PASS=$PASS FAIL=$FAIL"
[ $FAIL = 0 ]
