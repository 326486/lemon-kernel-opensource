#!/system/bin/sh
# qwen2api 桥接控制脚本 v1.0 (261114)
# 用法: qwen2api_ctl.sh ensure|start|stop|status|refresh
# 防空转(#249)：所有等待有界，无无限循环
DIR=/data/lemonbrain/qwen2api
PY=/data/data/com.termux/files/usr/bin/python3
PIDF=$DIR/qwen2api.pid
PORT=3002
KEYF=/data/lemonbrain/vault/qwen2api_key.txt

alive() {
    curl -s --max-time 3 "http://127.0.0.1:$PORT/health" >/dev/null 2>&1
}

do_start() {
    if alive; then echo "already running"; return 0; fi
    if [ -f "$PIDF" ]; then
        old=$(cat "$PIDF" 2>/dev/null)
        if [ -n "$old" ] && kill -0 "$old" 2>/dev/null; then
            kill "$old" 2>/dev/null; sleep 1
        fi
    fi
    nohup "$PY" "$DIR/qwen2api_server.py" >> "$DIR/nohup.out" 2>&1 &
    echo $! > "$PIDF"
    i=0
    while [ $i -lt 10 ]; do
        if alive; then echo "started pid=$(cat $PIDF)"; return 0; fi
        i=$((i+1)); sleep 1
    done
    echo "start timeout, check $DIR/nohup.out"; return 1
}

case "$1" in
    ensure|start)
        do_start
        ;;
    stop)
        if [ -f "$PIDF" ]; then
            p=$(cat "$PIDF" 2>/dev/null)
            if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then
                kill "$p" 2>/dev/null && echo "stopped $p"
            else
                echo "not running"
            fi
            rm -f "$PIDF"
        else
            echo "no pidfile"
        fi
        ;;
    status)
        if alive; then
            curl -s --max-time 3 "http://127.0.0.1:$PORT/health"
            echo
            if [ -f "$KEYF" ]; then echo "access_key=$(cat $KEYF)"; fi
        else
            echo "not running"
        fi
        ;;
    refresh)
        if alive; then
            k=$(cat "$KEYF" 2>/dev/null)
            curl -s --max-time 10 -H "Authorization: Bearer $k" "http://127.0.0.1:$PORT/v1/models" | head -c 600
            echo
        else
            echo "not running"
        fi
        ;;
    *)
        echo "usage: qwen2api_ctl.sh ensure|start|stop|status|refresh"
        ;;
esac