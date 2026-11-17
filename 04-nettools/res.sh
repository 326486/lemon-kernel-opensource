#!/system/bin/sh
# 资源中心通用访问器 v1 · 小柠檬1号分身 20260920
# 用法: res.sh <域> <操作> [参数...]
# 域: mem=记忆中心 repo=仓库中心 learn=学习中心 mcp=/data/mcp源码 kern=内核源码
case "$1" in
  mem)   BASE=/data/小柠檬资源/小柠檬记忆中心 ;;
  repo)  BASE=/data/小柠檬资源/小柠檬仓库中心 ;;
  learn) BASE=/data/小柠檬资源/小柠檬记忆中心/小柠檬学习中心 ;;
  mcp)   BASE=/data/mcp源码 ;;
  kern)  BASE=/data/mcp源码/内核源码 ;;
  *) echo "未知域: $1 (可选 mem/repo/learn/mcp/kern)"; exit 1 ;;
esac
DOMAIN="$1"; OP="$2"; shift 2
case "$OP" in
  list)
    P="$1"; [ -z "$P" ] && P="."
    echo "[域=$DOMAIN]"
    ls -la "$BASE/$P" 2>&1 ;;
  read)
    P="$1"; L="$2"; [ -z "$L" ] && L=200
    [ -f "$BASE/$P" ] || { echo "无此文件: $P"; exit 1; }
    head -n "$L" "$BASE/$P" ;;
  write)
    P="$1"; C="$2"
    [ -z "$P" ] && { echo "需文件路径"; exit 1; }
    mkdir -p "$(dirname "$BASE/$P")"
    printf '%s' "$C" > "$BASE/$P" && echo "OK 已写 $P ($(wc -c < "$BASE/$P") 字节)" ;;
  find)
    K="$1"; [ -z "$K" ] && { echo "需关键词"; exit 1; }
    find "$BASE" -iname "*$K*" 2>/dev/null | head -100 ;;
  grep)
    K="$1"; [ -z "$K" ] && { echo "需关键词"; exit 1; }
    grep -rn -i "$K" "$BASE" 2>/dev/null | head -120 ;;
  du)
    du -sh "$BASE" 2>&1; echo "--- 一级占用 ---"; du -sh "$BASE"/* 2>/dev/null | sort | tail -20 ;;
  *) echo "未知操作: $OP (list/read/write/find/grep/du)"; exit 1 ;;
esac
