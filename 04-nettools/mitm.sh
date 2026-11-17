#!/system/bin/sh
JP=/data/local/tmp/jdk_work/data/data/com.termux/files/usr
JAVA=$JP/lib/jvm/java-17-openjdk/bin/java
DIR=/data/local/tmp/lemon_mitm
CA=/data/adb/xiaoningmeng/LemonCA自签根证书/证书与私钥/lemon_ca_private.jks
export LD_LIBRARY_PATH=$JP/lib:$JP/lib/server:$JP/lib/jli:$DIR/libs
export PATH=$JP/lib/jvm/java-17-openjdk/bin:$JP/bin:$PATH
case "$1" in
  start)
    if ps -A 2>/dev/null | grep -q '[M]itmProxy'; then echo MITM_ALREADY_RUNNING; exit 0; fi
    cd $DIR
    nohup $JAVA --add-exports java.base/sun.security.x509=ALL-UNNAMED -cp $DIR MitmProxy "$CA" >> $DIR/mitm_run.log 2>&1 &
    sleep 8
    if ss -tlnp 2>/dev/null | grep -q ':8888'; then echo MITM_RUNNING; else echo MITM_FAIL; tail -30 $DIR/mitm_run.log; fi
    ;;
  stop) pkill -f MitmProxy 2>/dev/null && echo MITM_STOPPED || echo MITM_NOT_RUNNING ;;
  status) ss -tlnp 2>/dev/null | grep ':8888' && echo MITM_RUNNING || echo MITM_DOWN ;;
  *) echo 'usage: mitm.sh start|stop|status' ;;
esac
