#!/system/bin/sh
# X浏览器控制台 · 261101重建
# reload: 发送F5刷新（需X浏览器在前台）
case "$1" in
  reload) input keyevent 135 && echo '已发送刷新键(F5)';;
  *) echo 'xbcdp.sh: 支持 reload';;
esac
