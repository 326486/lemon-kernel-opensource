#!/system/bin/sh
PY=/data/data/com.termux/files/usr/bin/python3
D=/data/lemonbrain/nettools
OUT=$D/test_results.txt
: > "$OUT"
run(){
  name="$1"; shift
  o=$($PY "$D/$name.py" "$@" 2>&1); rc=$?
  if [ $rc -eq 0 ] && ! echo "$o" | grep -q '"error"'; then
    echo "PASS $name | $(echo "$o" | head -c 120 | tr '\n' ' ')" >> "$OUT"
  else
    echo "FAIL $name rc=$rc | $(echo "$o" | head -c 200 | tr '\n' ' ')" >> "$OUT"
  fi
}
run inet_wttr --city Changsha
run inet_ipapi --target 8.8.8.8
run inet_httpbin --mode ip
run inet_arxiv --q electron --limit 2
run inet_stackexchange --q "android root" --limit 2
run inet_mcp_registry --q search --limit 3
run inet_s2 --q android --limit 2
run inet_webhook --action create
run inet_godbolt --action compilers --lang c
run inet_crtsh --domain example.com --limit 10
run inet_fdroid --q termux --limit 3
echo "DONE" >> "$OUT"