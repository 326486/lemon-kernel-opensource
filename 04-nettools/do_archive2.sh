#!/system/bin/sh
# 立规归档：8号库#153规则条目 + 学习中心L-386立规记录
set -u
M=$LEMON_DATA/小柠檬记忆中心
L=$M/小柠檬学习中心
TSV=$L/_索引/编号索引.tsv
CAT=$L/_本库目录.md
DOC="$L/08-总结篇/20261113-任务双归档与前置读取规则立规记录.md"

echo "==1.记忆中心8号库建条目=="
sh "$M/_索引/mem_new.sh" new 8 "任务双归档与前置读取规则（lemon-user261113指令）" /data/local/tmp/rule_body_153.md 261113

echo "==2.学习中心L-386索引与目录=="
BYTES=$(wc -c < "$DOC")
echo "doc_bytes=$BYTES"
[ "$BYTES" -lt 300 ] && { echo "ABORT: 文档过小"; exit 1; }
if grep -q "^L-386" "$TSV"; then
  echo "L-386已在索引"
else
  printf 'L-386\t任务双归档与前置读取规则立规记录\t08-总结篇\t261113\t08-总结篇/20261113-任务双归档与前置读取规则立规记录.md\t%s\n' "$BYTES" >> "$TSV"
  echo "索引已追加"
fi
LAST=$(grep -oE '^\| L-[0-9]+' "$CAT" | grep -oE '[0-9]+' | sort -n | tail -1)
awk -F'\t' -v last="$LAST" '{ n=substr($1,3)+0; if(n>last) printf "| %s | %s | %s | %s | %s | %s |\n",$1,$2,$3,$4,$5,$6 }' "$TSV" >> "$CAT"
TOTAL=$(grep -c '^L-' "$TSV")
sed -i "s/更新 [0-9]*/更新 261113/; s/共 [0-9]* 条/共 $TOTAL 条/" "$CAT"
for c in 01-改造案例 02-技术经验 03-工具与命令 04-踩坑与风险 05-资料与索引 06-学习篇 07-复习篇 08-总结篇 09-考试篇 根; do
  N=$(awk -F'\t' -v c="$c" '$3==c' "$TSV" | wc -l)
  [ "$N" -gt 0 ] && sed -i "s/^| $c | [0-9]* |/| $c | $N |/" "$CAT"
done
echo "目录已同步: 共 $TOTAL 条"

echo "==3.回读验证=="
sh "$L/_索引/取.sh" L-386 | head -3
find "$M/小柠檬8号规则总库/条目" -name "*153*" 2>/dev/null | head -2
echo "==DONE=="