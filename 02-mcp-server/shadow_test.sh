#!/system/bin/sh
# 影子测试台 · 8792 独立实例，破坏性测试专用，绝不碰 8791
# 坑：不可全局 export LD_LIBRARY_PATH（会让系统 curl 加载 Termux libcrypto 报 EVP_MD_CTX_create）
PORT=8792
SP=/data/lemonbrain/slimproxy/slim_proxy.py
P=/data/data/com.termux/files/usr
PIDF=/data/lemonbrain/slimproxy/.slim.$PORT.pid
LOG=/data/lemonbrain/logs/shadow.log

up() { awk -v h=":2258" '$2 ~ h"$" && $4 == "0A" {f=1} END {exit !f}' /proc/net/tcp 2>/dev/null; }

echo "[1] 启动影子实例 8792"
LD_LIBRARY_PATH=$P/lib nohup env LEMON_SLIM_PORT=$PORT $P/bin/python3 -u "$SP" >> "$LOG" 2>&1 &
echo $! > "$PIDF"
sleep 2
if up; then echo "    OK 8792 已监听"; else echo "    FAIL 启动失败"; tail -5 "$LOG"; exit 1; fi

echo "[2] 验证 tools/list = 14"
N=$(curl -s -m 8 -X POST http://127.0.0.1:$PORT/ -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}' | grep -o '"name": *"[^"]*"' | wc -l)
echo "    工具数 = $N"

echo "[3] 强杀影子进程"
NP=$(cat "$PIDF"); kill -9 "$NP" 2>/dev/null; w=0; while up && [ $w -lt 10 ]; do sleep 0.5; w=$((w+1)); done
if up; then echo "    FAIL 未杀死"; else echo "    OK 已杀死，端口空"; fi

echo "[4] 手动重启"
LEMON_SLIM_PORT=$PORT sh /data/lemonbrain/slimproxy/start.sh
sleep 2
if up; then echo "    OK 8792 恢复"; else echo "    FAIL 恢复失败"; fi

echo "[5] 清理"
NP=$(cat /data/lemonbrain/slimproxy/.slim.$PORT.pid 2>/dev/null); [ -n "$NP" ] && kill -9 "$NP" 2>/dev/null
rm -f /data/lemonbrain/slimproxy/.slim.$PORT.pid
sleep 1
if up; then echo "    FAIL 未清理"; else echo "    OK 已清理"; fi

echo "[6] 生产 8791 未受影响"
curl -s -m 5 http://127.0.0.1:8791/ | head -c 100
echo
