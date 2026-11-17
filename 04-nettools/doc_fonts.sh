#!/system/bin/sh
# 柠檬内核 云字体管理 (取自一加「文档」App cloud_fonts_config.json, 汉仪正版字体)
# 用法: doc_fonts.sh list | doc_fonts.sh download <SongTi|FangSong|KaiTi|HeiTi>
# 铁律: 有限循环 | curl 全程 --max-time | fail-closed
BASE=/data/adb/lemon_kernel/doc_assets
CFG="$BASE/cloud_fonts_config.json"
FONTDIR="$BASE/fonts"
PY=/data/data/com.termux/files/usr/bin/python3

[ -f "$CFG" ] || { echo "ERROR: 配置不存在 $CFG"; exit 1; }

case "$1" in
  list)
    echo "== 云字体库 (源自 一加文档App 汉仪正版) =="
    mkdir -p "$FONTDIR"
    $PY - "$CFG" "$FONTDIR" <<'EOF'
import json, os, sys
cfg, fdir = sys.argv[1], sys.argv[2]
data = json.load(open(cfg))
base = data.get('baseUrl', '')
print('下载源: %s' % base)
for it in data.get('list', []):
    p = os.path.join(fdir, it['fontName'])
    st = 'OK %s字节' % os.path.getsize(p) if os.path.isfile(p) else '未下载'
    print('%-10s %-40s %8.1fMB  [%s]' % (
        it['category'], it['fontName'], int(it['fontSize'])/1048576.0, st))
EOF
    ;;
  download)
    [ -z "$2" ] && { echo "ERROR: 用法 doc_fonts.sh download <SongTi|FangSong|KaiTi|HeiTi>"; exit 1; }
    mkdir -p "$FONTDIR"
    NAME=$($PY - "$CFG" "$2" <<'EOF'
import json, sys
data = json.load(open(sys.argv[1]))
for it in data.get('list', []):
    if it['category'] == sys.argv[2]:
        print(it['fontName']); break
EOF
)
    [ -z "$NAME" ] && { echo "ERROR: 无此字体类别: $2 (可选 SongTi/FangSong/KaiTi/HeiTi)"; exit 1; }
    URL=$($PY - "$CFG" <<'EOF'
import json, sys
print(json.load(open(sys.argv[1]))['baseUrl'])
EOF
)
    echo "下载: $URL$NAME"
    timeout 180 curl -sL --max-time 170 -o "$FONTDIR/$NAME.part" "$URL$NAME" || { echo "ERROR: 下载失败"; rm -f "$FONTDIR/$NAME.part"; exit 1; }
    SIZE=$(stat -c %s "$FONTDIR/$NAME.part" 2>/dev/null)
    [ "${SIZE:-0}" -lt 1000000 ] && { echo "ERROR: 文件异常过小($SIZE), 疑似下载失败"; rm -f "$FONTDIR/$NAME.part"; exit 1; }
    mv "$FONTDIR/$NAME.part" "$FONTDIR/$NAME"
    echo "完成: $FONTDIR/$NAME ($SIZE 字节)"
    ;;
  *)
    echo "ERROR: 用法 doc_fonts.sh list | download <SongTi|FangSong|KaiTi|HeiTi>"
    exit 1
    ;;
esac