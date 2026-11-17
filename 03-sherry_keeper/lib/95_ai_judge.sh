#!/system/bin/sh
# 95_ai_judge.sh — AI 判断层（P2，依据 20260918_雪莉AI判断层档案重建）
# 云脑：本地网关 OpenAI 兼容接口；纯 shell+curl，JSON 解析用 Termux python3 绝对路径（#35坑）
PY=/data/data/com.termux/files/usr/bin/python3
AI_CONF="$SK_FILES/ai.conf"

ai_load_conf(){
  [ -f "$AI_CONF" ] || return 1
  . "$AI_CONF"
  return 0
}

ai_available(){
  ai_load_conf || return 1
  curl -sS -m 5 "$AI_PRIMARY_URL/models" -H "Authorization: Bearer $AI_KEY1" >/dev/null 2>&1 && return 0
  curl -sS -m 5 "$AI_FALLBACK_URL/models" -H "Authorization: Bearer $AI_KEY1" >/dev/null 2>&1 && return 0
  return 1
}

json_escape(){
  printf '%s' "$1" | tr '\n\r\t' '   ' | tr -d '"\\'
}

ai_call(){
  # 限速护栏：与上次调用至少间隔8秒（网关RPM敏感，密集调用必429）
  _pf="$SK_STATUS/.ai_last_call"
  _last=$(cat "$_pf" 2>/dev/null || echo 0)
  _now=$(date +%s)
  _gap=$((_now - _last))
  if [ "$_gap" -lt 8 ]; then sleep $((8 - _gap)); fi
  date +%s > "$_pf" 2>/dev/null
  _p=$(json_escape "$1")
  _body="{\"model\":\"$AI_MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"$_p\"}],\"max_tokens\":${AI_MAX_TOKENS:-2048}}"
  _r=$(curl -sS -m ${AI_TIMEOUT:-40} "$AI_PRIMARY_URL/chat/completions" -H "Authorization: Bearer $AI_KEY1" -H 'Content-Type: application/json' -d "$_body" 2>/dev/null)
  case "$_r" in
    *429*|*频率超限*)
      sk_log WARN "ai rate-limited, backoff 30s"
      sleep 15
      date +%s > "$_pf" 2>/dev/null
      sleep 15
      _r=$(curl -sS -m ${AI_TIMEOUT:-40} "$AI_PRIMARY_URL/chat/completions" -H "Authorization: Bearer $AI_KEY1" -H 'Content-Type: application/json' -d "$_body" 2>/dev/null)
      ;;
  esac
  if [ -z "$_r" ] || ! printf '%s' "$_r" | grep -q '"choices"'; then
    sleep 2
    _r=$(curl -sS -m ${AI_TIMEOUT:-40} "$AI_PRIMARY_URL/chat/completions" -H "Authorization: Bearer $AI_KEY1" -H 'Content-Type: application/json' -d "$_body" 2>/dev/null)
  fi
  if [ -z "$_r" ] || ! printf '%s' "$_r" | grep -q '"choices"'; then
    _r=$(curl -sS -m ${AI_TIMEOUT:-40} "$AI_FALLBACK_URL/chat/completions" -H "Authorization: Bearer $AI_KEY2" -H 'Content-Type: application/json' -d "$_body" 2>/dev/null)
  fi
  printf '%s' "$_r"
}

ai_extract_content(){
  if [ -x "$PY" ]; then
    "$PY" -c 'import sys,json
try:
    d=json.load(sys.stdin)
    print(d["choices"][0]["message"].get("content",""))
except Exception:
    print("")'
  else
    sed -n 's/.*"content":"\(.*\)","reasoning_content".*/\1/p' | head -1
  fi
}

ai_judge_file(){
  _f="$1"
  sherry_path_allowed "$_f" || { echo dangerous; return; }
  _cache="$SK_STATUS/ai_verdict/cache.tsv"
  mkdir -p "$SK_STATUS/ai_verdict" 2>/dev/null
  _key=$(printf '%s' "$_f" | md5sum | cut -d' ' -f1)
  _hit=$(grep "^$_key	" "$_cache" 2>/dev/null | head -1)
  if [ -n "$_hit" ]; then
    printf '%s' "$_hit" | cut -f3
    return
  fi
  _sz=$(wc -c < "$_f" 2>/dev/null || echo 0)
  _mt=$(stat -c %y "$_f" 2>/dev/null | cut -d. -f1)
  _prompt="你是文件清理安全审计员。判断下面这个文件能否安全移入回收站（不是永久删除）。只回答一个英文词：safe 或 caution 或 dangerous。文件路径：$_f 大小：${_sz}字节 修改时间：$_mt"
  ai_load_conf
  _raw=$(ai_call "$_prompt")
  _content=$(printf '%s' "$_raw" | ai_extract_content)
  _v=$(printf '%s' "$_content" | tr 'A-Z' 'a-z' | grep -oE 'safe|caution|dangerous' | head -1)
  [ -n "$_v" ] || _v=unknown
  case "$_v" in
    safe|caution|dangerous) printf '%s\t%s\t%s\n' "$_key" "$_f" "$_v" >> "$_cache";;
  esac
  sk_log INFO "ai_judge $_f -> $_v"
  echo "$_v"
}

ai_smart_clean(){
  _dry=0; _dir=""
  for a in "$@"; do
    case "$a" in
      --dry) _dry=1;;
      *) _dir="$a";;
    esac
  done
  if [ -n "$_dir" ]; then
    sherry_path_allowed "$_dir/probe" || { echo "[sherry] deny: $_dir out of whitelist"; return 2; }
    _targets="$_dir"
  else
    _targets="/data/local/tmp /storage/emulated/0/Download"
  fi
  ai_load_conf || { echo "[sherry] ai conf missing"; return 2; }
  _safe=0; _skip=0
  for d in $_targets; do
    [ -d "$d" ] || continue
    find "$d" -maxdepth 2 -type f \( -name '*.tmp' -o -name '*.temp' -o -name '*.log' -o -name '*.cache' -o -name '*.bak' \) > "$SK_STATUS/.ai_cand" 2>/dev/null
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      sherry_path_allowed "$f" || { _skip=$((_skip+1)); continue; }
      v=$(ai_judge_file "$f")
      if [ "$v" = "safe" ]; then
        if [ "$_dry" = 1 ]; then
          echo "[sherry] DRY ai-safe: $f"
        else
          safe_rm "$f" && _safe=$((_safe+1))
        fi
      else
        _skip=$((_skip+1))
        sk_log INFO "ai_skip $f verdict=$v"
      fi
    done < "$SK_STATUS/.ai_cand"
  done
  rm -f "$SK_STATUS/.ai_cand" 2>/dev/null
  echo "[sherry] ai_clean done: recycled=$_safe skipped=$_skip dry=$_dry"
}
