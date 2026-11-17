#!/system/bin/sh
# [签名] jarsigner 校验APK签名 · 261101重建（原脚本丢失，按插件cmd语义重建）
# 被source调用: mt_sign.sh verify <APK路径>
case "$1" in
  verify)
    APK="$2"
    [ -z "$APK" ] && { echo '用法: verify <APK路径>'; exit 1; }
    [ -f "$APK" ] || { echo "文件不存在: $APK"; exit 1; }
    /data/data/com.termux/files/usr/bin/jarsigner -verify -verbose:summary -certs "$APK" 2>&1 | tail -40
    ;;
  *) echo "mt_sign.sh: 未知子命令 $1 (支持: verify)"; exit 1;;
esac
