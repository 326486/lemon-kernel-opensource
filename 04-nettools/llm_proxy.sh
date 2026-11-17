#!/system/bin/sh
export PATH=/data/adb/magisk:/system/bin:/system/xbin:$PATH
K=/data/adb/lemon_kernel
CONF=$K/conf/proxy.env
PROMPT_FILE=$K/conf/proxy_prompt.txt
[ -f "$CONF" ] && . "$CONF"
: "${PROXY_URL:=https://api.deepseek.com/chat/completions}"
: "${PROXY_KEY:=}"
: "${PROXY_MODEL:=deepseek-chat}"
: "${PROXY_TIMEOUT:=120}"
OP="$1"; shift

json_escape() {
  awk 'BEGIN{ORS=""} { gsub(/\\/,"\\\\"); gsub(/"/,"\\\""); gsub(/\t/,"\\t"); gsub(/\r/,""); if (NR>1) printf "\\n"; printf "%s", $0; }'
}

case "$OP" in
  chat)
    TEXT="$1"
    [ -z "$TEXT" ] && { echo "[err] 缺少 text"; exit 2; }
    SYS=$(cat "$PROMPT_FILE" 2>/dev/null)
    S_ESC=$(printf '%s' "$SYS" | json_escape)
    U_ESC=$(printf '%s' "$TEXT" | json_escape)
    P=/data/local/tmp/.llm_payload.json
    printf '{"model":"%s","messages":[{"role":"system","content":"%s"},{"role":"user","content":"%s"}],"stream":false}' "$PROXY_MODEL" "$S_ESC" "$U_ESC" > "$P"
    RESP=$(curl -s -m "$PROXY_TIMEOUT" "$PROXY_URL" -H "Content-Type: application/json" -H "Authorization: Bearer $PROXY_KEY" --data-binary @"$P" 2>&1)
    OUT=$(printf '%s' "$RESP" | sed -n 's/.*"content":"\([^"]*\)".*/\1/p' | head -1)
    if [ -z "$OUT" ]; then echo "[上游原始响应]"; printf '%s\n' "$RESP" | head -c 2000; else printf '%b\n' "$OUT"; fi
    ;;
  raw)
    TEXT="$1"
    SYS=$(cat "$PROMPT_FILE" 2>/dev/null)
    S_ESC=$(printf '%s' "$SYS" | json_escape)
    U_ESC=$(printf '%s' "$TEXT" | json_escape)
    P=/data/local/tmp/.llm_payload.json
    printf '{"model":"%s","messages":[{"role":"system","content":"%s"},{"role":"user","content":"%s"}],"stream":false}' "$PROXY_MODEL" "$S_ESC" "$U_ESC" > "$P"
    curl -s -m "$PROXY_TIMEOUT" "$PROXY_URL" -H "Content-Type: application/json" -H "Authorization: Bearer $PROXY_KEY" --data-binary @"$P" 2>&1
    ;;
  prompt_get)
    cat "$PROMPT_FILE" 2>&1 ;;
  prompt_set)
    printf '%s' "$1" > "$PROMPT_FILE" && echo "[ok] 提示词已更新 ($(wc -c < "$PROMPT_FILE") 字节)" ;;
  info)
    echo "上游URL: $PROXY_URL"
    echo "模型:    $PROXY_MODEL"
    echo "KEY:     $([ -n "$PROXY_KEY" ] && [ "$PROXY_KEY" != "在此填入你的KEY" ] && echo 已配置 || echo 未配置)"
    echo "提示词:  $(wc -c < "$PROMPT_FILE" 2>/dev/null) 字节"
    echo "--- 提示词预览 ---"
    head -20 "$PROMPT_FILE" 2>&1 ;;
  *)
    echo "[err] 未知操作: $OP"; exit 2 ;;
esac
