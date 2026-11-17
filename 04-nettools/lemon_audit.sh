#!/system/bin/sh
# ============================================================
# lemon_audit.sh v1.0 · 安全 / 权限 / 端口审计
# 20261001 · 小柠檬本体
# 用法: lemon_audit.sh {sec|perm [n]|ports}
# ============================================================
clean(){ case "$1" in \$*) printf '' ;; *) printf '%s' "$1" ;; esac; }
BBS=/data/adb/magisk/busybox

do_sec(){
  printf '===== 🛡 安全体检 %s =====\n' "$(date '+%F %T')"
  printf '\n-- 1) 基础环境 --\n'
  printf '  uid          : %s\n' "$(id -u 2>/dev/null)"
  printf '  SELinux      : %s\n' "$(getenforce 2>/dev/null)"
  printf '  ro.secure    : %s   ro.debuggable: %s\n' "$(getprop ro.secure)" "$(getprop ro.debuggable)"
  printf '  build.type   : %s\n' "$(getprop ro.build.type)"
  printf '  ADB          : %s   开发者模式: %s   ADB WiFi: %s\n' \
    "$(settings get global adb_enabled 2>/dev/null)" \
    "$(settings get global development_settings_enabled 2>/dev/null)" \
    "$(settings get global adb_wifi_enabled 2>/dev/null)"
  printf '\n-- 2) 锁屏 --\n'
  printf '  lockscreen.disabled : %s  (1=已禁用锁屏, 高危)\n' "$(settings get secure lockscreen.disabled 2>/dev/null)"
  printf '  凭证文件            : %s\n' "$(ls /data/system/*.key 2>/dev/null | tr '\n' ' ')"
  printf '\n-- 3) 设备管理员 (可远程锁机/擦除) --\n'
  dumpsys device_policy 2>/dev/null | grep -E 'admin=|Active admin' | head -n 8 | sed 's/^/  /'
  printf '\n-- 4) 无障碍服务 (可读屏/模拟点击) --\n'
  a=$(settings get secure enabled_accessibility_services 2>/dev/null)
  printf '  %s\n' "${a:-（无）}"
  printf '\n-- 5) Magisk 模块 (启用中) --\n'
  for m in /data/adb/modules/*/; do
    [ -d "$m" ] || continue
    [ -f "$m/disable" ] && continue
    [ -f "$m/remove" ] && continue
    printf '  ✔ %s\n' "$(basename "$m")"
  done
  [ -d /data/adb/modules ] || printf '  （无目录）\n'
  printf '\n-- 6) 内核模块 (lemon 系列 + 污染位) --\n'
  lsmod 2>/dev/null | grep -iE 'lemon|guard|protect' | sed 's/^/  /'
  printf '  tainted = %s\n' "$(cat /proc/sys/kernel/tainted 2>/dev/null)"
  printf '\n-- 7) 自启可疑项 (调用 bootaudit) --\n'
  sh /data/adb/lemon_kernel/lemonlib/lemon_boot.sh bootaudit 2>/dev/null | grep -E '^\s*\[[!?]\]' | head -n 10 | sed 's/^/  /'
  printf '\n-- 8) 对外暴露端口 --\n'
  sh /data/adb/lemon_kernel/lemonlib/lemon_audit.sh ports 2>/dev/null | sed -n '4,20p'
  printf '\n===== 体检结束 =====\n'
}

do_perm(){
  n=$(clean "$1"); [ -z "$n" ] && n=40
  printf '===== 🔐 权限审计 (前 %s 个第三方应用) %s =====\n' "$n" "$(date '+%T')"
  printf '敏感权限: 定位/相机/麦克风/通讯录/短信/通话/电话状态/传感器\n\n'
  pm list packages -3 2>/dev/null | sed 's/^package://' | head -n "$n" | while read -r p; do
    [ -z "$p" ] && continue
    out=$(dumpsys package "$p" 2>/dev/null | grep 'granted=true' \
      | grep -oE 'android\.permission\.[A-Z_]+' | sort -u \
      | grep -E 'FINE_LOCATION|COARSE_LOCATION|CAMERA|RECORD_AUDIO|READ_CONTACTS|READ_SMS|SEND_SMS|CALL_PHONE|READ_PHONE_STATE|READ_CALL_LOG|BODY_SENSORS|GET_ACCOUNTS' \
      | sed 's/android\.permission\.//g' | tr '\n' ' ')
    [ -n "$out" ] && printf '  %-44s %s\n' "$p" "$out"
  done
  printf '\n[提示] 越权/异常应用可用 app_freeze 或 pkg_disable_user 处置\n'
}

do_ports(){
  printf '===== 🌐 对外暴露端口审计 %s =====\n' "$(date '+%F %T')"
  printf '(非回环监听 = 局域网/外网可达)\n\n'
  ss -ltnp 2>/dev/null | grep LISTEN | grep -v -E '127\.0\.0\.1|\[::1\]' > /data/local/tmp/lemon_ports.txt
  if [ -s /data/local/tmp/lemon_ports.txt ]; then
    n=0
    while read -r l; do
      n=$((n+1))
      a=$(printf '%s' "$l" | awk '{print $4}')
      pr=$(printf '%s' "$l" | sed -n 's/.*users:((\"\([^\"]*\)\".*/\1/p')
      printf '  %-24s %s\n' "$a" "${pr:-?}"
    done < /data/local/tmp/lemon_ports.txt
    printf '\n共 %s 个对外监听\n' "$n"
  else
    printf '  （无对外监听 / ss 不可用）\n'
  fi
  printf '\n-- 本机所有监听 (含回环) --\n'
  ss -ltn 2>/dev/null | grep LISTEN | awk '{print "  " $4}' | sort -u | head -n 30
}

case "$1" in
  sec)   do_sec ;;
  perm)  do_perm "$2" ;;
  ports) do_ports ;;
  *) printf '用法: lemon_audit.sh {sec|perm [n]|ports}\n' ;;
esac
