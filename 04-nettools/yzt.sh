#!/system/bin/sh
# yzt.sh - 宇宙工具箱接口桥 v1.0 (261104)
# 来源: 宇宙工具箱 v2.9.6 接口挖掘 (5号库#219/学习中心L-380)
# 子命令: video|iptv|res|movie|dialect|netdisk
# 防空转: 全部网络操作 timeout 包裹, 无循环, 输出有界 (#249)

UA='Mozilla/5.0 (Linux; Android 13; PLQ110) AppleWebKit/537.36 Chrome/120 Mobile Safari/537.36'
OUT=/data/lemonbrain/logs/yzt
mkdir -p "$OUT" 2>/dev/null

case "$1" in

video)
  # 随机短视频直链: 302 Location 模式
  src="$2"; cat_="$3"
  case "$src" in
  yujn)     url="http://api.yujn.cn/api/${cat_:-COS}.php?type=video";;
  yujnhttps) url="https://api.yujn.cn/api/${cat_:-nvda}.php?type=video";;
  xjj)      d="${cat_:-kawayi}"; url="http://xjj1.716888.xyz/fenlei/zj/$d/$d.php?random=$(date +%s)";;
  xjj2)     url="http://xjj2.716888.xyz/fenlei/kuan3/v.php?_t=$(date +%s)";;
  dj)       url="http://xjj1.716888.xyz/fenlei/djxjj/dj1.php?random=$(date +%s)";;
  cenguigui) url="https://api.cenguigui.cn/api/mp4/api.php?type=${cat_:-luoli}&format=mp4";;
  hhl)      url="https://www.hhlqilongzhu.cn/api/MP4_xiaojiejie.php";;
  *) echo "ERR src 须为: yujn|yujnhttps|xjj|xjj2|dj|cenguigui|hhl"; echo "yujn分类: COS baisis bianzhuang chuanda diaodai hanfu heisis jiepai jjy jksp jpmt ksbianzhuang ksxjjsp luoli manhuay manzhan nvda qingchun rewu shejie shwd tianmei tongtong wmsc xiaoxiao yuzu zrn"; echo "xjj目录: jingpinbz jingpinsc jipinll jipinyz kawayi nennen nideym rewu sihuawd tianmei wanmeisc xuejie yusi"; exit 1;;
  esac
  loc=$(timeout 20 curl -s -A "$UA" -D - -o /dev/null "$url" 2>/dev/null | tr -d '\r' | awk 'tolower($1)=="location:"{print $2}' | head -1)
  if [ -n "$loc" ]; then
    echo "source: $src${cat_:+/$cat_}"
    echo "mode: 302 redirect"
    echo "video: $loc"
  else
    body=$(timeout 20 curl -sL -A "$UA" "$url" 2>/dev/null | head -c 800)
    if [ -n "$body" ]; then
      echo "source: $src${cat_:+/$cat_}"
      echo "mode: body"
      echo "body: $body"
    else
      echo "ERR 无响应(源失效或被防护): $url"
      exit 1
    fi
  fi
  ;;

iptv)
  # 直播源清单: txt 落盘+预览
  src="${2:-iptv}"
  case "$src" in
  iptv)      url='http://tools.53at.com/file/iptv.txt';;
  livechina) url='http://tools.53at.com/file/livechina.txt';;
  *) echo "ERR src 须为: iptv|livechina"; exit 1;;
  esac
  f="$OUT/$(date +%Y%m%d-%H%M%S)-$src.txt"
  timeout 30 curl -sL -A "$UA" "$url" -o "$f" 2>/dev/null
  if [ ! -s "$f" ]; then echo "ERR 下载失败: $url"; rm -f "$f" 2>/dev/null; exit 1; fi
  n=$(wc -l < "$f" | tr -d ' ')
  echo "源: $url"
  echo "落盘: $f"
  echo "行数: $n"
  echo "预览(前10行):"
  head -10 "$f"
  ;;

