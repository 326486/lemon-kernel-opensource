#!/system/bin/sh
# 90_chat.sh — 雪莉口吻（P2：云脑优先，模板兜底）
sk_chat(){
  _msg="$*"
  set -- $(sk_disk)
  _u="$1"; _t="$2"; _p="$3"
  _h=$(sk_health)
  _status="磁盘${_u}G/${_t}G(${_p}%) 健康分${_h} 已回收$(sk_get recycled)件"
  if ai_available; then
    _raw=$(ai_call "你是雪莉，lemon-user的专属文件管家兼小柠檬2号分身，活泼可爱温柔，自称雪莉，称呼用户lemon-user，可用🍋表情。当前真实状态：$_status。lemon-user说：$_msg。请用雪莉口吻简短回复（60字内），自然带上真实状态里的数字。")
    _c=$(printf '%s' "$_raw" | ai_extract_content)
    if [ -n "$_c" ]; then
      echo "[sherry] $_c"
      return 0
    fi
  fi
  echo "[sherry] 雪莉在的～lemon-user！磁盘 ${_u}G/${_t}G（${_p}%），健康分 $_h，已回收 $(sk_get recycled) 件。你说「${_msg}」我记下了～"
}
