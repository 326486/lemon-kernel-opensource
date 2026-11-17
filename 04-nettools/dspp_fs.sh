#!/system/bin/sh
# DeepSeek++ 文件工作区适配层 · 小柠檬1号分身 20260921
# 用法: dspp_fs.sh <op> [args...]
WS="/storage/emulated/0/小柠檬通用文件夹/dspp_workspace"
mkdir -p "$WS" 2>/dev/null

resolve() {
  case "$1" in
    /*) echo "$1" ;;
    "") echo "$WS" ;;
    *) echo "$WS/$1" ;;
  esac
}

OP="$1"; shift

case "$OP" in
  info)
    echo "工作区根: $WS"
    echo "文件数: $(find "$WS" -type f 2>/dev/null | wc -l)"
    echo "目录数: $(find "$WS" -type d 2>/dev/null | wc -l)"
    echo "占用:   $(du -sh "$WS" 2>/dev/null | cut -f1)"
    echo "--- 顶层 ---"
    ls -la "$WS" 2>&1 | head -30
    ;;
  list)
    P=$(resolve "$1")
    [ -e "$P" ] || { echo "[err] 路径不存在: $P"; exit 1; }
    ls -la "$P" 2>&1 | head -200
    ;;
  read)
    P=$(resolve "$1")
    [ -f "$P" ] || { echo "[err] 文件不存在: $P"; exit 1; }
    sz=$(wc -c < "$P" 2>/dev/null)
    echo "[file=$P size=$sz]"
    head -c 262144 "$P" 2>&1
    ;;
  write)
    P=$(resolve "$1"); C="$2"
    mkdir -p "$(dirname "$P")" 2>/dev/null
    printf '%s' "$C" > "$P" && echo "[ok] 已写入 $P ($(wc -c < "$P") 字节)"
    ;;
  append)
    P=$(resolve "$1"); C="$2"
    mkdir -p "$(dirname "$P")" 2>/dev/null
    printf '%s' "$C" >> "$P" && echo "[ok] 已追加 $P ($(wc -c < "$P") 字节)"
    ;;
  mkdir)
    P=$(resolve "$1")
    mkdir -p "$P" && echo "[ok] 已创建目录 $P"
    ;;
  find)
    K="$1"
    if [ -z "$K" ]; then find "$WS" -maxdepth 6 2>/dev/null | head -200
    else find "$WS" -maxdepth 6 -iname "*$K*" 2>/dev/null | head -200; fi
    ;;
  *)
    echo "[err] 未知操作: $OP"; exit 2 ;;
esac
