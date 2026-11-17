#!/system/bin/sh
# ══════════════════════════════════════════════════════════════
# 小柠檬 · Termux 内核桥 v3.1  (261030)
# v3.1：su 探测顺序修正 —— Magisk 新版 su 在 /debug_ramdisk/su
# v3：su/timeout 绝对路径（8788 重启后 PATH 不含 magisk，裸 su not found）
# 参数传递：LemonCore 替换 $param 会加单引号 → 多值参数走环境变量 TX_*
# 子命令：run|runc|root|rootc|build|cxx|cmake|meson|ninja|make|cross|
#         strip|elf|size|which|env|git|pip|pkg|curl
# 防空转：一律 timeout；输出超 4KB 落盘只回预览
# ══════════════════════════════════════════════════════════════

TX_P=/data/data/com.termux/files/usr
TX_H=/data/data/com.termux/files/home
TX_U=10412
OUTDIR=/data/lemonbrain/toolout
MAXB=4096
JOB=/data/local/tmp/tx_job_$$.sh
OUTF=/data/local/tmp/tx_out_$$

# ★ su 探测（新版 Magisk 在 /debug_ramdisk）
SU_BIN=/debug_ramdisk/su
[ -x "$SU_BIN" ] || SU_BIN=/data/adb/magisk/su
[ -x "$SU_BIN" ] || SU_BIN=/system/bin/su
TO_BIN=/system/bin/timeout
[ -x "$TO_BIN" ] || TO_BIN=timeout

cleanup() { rm -f "$JOB" "$OUTF"; }
trap cleanup EXIT INT TERM

emit() {
    SZ=$(wc -c < "$OUTF" 2>/dev/null)
    SZ=${SZ// /}
    [ -z "$SZ" ] && SZ=0
    if [ "$SZ" -gt "$MAXB" ]; then
        mkdir -p "$OUTDIR" 2>/dev/null
        DEST="$OUTDIR/$(date +%Y%m%d-%H%M%S)-tx.txt"
        cp -f "$OUTF" "$DEST" 2>/dev/null
        head -c "$MAXB" "$OUTF"
        echo
        echo "[slim] 输出 ${SZ}B 超 4KB，全文：$DEST"
    else
        cat "$OUTF"
    fi
}

do_exec() {
    MODE="$1"; T="$2"; CMD="$3"
    if [ -z "$CMD" ]; then echo "ERR: 空命令"; exit 2; fi
    case "$T" in ""|*[!0-9]*) T=120 ;; esac

    {
        echo "#!/system/bin/sh"
        echo "export HOME=$TX_H"
        echo "export PREFIX=$TX_P"
        echo "export PATH=$TX_P/bin:/system/bin"
        echo "export LD_LIBRARY_PATH=$TX_P/lib"
        echo "export TMPDIR=$TX_P/tmp"
        echo "export TERM=xterm-256color"
        echo "cd $TX_H || exit 9"
        printf '%s\n' "$CMD"
    } > "$JOB"
    chmod 700 "$JOB"

    if [ "$MODE" = root ]; then
        "$TO_BIN" "$T" /system/bin/sh "$JOB" > "$OUTF" 2>&1
    else
        chown $TX_U:$TX_U "$JOB" 2>/dev/null
        "$TO_BIN" "$T" "$SU_BIN" $TX_U -c "sh $JOB" > "$OUTF" 2>&1
    fi
    RC=$?

    if [ "$RC" -eq 124 ]; then
        echo "[超时] 已强制终止（${T}s）。输出尾部："
        emit
        echo "[exit=$RC]"
        exit 124
    fi

    [ "$MODE" = root ] && chown -R $TX_U:$TX_U "$TX_H" 2>/dev/null

    emit
    echo "[exit=$RC]"
    exit $RC
}

OUT_A=${TX_OUT:-$TX_H/a.out}
OUT_O=${TX_OUT:-$TX_H/a.o}

