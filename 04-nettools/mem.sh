#!/system/bin/sh
# ═══════════════════════════════════════════════════════
#  小柠檬记忆检索器 v2.4（每库独立编号版 · 261031）
#  v2.3 → v2.4：编号体系从「全局连续」改为「每库从1独立」：
#    1. get <N>     裸号先查新索引；唯一命中直给；多条歧义列候选；
#                   0 命中自动回落旧全局映射（旧引用 #174 等无缝兼容）
#    2. get <库:N>  新语法精确直达（8:15 / 8号:15 / 根:2）
#    3. old <O>     链式映射: 260929旧号→全局号→库内号
#    4. find/list 输出带库；stat 重号按「库+编号」口径
#  前版史: v2.3 get支持B<n> / v2.2 修LINES特殊变量 / v2.1 免临时文件
# ═══════════════════════════════════════════════════════
MEM=/data/小柠檬资源/小柠檬记忆中心
IDX=$MEM/_索引
TSV=$IDX/编号索引.tsv
MAP=$IDX/编号映射_旧到新.tsv          # 260929: 旧号→全局号
GMAP=$IDX/编号映射_全局到库内.tsv     # 261031: 全局号→库→库内号→路径

usage() {
cat <<'EOF'
用法: sh mem.sh <子命令>
  get <编号>              取单条全文。裸号: 唯一命中直给/歧义列候选/自动兼容旧全局号
  get <库:编号>           精确直达，如: get 8:15  get 8号:15  get 根:2
  old <旧编号>            旧号→全局号→库内号 链式映射
  find <关键词> [数量]    搜正文反查（默认15条）
  list [库] [起] [止]     列编号+标题（如: mem.sh list 8号 1 50）
  stat                    各库条数 + 库内编号健康度
  rebuild                 重建索引
EOF
}

# 库参数 → 索引里的库名（get 库:N 用）
libname() {
  case "$1" in
    1)      echo "小柠檬1号记忆库" ;;
    2)      echo "小柠檬2号小说专用库" ;;
    3)      echo "小柠檬3号记忆库" ;;
    4)      echo "小柠檬4号记忆库" ;;
    5)      echo "小柠檬5号记忆库" ;;
    6)      echo "小柠檬6号记忆库" ;;
    7)      echo "小柠檬7号记忆库" ;;
    8)      echo "小柠檬8号规则总库" ;;
    9)      echo "小柠檬9号记忆库" ;;
    R|根|根目录) echo "_根目录条目" ;;
    *)      echo "$1" ;;
  esac
}

show_file() {   # $1=路径 $2=展示头
  [ -f "$1" ] || { echo "!! 文件缺失: $1"; return 1; }
  echo "═══ $2 ═══"
  echo "文件: ${1#$MEM/}"
  echo "──────────────────────────────────────"
  cat "$1"
  echo
}

