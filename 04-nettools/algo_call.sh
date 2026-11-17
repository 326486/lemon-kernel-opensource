#!/system/bin/sh
K=/data/adb/lemon_kernel
TMP=/data/local/tmp/.algo_resp
sh $K/lemon/algo_raw.sh "$@" > $TMP 2>&1
BODY=$(sed -e 's/^.*"text":"//' $TMP)
printf '%b' "$BODY" | tr -d '\134' | sed 's/"}],"isError".*$//'