case "$1" in
  runc)  T="$2"; do_exec user "${T:-120}" "$TX_CMD" ;;
  rootc) T="$2"; do_exec root "${T:-120}" "$TX_CMD" ;;
  run)   shift; T="$1"; shift; do_exec user "$T" "$*" ;;
  root)  shift; T="$1"; shift; do_exec root "$T" "$*" ;;
  runb)  B64="$TX_B64"; [ -z "$B64" ] && { echo "ERR: code参数为空"; exit 2; }; T="${TX_T:-120}"; CMD="$(printf %s "$B64" | /system/bin/base64 -d 2>/dev/null)"; [ -z "$CMD" ] && { echo "ERR: base64解码为空"; exit 2; }; do_exec user "$T" "$CMD" ;;

  build)
    do_exec user 280 "clang -O2 $TX_FLAGS -o $OUT_A $TX_SRC && ls -l $OUT_A && echo BUILD_OK"
    ;;
  cxx)
    do_exec user 280 "clang++ -std=c++17 -O2 $TX_FLAGS -o $OUT_A $TX_SRC && ls -l $OUT_A && echo CXX_OK"
    ;;
  cmake)
    B=${TX_BUILD:-$TX_H/build}
    do_exec user 580 "cmake -S $TX_DIR -B $B -G Ninja $TX_FLAGS && cmake --build $B && echo CMAKE_OK"
    ;;
  meson)
    B=${TX_BUILD:-build}
    do_exec user 580 "cd $TX_DIR && meson setup $B $TX_FLAGS && ninja -C $B && echo MESON_OK"
    ;;
  ninja)
    do_exec user 580 "ninja -C ${TX_DIR:-.} $TX_FLAGS && echo NINJA_OK"
    ;;
  make)
    do_exec user 580 "cd $TX_DIR && make $TX_FLAGS"
    ;;
  cross)
    A=${TX_API:-30}
    do_exec user 280 "clang -target aarch64-linux-android$A $TX_FLAGS -O2 -c $TX_SRC -o $OUT_O && ls -l $OUT_O && echo CROSS_OK"
    ;;
  strip)
    S=${TX_OUT:-$TX_SRC.stripped}
    do_exec user 120 "llvm-strip --strip-debug -o $S $TX_SRC && ls -l $TX_SRC $S && echo STRIP_OK"
    ;;
  elf)
    case "$TX_OP" in
      header)  C="readelf -h $TX_FILE" ;;
      sections) C="readelf -SW $TX_FILE" ;;
      symbols) C="readelf -sW $TX_FILE" ;;
      dynamic) C="readelf -dW $TX_FILE" ;;
      *)       C="readelf -h $TX_FILE; echo '--- 段 ---'; readelf -SW $TX_FILE; echo '--- 动态 ---'; readelf -dW $TX_FILE" ;;
    esac
    do_exec user 150 "$C"
    ;;
  size)
    do_exec user 60 "ls -l $TX_FILE; echo '--- 节区体积 ---'; llvm-size -A $TX_FILE 2>/dev/null | head -20"
    ;;
  which)
    do_exec user 40 "for c in $TX_NAMES; do printf '%-12s ' \$c; command -v \$c 2>/dev/null || echo NOT_FOUND; done"
    ;;
  env)
    do_exec user 60 "sh /data/local/tmp/tx_env.sh"
    ;;
  git)
    do_exec root 880 "cd ${TX_DIR:-$TX_H} && git $TX_GITARGS"
    ;;
  pip)
    do_exec root 580 "python3 -m pip install -i https://pypi.tuna.tsinghua.edu.cn/simple --no-cache-dir $TX_PKG"
    ;;
  pkg)
    do_exec root ${TX_T:-300} "python3 /data/adb/lemon_kernel/lemon/tx/txdep.py $TX_SUB $TX_ARG"
    ;;
  curl)
    do_exec root 880 "curl -L -m 860 -o ${TX_CURL_OUT:-dl.bin} $TX_CURL_URL && ls -l ${TX_CURL_OUT:-dl.bin} && echo CURL_OK"
    ;;
  *)
    sed -n '2,18p' "$0"
    exit 1
    ;;
esac