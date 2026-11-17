#!/system/bin/sh
# 小柠檬感知工具组 · 路线A 第1批（2026-11-16）
# 用法: perception.sh <sms_list|contact_list|call_log_list|notif_list|loc_last> [limit] [offset]
# 原则: 只读感知。数据库一律 -readonly 打开，不写任何系统数据。
TU=/data/data/com.termux/files/usr
SQLITE="$TU/bin/sqlite3"
export LD_LIBRARY_PATH="$TU/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export PATH="$TU/bin:$PATH"

num() { case "$1" in ''|*[!0-9]*) echo "$2";; *) echo "$1";; esac; }
CMD="$1"
LIMIT=$(num "$2" 20)
OFFSET=$(num "$3" 0)
[ "$LIMIT" -gt 200 ] && LIMIT=200

sq() {
  if [ ! -x "$SQLITE" ]; then echo '{"error":"sqlite3 missing"}'; return; fi
  out=$("$SQLITE" -readonly -json "$1" "$2" 2>&1)
  case "$out" in
    \[*) echo "$out";;
    '') echo '[]';;
    *) printf '{"error":"%s"}\n' "$(echo "$out" | head -1 | tr -d '"\\')";;
  esac
}

case "$CMD" in
sms_list)
  sq /data/data/com.android.providers.telephony/databases/mmssms.db \
    "SELECT _id,thread_id,address,date,type,body FROM sms ORDER BY date DESC LIMIT $LIMIT OFFSET $OFFSET;"
  ;;
contact_list)
  sq /data/data/com.android.providers.contacts/databases/contacts2.db \
    "SELECT r._id,r.display_name,d.data1 AS number FROM raw_contacts r JOIN data d ON d.raw_contact_id=r._id JOIN mimetypes m ON d.mimetype_id=m._id WHERE m.mimetype='vnd.android.cursor.item/phone_v2' AND r.deleted=0 ORDER BY r._id LIMIT $LIMIT OFFSET $OFFSET;"
  ;;
call_log_list)
  sq /data/data/com.android.providers.contacts/databases/calllog.db \
    "SELECT _id,number,name,date,duration,type FROM calls ORDER BY date DESC LIMIT $LIMIT OFFSET $OFFSET;"
  ;;
notif_list)
  dumpsys notification --noredact 2>/dev/null | awk '
    function esc(s){gsub(/\\/,"\\\\",s);gsub(/"/,"\\\"",s);gsub(/\t/," ",s);return s}
    function val(s){ if (match(s,/^[A-Za-z]+ \(/)) { sub(/^[A-Za-z]+ \(/,"",s); sub(/\)[ \t]*$/,"",s) } return s }
    BEGIN{sep="";printf "["}
    /NotificationRecord[({]/{
      if(pkg!=""){printf "%s{\"pkg\":\"%s\",\"title\":\"%s\",\"text\":\"%s\"}",sep,pkg,esc(title),esc(text);sep=","}
      pkg="";title="";text=""
      if(match($0,/pkg=[^ ]+/))pkg=substr($0,RSTART+4,RLENGTH-4)
    }
    /android\.title=/ && !/android\.title\.big/{sub(/.*android\.title=/,"");title=val($0)}
    /android\.text=/ && !/android\.text\.big/{sub(/.*android\.text=/,"");text=val($0)}
    END{if(pkg!=""){printf "%s{\"pkg\":\"%s\",\"title\":\"%s\",\"text\":\"%s\"}",sep,pkg,esc(title),esc(text)}print "]"}
  '
  ;;
loc_last)
  dumpsys location 2>/dev/null | grep -i "last location" | head -5 | awk '
    BEGIN{sep="";printf "["}
    {gsub(/\\/,"\\\\");gsub(/"/,"\\\"");gsub(/^[ \t]+/,"");printf "%s\"%s\"",sep,$0;sep=","}
    END{print "]"}
  '
  ;;
cam_photo)
  OUT="${2:-/data/data/com.termux/files/home/lemonout/cam_$(date +%s).jpg}"
  CAM=$(num "$3" 0)
  mkdir -p "$(dirname "$OUT")"
  if termux-camera-photo -c "$CAM" "$OUT" >/dev/null 2>&1 && [ -s "$OUT" ]; then
    printf '{"path":"%s","bytes":%s,"camera":%s}\n' "$OUT" "$(stat -c %s "$OUT" 2>/dev/null || echo 0)" "$CAM"
  else
    echo '{"error":"camera capture failed (检查Termux:API应用与相机权限)"}'
  fi
  ;;
mic_record)
  SECS=$(num "$2" 5)
  [ "$SECS" -gt 120 ] && SECS=120
  OUT="${3:-/data/lemonbrain/toolout/mic_$(date +%s).m4a}"
  mkdir -p "$(dirname "$OUT")"
  termux-microphone-record -l "$SECS" >/dev/null 2>&1
  sleep $((SECS + 2))
  SRC=$(ls -t /storage/emulated/0/TermuxAudioRecording_*.m4a 2>/dev/null | head -1)
  if [ -n "$SRC" ] && [ -s "$SRC" ] && cat "$SRC" > "$OUT" 2>/dev/null && [ -s "$OUT" ]; then
    rm -f "$SRC"
    printf '{"path":"%s","bytes":%s,"seconds":%s}\n' "$OUT" "$(stat -c %s "$OUT" 2>/dev/null || echo 0)" "$SECS"
  else
    echo '{"error":"mic record failed (检查Termux:API应用与麦克风/存储权限)"}'
  fi
  ;;
tts_say)
  TEXT="$2"
  if [ -z "$TEXT" ]; then echo '{"error":"text required"}'; exit 0; fi
  if termux-tts-speak "$TEXT" >/dev/null 2>&1; then
    echo '{"spoken":true}'
  else
    echo '{"error":"tts failed (检查Termux:API应用)"}'
  fi
  ;;
loc_fresh)
  MODE=$(settings get secure location_mode 2>/dev/null)
  TOGGLE=0
  if [ "$MODE" = "0" ]; then settings put secure location_mode 3; TOGGLE=1; sleep 2; fi
  OUT=$(termux-location -p gps -r once 2>/dev/null)
  case "$OUT" in \{*) :;; *) OUT=$(termux-location -p network -r once 2>/dev/null);; esac
  [ "$TOGGLE" = "1" ] && settings put secure location_mode "$MODE"
  case "$OUT" in \{*) echo "$OUT";; *) echo '{"error":"no fix (定位未开启或无信号)"}';; esac
  ;;
*)
  echo '{"error":"unknown subcommand"}'
  ;;
esac
