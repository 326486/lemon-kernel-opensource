#!/system/bin/sh
# 30_storage.sh — 磁盘/健康分
sk_disk(){
  _d=$(df -k /data 2>/dev/null | awk 'NR==2{printf "%.1f %.1f %d", $3/1048576, $2/1048576, $5+0}')
  [ -n "$_d" ] || _d="0.0 0.0 0"
  echo "$_d"
}

sk_health(){
  set -- $(sk_disk)
  _p="${3:-50}"
  echo $((100 - _p / 2))
}
