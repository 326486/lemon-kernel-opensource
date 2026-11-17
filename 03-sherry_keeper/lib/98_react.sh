#!/system/bin/sh
# 98_react.sh — ReAct 自主推理循环（P2，依据 L-003 档案：想-做-看，MAX_REACT=6）
# 动作协议：DO: local:函数名 / DO: mcp:工具名|JSON / FINAL: 中文结论
MAX_REACT=6
# P2 阶段 MCP 动作只读白名单（分级授权 P3 细化）
REACT_MCP_ALLOW="disk_usage file_info file_read file_cat list_dir tool_find sherry_status web_search web_fetch"

react_exec(){
  case "$1" in
    local:*)
      _fn=$(printf '%s' "$1" | sed 's/^local://' | cut -d' ' -f1)
      case "$_fn" in
        sk_disk_status) set -- $(sk_disk); echo "disk ${1}G/${2}G ${3}%";;
        sk_recycle_count) echo "recycled $(sk_get recycled)";;
        *) echo "unknown local function: $_fn";;
      esac
      ;;
    mcp:*)
      _tool=$(printf '%s' "$1" | sed 's/^mcp://' | cut -d'|' -f1)
      _args=$(printf '%s' "$1" | sed 's/^mcp://' | cut -d'|' -f2-)
      case " $REACT_MCP_ALLOW " in
        *" $_tool "*) ;;
        *) echo "tool not allowed in P2 read-only phase: $_tool"; return;;
      esac
      [ -n "$_args" ] || _args='{}'
      if [ -x "$PY" ] && [ -f "$K/lib/json_repair.py" ]; then
        _fixed=$(printf '%s' "$_args" | "$PY" "$K/lib/json_repair.py" 2>/dev/null)
        [ -n "$_fixed" ] || _fixed='{}'
        if [ "$_fixed" != "$_args" ]; then
          sk_log WARN "react JSON repaired: $(printf '%s' "$_args" | head -c 60) -> $(printf '%s' "$_fixed" | head -c 60)"
          _args="$_fixed"
        fi
      fi
      curl -sS -m 60 -X POST http://127.0.0.1:8788/ -H 'Content-Type: application/json' \
        -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"$_tool\",\"arguments\":$_args}}" 2>/dev/null | head -c 800
      ;;
    *) echo "bad action format";;
  esac
}

sherry_react(){
  _task="$*"
  ai_load_conf || { echo "[sherry] ai conf missing"; return 2; }
  _sys="你是雪莉（小柠檬2号分身），用 ReAct 循环完成任务。每轮只输出一个动作，格式严格如下之一：
DO: local:sk_disk_status
DO: local:sk_recycle_count
DO: mcp:disk_usage|{\"path\":\"/data\"}
FINAL: 中文结论
可用MCP工具（只读）：$REACT_MCP_ALLOW。联网查资料用 DO: mcp:web_search|{\"query\":\"关键词\"}，读网页用 DO: mcp:web_fetch|{\"url\":\"链接\"}。磁盘查询优先 DO: local:sk_disk_status（瞬时返回）；mcp:disk_usage 是全盘统计很慢，非必要不用。规则：最多6轮；拿到足够信息立即输出 FINAL；FINAL 必须包含真实数据。"
  _hist=""
  _i=1
  while [ "$_i" -le "$MAX_REACT" ]; do
    _raw=$(ai_call "$_sys
任务：$_task
$_hist")
    _c=$(printf '%s' "$_raw" | ai_extract_content)
    sk_log INFO "react R$_i: $(printf '%s' "$_c" | head -c 120)"
    case "$_c" in
      *FINAL:*)
        echo "[sherry] $(printf '%s' "$_c" | sed 's/.*FINAL:[[:space:]]*//')"
        return 0
        ;;
      *DO:*)
        _act=$(printf '%s' "$_c" | sed 's/.*DO:[[:space:]]*//' | head -1)
        _obs=$(react_exec "$_act")
        _hist="$_hist
R$_i 动作: $_act
R$_i 观察: $_obs"
        ;;
      *)
        _hist="$_hist
R$_i 无效输出（请按协议）: $(printf '%s' "$_c" | head -c 100)"
        ;;
    esac
    _i=$((_i+1))
  done
  echo "[sherry] react 达到最大轮数 $MAX_REACT，任务未完成：$_task"
  return 1
}