res)
  # 53at 资源下载: 落盘+预览
  f="${2:-backgroundColor}"
  case "$f" in
  backgroundColor)  url='http://tools.53at.com/config/backgroundColor.json';;
  backgroundImage)  url='http://tools.53at.com/config/backgroundImage.json';;
  updatelog)        url='http://tools.53at.com/file/update_log';;
  yellow)           url='http://tools.53at.com/file/yellow';;
  avatar)           url='http://tools.53at.com/file/%E5%A4%B4%E5%83%8F%E5%88%B6%E4%BD%9C.zip';;
  *) echo "ERR file 须为: backgroundColor|backgroundImage|updatelog|yellow|avatar"; exit 1;;
  esac
  o="$OUT/$(date +%Y%m%d-%H%M%S)-$f"
  timeout 30 curl -sL -A "$UA" "$url" -o "$o" 2>/dev/null
  if [ ! -s "$o" ]; then echo "ERR 下载失败: $url"; rm -f "$o" 2>/dev/null; exit 1; fi
  s=$(wc -c < "$o" | tr -d ' ')
  echo "源: $url"
  echo "落盘: $o ($s B)"
  echo "预览:"
  head -c 600 "$o"; echo
  ;;

movie)
  # 影视搜索/播放列表 (源当前多不通, 拿到啥回啥)
  sub="$2"; a="$3"; b="${4:-1}"
  case "$sub" in
  search)
    case "$a" in
    kunyu77)
      r=$(timeout 20 curl -sG -A "$UA" 'http://api.kunyu77.com/api.php/provide/searchVideo' --data-urlencode "pg=$b" --data-urlencode "searchName=${3:-宇宙}" 2>/dev/null | head -c 2000);;
    bajie)
      r=$(timeout 20 curl -sG -A "$UA" 'http://cj.bajiecaiji.com/index.php' --data-urlencode 'm=vod-search' --data-urlencode "wd=${3:-宇宙}" 2>/dev/null | head -c 2000);;
    ywhuilong)
      r=$(timeout 20 curl -sL -A "$UA" 'http://appapi.ywhuilong.com/index.php/app/ios/m3u8/index' 2>/dev/null | head -c 2000);;
    *) echo "ERR src 须为: kunyu77|bajie|ywhuilong"; exit 1;;
    esac
    if [ -n "$r" ]; then echo "结果($a):"; echo "$r"; else echo "ERR 源无响应(域名可能失效): $a"; exit 1; fi
    ;;
  playlist)
    r=$(timeout 20 curl -s -A "$UA" "http://api.kunyu77.com/api.php/provide/videoPlaylist?ids=${a:-1}" 2>/dev/null | head -c 2000)
    if [ -n "$r" ]; then echo "播放列表:"; echo "$r"; else echo "ERR 源无响应"; exit 1; fi
    ;;
  *) echo "ERR 用法: movie search|playlist <src|ids> <关键词> [页码]"; exit 1;;
  esac
  ;;

dialect)
  # 方言翻译 (voicedic, 参数格式若报错需抓包确认)
  lang="$2"; text="$3"
  if [ -z "$lang" ]; then echo "ERR 用法: dialect <方言如:闽南话> <文本>"; exit 1; fi
  r=$(timeout 20 curl -s -G -A "$UA" 'http://zh.voicedic.com/process.php' --data-urlencode '_input_charset=utf8' --data-urlencode "language=$lang" --data-urlencode "text=${text:-你好}" 2>/dev/null | head -c 800)
  if [ -n "$r" ]; then echo "voicedic($lang):"; echo "$r"; else echo "ERR 无响应"; exit 1; fi
  ;;

netdisk)
  # 网盘搜索 (diskgirl, 跳转探测)
  t=$(date +%s)
  r=$(timeout 20 curl -sL -A "$UA" -w "\nFINAL_URL:%{url_effective}" "http://diskgirl.com/get/get1.php?_t=$t" 2>/dev/null | head -c 1000)
  if [ -n "$r" ]; then echo "$r"; else echo "ERR 无响应"; exit 1; fi
  ;;

*)
  echo "yzt.sh - 宇宙工具箱接口桥 v1.0"
  echo "用法: yzt.sh <video|iptv|res|movie|dialect|netdisk> [参数]"
  echo "  video <src> [分类]   随机短视频直链 (yujn/xjj/xjj2/dj/cenguigui/hhl/yujnhttps)"
  echo "  iptv [src]           直播源 (iptv|livechina)"
  echo "  res <file>           资源 (backgroundColor|backgroundImage|updatelog|yellow|avatar)"
  echo "  movie search <src> <kw> [pg]  影视搜索 (kunyu77|bajie|ywhuilong)"
  echo "  movie playlist <ids>          播放列表"
  echo "  dialect <方言> <文本>          方言翻译"
  echo "  netdisk                       网盘搜索探测"
  ;;
esac