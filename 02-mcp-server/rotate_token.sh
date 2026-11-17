#!/system/bin/sh
# rotate_token.sh —— 小柠檬令牌轮换 v1.0（261111）
# 用法: sh rotate_token.sh <级别>     级别: root | write | readonly | main
#   root/write/readonly → 轮换 .tokens.json 对应字段（分级模式）
#   main                → 轮换 .token 主令牌（兼容模式）
# 特性：原子写入（tmp+mv 防热加载读到半截）；旧令牌自动进 revoked 吊销列表；轮换免重启（v1.3.3 热加载）
# 退出码: 0=成功 1=用法错误 2=目标不存在

set -u
S=${ROTATE_HOME:-/data/lemonbrain/slimproxy}
LVL="${1:-}"

case "$LVL" in
  root|write|readonly|main) ;;
  *) echo "用法: sh rotate_token.sh <root|write|readonly|main>"; exit 1 ;;
esac

# 生成 48 字符新令牌（只用字母数字，URL/header 友好）
NEW_TOK=$(head -c 64 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 48)
[ ${#NEW_TOK} -eq 48 ] || { echo "令牌生成失败"; exit 2; }

PY=${ROTATE_PY:-/data/data/com.termux/files/usr/bin/python3}

if [ "$LVL" = "main" ]; then
  # ---- 轮换主令牌 .token ----
  [ -f "$S/.token" ] || { echo ".token 不存在，无需轮换（直接新建即可）"; exit 2; }
  OLD_TOK=$(cat "$S/.token")
  TMP="$S/.token.tmp.$$"
  umask 077
  printf '%s' "$NEW_TOK" > "$TMP"
  mv "$TMP" "$S/.token"
  chmod 600 "$S/.token"
  # 旧令牌留档（仅审计，已失效）
  echo "$(date '+%y%m%d-%H%M%S') main 轮换，旧令牌尾号 ...$(printf '%s' "$OLD_TOK" | tail -c 5)" >> "$S/.token_rotate.log"
  echo "✓ 主令牌已轮换（旧令牌即刻失效）"
else
  # ---- 轮换分级令牌 .tokens.json 对应级别 ----
  [ -f "$S/.tokens.json" ] || { echo ".tokens.json 不存在（未启用分级令牌）"; exit 2; }
  LVL="$LVL" NEW_TOK="$NEW_TOK" S="$S" "$PY" - <<'EOF'
import json, os, sys
s = os.environ["S"]; lvl = os.environ["LVL"]; new_tok = os.environ["NEW_TOK"]
fp = os.path.join(s, ".tokens.json")
d = json.load(open(fp, encoding="utf-8"))
old = (d.get(lvl) or "").strip()
d[lvl] = new_tok
rev = d.get("revoked") or []
if old:
    rev.append(old)
d["revoked"] = rev[-20:]          # 吊销列表只留最近 20 个，防无限膨胀
tmp = fp + ".tmp." + str(os.getpid())
os.makedirs(s, exist_ok=True)
fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)   # 原子写
with os.fdopen(fd, "w", encoding="utf-8") as f:
    json.dump(d, f, ensure_ascii=False, indent=1)
os.replace(tmp, fp)
print("✓ %s 级令牌已轮换（旧令牌已入 revoked 吊销列表，即刻拒用）" % lvl)
if old:
    print("  旧令牌尾号 ...%s 已吊销" % old[-4:])
EOF
  [ $? -eq 0 ] || { echo "轮换失败"; exit 2; }
fi

echo ""
echo "═══ 新令牌（请立即复制保管，并分发给对应 AI 分身）═══"
echo "$LVL: $NEW_TOK"
echo "═══ v1.3.3 热加载已生效，无需重启任何服务 ═══"
