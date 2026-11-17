#!/system/bin/sh
# ============================================================
# lemonlib · snap —— 快照管理（create / restore / list / diff）
#  2026-09-28 小柠檬本体
#  遵循 #230：备份先行 / 非空校验 / 回读验证
#
# 用法: snap.sh <action> [path] [label]
#   create  <路径> <标签>   打包快照到备份仓库
#   restore <标签>          从快照恢复（先备份现场）
#   list                    列出所有快照
#   diff    <标签>          对比现况与快照
# ============================================================
ACT="$1"
ARG2="$2"
ARG3="$3"
REPO=/data/小柠檬资源/8788内核专用备份仓库/lemonlib_snapshots
mkdir -p "$REPO"

ts() { date '+%Y%m%d_%H%M%S'; }

case "$ACT" in
create)
  SRC="$ARG2"; LABEL="${ARG3:-snap}"
  [ -z "$SRC" ] && { echo "!! 缺少路径。用法: snap create <路径> <标签>"; exit 1; }
  [ -e "$SRC" ] || { echo "!! 路径不存在: $SRC"; exit 1; }
  NAME="${LABEL}_$(ts)"
  DST="$REPO/$NAME"
  mkdir -p "$DST"
  echo "=================================================="
  echo " 创建快照: $NAME"
  echo " 源: $SRC"
  echo "=================================================="
  # 打包（保留属性）
  BASE=$(basename "$SRC")
  tar czf "$DST/data.tar.gz" -C "$(dirname "$SRC")" "$BASE" 2>/dev/null
  [ -s "$DST/data.tar.gz" ] || { echo "!! 打包失败"; exit 1; }
  # 清单
  find "$SRC" -type f -exec md5sum {} \; 2>/dev/null | sort -k2 > "$DST/md5sums.txt"
  {
    echo "label=$LABEL"
    echo "source=$SRC"
    echo "time=$(date '+%F %T')"
    echo "files=$(find "$SRC" -type f | wc -l)"
    echo "bytes=$(du -sb "$SRC" 2>/dev/null | cut -f1)"
    echo "tar_md5=$(md5sum "$DST/data.tar.gz" | cut -d' ' -f1)"
  } > "$DST/manifest.txt"
  echo
  echo "[结果]"
  cat "$DST/manifest.txt"
  echo
  echo "包大小: $(du -h "$DST/data.tar.gz" | cut -f1)"
  echo "清单行数: $(wc -l < "$DST/md5sums.txt")"
  echo "位置: $DST"
  echo "=================================================="
  ;;

restore)
  NAME="$ARG2"
  [ -z "$NAME" ] && { echo "!! 缺少标签。用法: snap restore <标签>"; exit 1; }
  SNAP="$REPO/$NAME"
  [ -d "$SNAP" ] || { 
    echo "!! 快照不存在: $NAME"; echo "   可用快照:"; ls "$REPO" 2>/dev/null | sed 's/^/     /'; exit 1; }
  SRC=$(grep '^source=' "$SNAP/manifest.txt" | cut -d= -f2-)
  echo "=================================================="
  echo " 从快照恢复: $NAME"
  echo " 目标: $SRC"
  echo "=================================================="
  # 备份现场（#230）
  NOW="$REPO/现场备份_$(ts)"
  if [ -e "$SRC" ]; then
    mkdir -p "$NOW"
    tar czf "$NOW/before.tar.gz" -C "$(dirname "$SRC")" "$(basename "$SRC")" 2>/dev/null
    echo "[1] 已备份现场 -> $NOW/before.tar.gz ($(du -h "$NOW/before.tar.gz" | cut -f1))"
  else
    echo "[1] 目标不存在，将新建"
  fi
  # 解包
  echo "[2] 解包恢复..."
  tar xzf "$SNAP/data.tar.gz" -C "$(dirname "$SRC")" 2>/dev/null
  rc=$?
  echo "    解包返回码: $rc"
  [ "$rc" != "0" ] && { echo "!! 恢复失败"; exit 1; }
  # 回读校验
  echo "[3] 回读校验（md5 比对）..."
  bad=$(cd / && md5sum -c "$SNAP/md5sums.txt" 2>/dev/null | grep -c 'FAILED')
  total=$(wc -l < "$SNAP/md5sums.txt")
  echo "    校验 $total 个文件，不一致 $bad 个"
  if [ "$bad" = "0" ]; then
    echo
    echo "[结果] 恢复成功 ✅（全部文件 md5 一致）"
  else
    echo
    echo "[结果] ⚠️ 有 $bad 个文件不一致"
  fi
  echo "现场备份保留在: $NOW"
  echo "=================================================="
  ;;

list)
  echo "=================================================="
  echo " 快照列表  ($REPO)"
  echo "=================================================="
  n=0
  for d in "$REPO"/*/; do
    [ -d "$d" ] || continue
    base=$(basename "$d")
    case "$base" in
      现场备份_*) continue ;;
    esac
    n=$((n+1))
    echo
    echo "  [$n] $base"
    [ -f "$d/manifest.txt" ] && sed 's/^/       /' "$d/manifest.txt"
  done
  [ "$n" = "0" ] && echo "  （暂无快照）"
  echo
  echo "  合计: $n 个快照"
  # 现场备份单独列
  nb=$(ls -d "$REPO"/现场备份_* 2>/dev/null | wc -l)
  [ "$nb" -gt 0 ] && echo "  另有 $nb 份现场备份"
  echo "=================================================="
  ;;

diff)
  NAME="$ARG2"
  SNAP="$REPO/$NAME"
  [ -d "$SNAP" ] || { echo "!! 快照不存在: $NAME"; exit 1; }
  SRC=$(grep '^source=' "$SNAP/manifest.txt" | cut -d= -f2-)
  echo "=================================================="
  echo " 对比: $NAME  vs  现况"
  echo " 目标: $SRC"
  echo "=================================================="
  # 现况 md5
  find "$SRC" -type f -exec md5sum {} \; 2>/dev/null | sort -k2 > /data/local/tmp/snap_now.txt 2>/dev/null
  echo
  echo "[1] 文件数"
  echo "  快照: $(wc -l < "$SNAP/md5sums.txt")"
  echo "  现况: $(wc -l < /data/local/tmp/snap_now.txt)"
  echo
  echo "[2] 差异（现况 vs 快照）"
  d=$(diff "$SNAP/md5sums.txt" /data/local/tmp/snap_now.txt 2>/dev/null)
  if [ -z "$d" ]; then
    echo "  ✅ 完全一致"
  else
    echo "$d" | grep '^<' | head -10 | sed 's/^</  删除或改动: /'
    echo "$d" | grep '^>' | head -10 | sed 's/^>/  新增或改动: /'
    echo "  （差异行数: $(echo "$d" | wc -l)）"
  fi
  echo "=================================================="
  ;;

*)
  echo "lemonlib · snap —— 快照管理"
  echo
  echo "用法:"
  echo "  snap create  <路径> <标签>   创建快照"
  echo "  snap restore <标签>          恢复（先自动备份现场）"
  echo "  snap list                    列出快照"
  echo "  snap diff    <标签>          对比现况"
  echo
  echo "仓库: $REPO"
  ;;
esac
