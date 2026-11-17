#!/system/bin/sh
# ============================================================
# lemon_netx.sh v1.0 · 网络增强（一键诊断 / WiFi 配置）
# 20261001 · 小柠檬本体
# 用法: lemon_netx.sh {diagnose|wifi}
# ============================================================
clean(){ case "$1" in \$*) printf '' ;; *) printf '%s' "$1" ;; esac; }
BBS=/data/adb/magisk/busybox
gw_of(){ ip route get 223.5.5.5 2>/dev/null | sed -n 's/.*via \([0-9.]*\).*/\1/p' | head -n 1; }

do_diagnose(){
  printf '===== 📡 网络一键诊断 %s =====\n' "$(date '+%F %T')"
  GW=$(gw_of)
  printf '\n-- 1) 接口与地址 --\n'
  ip -o -4 addr show 2>/dev/null | awk '{printf "  %-14s %s\n", $2, $4}' | head -n 8
  printf '\n-- 2) 默认路由 --\n'
  printf '  网关: %s\n' "${GW:-未识别}"
  ip route get 223.5.5.5 2>/dev/null | sed 's/^/  /' | head -n 1
  printf '\n-- 3) DNS --\n'
  dns=$(getprop 2>/dev/null | grep -E 'net\.dns[0-9]' | sed 's/^/  /' | head -n 4)
  if [ -n "$dns" ]; then printf '%s\n' "$dns"; else printf '  (无 net.dns 属性，用系统解析器验证)\n  '; if [ -x "$BBS" ]; then "$BBS" nslookup www.baidu.com 2>&1 | grep -E 'Address|Name' | head -n 3 | tr '\n' ' '; fi; printf '\n'; fi
  printf '\n-- 4) 网关连通 (3 包) --\n'
  if [ -n "$GW" ]; then ping -c 3 -W 2 "$GW" 2>/dev/null | tail -n 3 | sed 's/^/  /'; else printf '  跳过(无网关)\n'; fi
  printf '\n-- 5) 公网连通 223.5.5.5 (3 包) --\n'
  ping -c 3 -W 2 223.5.5.5 2>/dev/null | tail -n 3 | sed 's/^/  /'
  printf '\n-- 6) DNS 解析 --\n'
  if [ -x "$BBS" ]; then "$BBS" nslookup www.baidu.com 223.5.5.5 2>&1 | grep -E 'Address|Name|server' | head -n 5 | sed 's/^/  /'; else printf '  (busybox 不可用)\n'; fi
  printf '\n-- 7) HTTP 可达性与延迟 --\n'
  for u in https://www.baidu.com https://223.5.5.5; do
    r=$(curl -s -o /dev/null -m 6 -w '%{http_code}  %{time_total}s' "$u" 2>/dev/null)
    printf '  %-26s %s\n' "$u" "${r:-失败}"
  done
  printf '\n-- 8) 连接概览 --\n'
  ss -s 2>/dev/null | sed 's/^/  /' | head -n 6
  [ -z "$(ss -s 2>/dev/null | head -n 1)" ] && cat /proc/net/sockstat 2>/dev/null | sed 's/^/  /'
  printf '\n-- 9) 本机监听端口 --\n'
  ss -ltn 2>/dev/null | grep LISTEN | awk '{print $4}' | sort -u | sed 's/^/  /' | head -n 20
  printf '\n===== 诊断结束 =====\n'
}

do_wifi(){
  printf '===== 📶 WiFi 配置导出 %s =====\n' "$(date '+%F %T')"
  found=0
  for f in /data/misc/apexdata/com.android.wifi/WifiConfigStore.xml \
           /data/misc/wifi/WifiConfigStore.xml \
           /data/misc/wifi/wpa_supplicant.conf \
           /data/vendor/wifi/wpa/wpa_supplicant.conf; do
    [ -r "$f" ] || continue
    found=1
    printf '\n## %s\n' "$f"
    grep -o -E '<string name="SSID">[^<]*|<string name="PreSharedKey">[^<]*|ssid="[^"]*|psk="[^"]*|network=\{' "$f" 2>/dev/null \
      | sed 's/<string name="//; s/">/ = /; s/&quot;/"/g; s/&amp;/\&/g; s/&lt;/</g; s/&gt;/>/g' | head -n 80 | sed "s/^/  /"
  done
  if [ "$found" -eq 0 ]; then printf '  （未找到可读的 WiFi 配置；Android 高版本多为加密存储）\n'; fi
  printf '\n-- 当前连接 --\n'
  dumpsys wifi 2>/dev/null | grep -E 'mWifiInfo|SSID:|BSSID|Link speed' | head -n 6 | sed 's/^/  /'
  printf '\n-- 已保存网络数 --\n'
  dumpsys wifi 2>/dev/null | grep -c 'SSID=' | sed 's/^/  /'
}

case "$1" in
  diagnose) do_diagnose ;;
  wifi)     do_wifi ;;
  *) printf '用法: lemon_netx.sh {diagnose|wifi}\n' ;;
esac