case "$1" in

  get)
    ARG="$2"
    [ -z "$ARG" ] && { usage; exit 1; }
    SRC="$TSV"; case "$ARG" in B*) SRC="$IDX/内置归档索引_B.tsv"; ARG="${ARG#B}";; esac
    [ -f "$SRC" ] || { echo "!! 索引不存在，先: sh mem.sh rebuild"; exit 1; }

    # ── 新语法 库:号 ──
    case "$ARG" in
      *:*)
        L=$(libname "${ARG%%:*}"); N="${ARG##*:}"
        case "$N" in ''|*[!0-9]*) echo "!! 编号须为数字"; exit 1;; esac
        P=$(awk -F'\t' -v n="$N" -v l="$L" '$1==n && $3==l {print $4; exit}' "$TSV")
        [ -z "$P" ] && { echo "!! $L 无库内编号 #$N"; exit 1; }
        show_file "$P" "$L ｜ #$N"
        ;;
      *)
        N="$ARG"
        # 优先旧全局号（历史引用 #174 等无缝兼容）
        ROW=$(awk -F'\t' -v g="$N" '$1==g {print $2"\t"$3"\t"$4; exit}' "$GMAP")
        if [ -n "$ROW" ]; then
          GK=$(printf '%s' "$ROW" | cut -f1); GN=$(printf '%s' "$ROW" | cut -f2); GP=$(printf '%s' "$ROW" | cut -f3)
          GL=$(libname "$GK")
          show_file "$GP" "$GL ｜ 库内 #$GN（旧全局 #$N）"
          CNT2=$(awk -F'\t' -v n="$N" '$1==n {c++} END{print c+0}' "$TSV")
          [ "$CNT2" -gt 0 ] && echo "ℹ️ 另有 $CNT2 个库存在库内编号 #$N，查它们用: get <库:$N>"
        else
          CNT=$(awk -F'\t' -v n="$N" '$1==n {c++} END{print c+0}' "$TSV")
          if [ "$CNT" -eq 1 ]; then
            P=$(awk -F'\t' -v n="$N" '$1==n {print $4; exit}' "$TSV")
            L=$(awk -F'\t' -v n="$N" '$1==n {print $3; exit}' "$TSV")
            show_file "$P" "$L ｜ #$N"
          elif [ "$CNT" -gt 1 ]; then
            echo "!! 库内编号 #$N 在 $CNT 个库存在，请 get <库:$N> 直达（无旧全局号对应）:"
            awk -F'\t' -v n="$N" '$1==n {printf "  get %s  %-40s [%s]\n", $3, $2, $3}' "$TSV"
          else
            echo "!! 未找到 #$N（库内/旧全局均无）；用 find <关键词> 或 old <旧编号>"
          fi
        fi
        ;;
    esac
    ;;

  old)
    O="$2"
    [ -z "$O" ] && { usage; exit 1; }
    # 先按全局号查；查不到再走 260929 旧映射
    ROW=$(awk -F'\t' -v g="$O" '$1==g {print $2"\t"$3"\t"$4; exit}' "$GMAP")
    if [ -z "$ROW" ]; then
      G=$(awk -F'\t' -v o="$O" '$1==o {print $2; exit}' "$MAP")
      [ -n "$G" ] && ROW=$(awk -F'\t' -v g="$G" '$1==g {print $2"\t"$3"\t"$4; exit}' "$GMAP")
    fi
    if [ -z "$ROW" ]; then echo "!! 旧编号 #$O 不在两级映射表里"; exit 1; fi
    GK=$(printf '%s' "$ROW" | cut -f1); GN=$(printf '%s' "$ROW" | cut -f2); GP=$(printf '%s' "$ROW" | cut -f3)
    echo "旧 #$O → $(libname "$GK") 库内 #$GN"
    awk -F'\t' -v n="$GN" -v l="$(libname "$GK")" '$1==n && $3==l {printf "  %s  [%s]\n", $2, $3}' "$TSV"
    ;;

  find)
    KW="$2"; LIM="${3:-15}"
    [ -z "$KW" ] && { usage; exit 1; }
    find "$MEM" -type f \( -path "*/条目/*#*.md" -o -path "*/_根目录条目/#*.md" \) -exec grep -l -e "$KW" {} + 2>/dev/null | sort | while IFS= read -r f; do
      n=$(basename "$f" | awk -F- 'NR==1{gsub(/^#/,"",$1); print $1}')
      case "$n" in ""|*[!0-9]*) continue ;; esac
      awk -F'\t' -v n="$n" -v p="$f" '$1==n && $4==p {printf "#%s\t[%s]\t%s\n", $1, $3, $2}' "$TSV"
    done | awk -F'\t' '!seen[$0]++' | head -n "$LIM"
    ;;

  list)
    LIB="$2"; LO="$3"; HI="$4"
    awk -F'\t' -v lib="$LIB" -v lo="$LO" -v hi="$HI" '
      { if (lib != "" && $3 !~ lib) next
        if (lo != "" && $1+0 < lo+0) next
        if (hi != "" && $1+0 > hi+0) next
        printf "#%-4s %-46s [%s]\n", $1, substr($2,1,42), $3 }
    ' "$TSV" | head -n 400
    ;;

  stat)
    echo "═══ 记忆中心 · 每库独立编号 健康度 ═══"
    printf "条目: %s 条 ｜ 索引: %s 字节\n" "$(wc -l < "$TSV")" "$(wc -c < "$TSV")"
    echo "── 各库分布（每库内部 1..N 连续为健康）──"
    awk -F'\t' '{c[$3]++} END{for (k in c) printf "  %-26s %s条\n", k, c[k]}' "$TSV" | sort
    echo "── 库内缺号（应无）──"
    awk -F'\t' '{print $3, $1}' "$TSV" | sort -k1,1 -k2,2n | awk '
      { if ($1!=lib) { lib=$1; prev=0 }
        if ($2 > prev+1) { for (i=prev+1; i<$2; i++) printf "  缺 %s #%d\n", lib, i }
        prev=$2 }'
    echo "── 库内重号（应无）──"
    awk -F'\t' '{print $3"\t"$1}' "$TSV" | sort | uniq -d | tr '\n' ' '; echo
    echo "── 映射表 ──"
    printf "  全局号→库内: %s 行 ｜ 260929旧→全局: %s 行\n" \
      "$(grep -c '^[0-9]' "$GMAP" 2>/dev/null)" "$(grep -c '^[0-9]' "$MAP" 2>/dev/null)"
    echo "── 内置归档区（B前缀 · 独立索引）──"
    [ -f "$IDX/内置归档索引_B.tsv" ] && printf "  内置条目: %s 条\n" "$(wc -l < "$IDX/内置归档索引_B.tsv")" || echo "  （B 索引不存在，跑 rebuild 生成）"
    ;;

  rebuild)
    sh "$IDX/rebuild.sh"
    ;;

  *)
    usage
    ;;
esac