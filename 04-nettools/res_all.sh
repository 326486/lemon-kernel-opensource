#!/system/bin/sh
# 资源中心跨域调度 v1 · 小柠檬1号分身 20260920
R="/data/adb/lemon_kernel/lemon/res/res.sh"
case "$1" in
  grep)
    K="$2"; [ -z "$K" ] && { echo "需关键词"; exit 1; }
    for d in mem repo learn mcp kern; do
      echo "########## [$d] ##########"
      sh $R $d grep "$K"
    done ;;
  overview)
    for d in mem:记忆中心 repo:仓库中心 learn:学习中心 mcp:MCP源码 kern:内核源码; do
      dd=${d%%:*}; cn=${d##*:}
      echo "########## $cn ($dd) ##########"
      sh $R $dd du
    done ;;
  *) echo "用法: res_all.sh grep <kw> | overview"; exit 1 ;;
esac
