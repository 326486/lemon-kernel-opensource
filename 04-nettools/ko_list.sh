#!/system/bin/sh
# ============================================================
# lemonlib · ko_list —— 内核模块一览（含参数与第三方识别）
# ============================================================
echo "=================================================="
echo " 内核模块清单  $(date '+%F %T')"
echo "=================================================="
echo
echo "[内核] $(uname -r)"
echo "[总数] $(wc -l < /proc/modules) 个已加载"
echo

echo "----- 第三方 / 自研模块（重点）-----"
found=0
while read -r name size refs deps state addr rest; do
  case "$name" in
    lemon_guard|lemon*|hello*|kpatch*|kpm*|sherry*|tricky*|shamiko*|zygisk*)
      echo "  ★ $name"
      echo "      大小=${size}B  引用=$refs  状态=$state"
      [ "$deps" != "-" ] && echo "      依赖=$deps"
      # 模块参数
      if [ -d "/sys/module/$name/parameters" ]; then
        echo -n "      参数: "
        for p in /sys/module/$name/parameters/*; do
          [ -e "$p" ] || continue
          echo -n "$(basename $p)=$(cat $p 2>/dev/null | head -c 40)  "
        done
        echo
      fi
      # 版本信息
      [ -f "/sys/module/$name/version" ] && echo "      版本=$(cat /sys/module/$name/version)"
      [ -f "/sys/module/$name/srcversion" ] && echo "      源码版本=$(cat /sys/module/$name/srcversion)"
      found=$((found+1))
      ;;
  esac
done < /proc/modules

[ "$found" = "0" ] && echo "  （无自研/第三方模块）"
echo
echo "  小计: $found 个自研/第三方模块"
echo

echo "----- 全部模块（按引用数排序前 15）-----"
tail -n +1 /proc/modules | sort -k3 -rn | head -15 | awk '{printf "  %-28s %8s  refs=%s\n", $1, $2, $3}'
echo
echo "----- 内核污染 -----"
t=$(cat /proc/sys/kernel/tainted)
echo "  tainted=$t"
[ "$t" = "0" ] && echo "  (干净)" || echo "  (含非官方模块/其他标记，位含义见 dmesg)"
echo
echo "----- 可用第三方 .ko 文件（仓库中）-----"
ls -la /data/adb/lemonguard/*.ko 2>/dev/null | awk '{print "  " $9 " (" $5 "B)"}'
ls -la /data/adb/lemoncar/*.ko 2>/dev/null | awk '{print "  " $9}'
echo "=================================================="
