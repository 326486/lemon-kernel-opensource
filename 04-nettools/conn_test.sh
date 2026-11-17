#!/system/bin/sh
# 免费API直连可达性测试（只读探测，不写任何业务数据）
CURL=/data/data/com.termux/files/usr/bin/curl
OUT=/data/lemonbrain/nettools/conn_test.out
: > "$OUT"
probe() {
  name="$1"; url="$2"; tmo="$3"
  code=$($CURL -s -o /dev/null -m "$tmo" -w "%{http_code}" -A "Mozilla/5.0 (Linux; Android)" "$url" 2>/dev/null)
  rc=$?
  echo "$name|http=$code|curl_rc=$rc|$url" >> "$OUT"
}
probe urlhaus      "https://urlhaus-api.abuse.ch/v1/"                          15
probe malwarebazaar "https://mb-api.abuse.ch/v1/"                             15
probe crtsh        "https://crt.sh/?q=example.com&output=json"                 30
probe wikipedia    "https://zh.wikipedia.org/api/rest_v1/page/summary/Android" 12
probe arxiv        "http://export.arxiv.org/api/query?search_query=all:electron&max_results=1" 15
probe s2           "https://api.semanticscholar.org/graph/v1/paper/search?query=android&limit=1" 15
probe httpbin      "https://httpbin.org/get"                                   15
probe webhooksite  "https://webhook.site/"                                     15
probe godbolt      "https://godbolt.org/api/compilers"                         15
probe stackexchange "https://api.stackexchange.com/2.3/info?site=stackoverflow" 15
probe wttr         "https://wttr.in/Changsha?format=3"                         15
probe ipapi        "http://ip-api.com/json/8.8.8.8"                            12
probe codeshare    "https://codeshare.frida.re/api/projects/"                  15
probe fdroid       "https://f-droid.org/repo/index-v1.jar"                     20
probe izzy         "https://apt.izzysoft.de/fdroid/repo/index-v1.jar"          20
probe github       "https://github.com/gchq/CyberChef/releases/latest"         15
probe gitlab       "https://gitlab.com/exploit-database/exploitdb"             15
probe mcpregistry  "https://registry.modelcontextprotocol.io/v0/servers"       15
probe edge_tts     "https://speech.platform.bing.com/"                         12
echo "DONE" >> "$OUT"