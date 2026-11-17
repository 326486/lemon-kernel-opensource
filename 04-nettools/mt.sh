#!/system/bin/sh
# mt.sh v3 · MT 底座引擎桥（取长补短计划 #566 · 261030 P2）
# LemonCore 以 root 调起；参数经环境变量传入（#572 铁律）
# 引擎：MT_ENG = dex|axml|arsc|apk（默认 dex）
# 子命令：MT_CMD（默认 info） 关键词：MT_KW 输出：MT_OUT
P=/data/data/com.termux/files/usr/bin
PY=$P/python3
DIR=/data/adb/lemon_kernel/lemon/mt

case "$MT_ENG" in
  axml)  ENG=$DIR/mt_axml.py ;;
  arsc)  ENG=$DIR/mt_arsc.py ;;
  apk)   ENG=$DIR/mt_apk.py ;;
  dex|*) ENG=$DIR/mt_dex.py ;;
esac

CMD=${MT_CMD:-info}
KW=${MT_KW:-}
OUT=${MT_OUT:-}

if [ -z "$MT_PATH" ]; then
  echo "ERR 缺少 MT_PATH（引擎路径参数）"
  exit 2
fi
if [ ! -f "$MT_PATH" ]; then
  echo "ERR 文件不存在：$MT_PATH"
  exit 3
fi

# xor 子命令参数序：<in> <out>（不走 KW）
if [ "$CMD" = "xor" ]; then
  if [ -z "$OUT" ]; then
    echo "ERR xor 需要 MT_OUT（输出 .dex 路径）"
    exit 4
  fi
  exec $PY $ENG xor "$MT_PATH" "$OUT"
fi

if [ -n "$KW" ]; then
  exec $PY $ENG "$CMD" "$MT_PATH" "$KW"
fi
exec $PY $ENG "$CMD" "$MT_PATH"