#!/system/bin/sh
# 学习中心L-385归档 + 记忆中心5号库#240建条目（一次性，含校验）
set -u
M=$LEMON_DATA/小柠檬记忆中心
L=$M/小柠檬学习中心
TSV=$L/_索引/编号索引.tsv
CAT=$L/_本库目录.md
DOC=$L/01-改造案例/20261113-小柠檬内核免费网络工具批量接入.md

echo "==1.文档字节校验=="
BYTES=$(wc -c < "$DOC")
echo "doc_bytes=$BYTES"
[ "$BYTES" -lt 1000 ] && { echo "ABORT: 文档过小，写入可能失败"; exit 1; }

echo "==2.追加学习中心索引=="
if grep -q "^L-385" "$TSV"; then
  echo "L-385已在索引，跳过"
else
  printf 'L-385\t小柠檬内核免费网络工具批量接入（13工具落地全记录）\t01-改造案例\t261113\t01-改造案例/20261113-小柠檬内核免费网络工具批量接入.md\t%s\n' "$BYTES" >> "$TSV"
  echo "已追加"
fi
tail -1 "$TSV"

echo "==3.同步学习中心目录=="
LAST=$(grep -oE '^\| L-[0-9]+' "$CAT" | grep -oE '[0-9]+' | sort -n | tail -1)
echo "目录当前最大编号: L-$LAST"
awk -F'\t' -v last="$LAST" '{ n=substr($1,3)+0; if(n>last) printf "| %s | %s | %s | %s | %s | %s |\n",$1,$2,$3,$4,$5,$6 }' "$TSV" >> "$CAT"
TOTAL=$(grep -c '^L-' "$TSV")
sed -i "s/更新 [0-9]*/更新 261113/; s/共 [0-9]* 条/共 $TOTAL 条/" "$CAT"
for c in 01-改造案例 02-技术经验 03-工具与命令 04-踩坑与风险 05-资料与索引 06-学习篇 07-复习篇 08-总结篇 09-考试篇 根; do
  N=$(awk -F'\t' -v c="$c" '$3==c' "$TSV" | wc -l)
  [ "$N" -gt 0 ] && sed -i "s/^| $c | [0-9]* |/| $c | $N |/" "$CAT"
done
echo "目录已同步: 共 $TOTAL 条"
head -4 "$CAT" | tail -1

echo "==4.记忆中心5号库建条目=="
sh "$M/_索引/mem_new.sh" new 5 "小柠檬内核inet_免费网络工具接入要点" /data/local/tmp/mem_body_inet.md 261113

echo "==5.回读验证=="
sh "$L/_索引/取.sh" L-385 | head -3
echo "---"
ls "$M/小柠檬5号记忆库/条目/" | grep -i "inet" | head -3
echo "==DONE=="