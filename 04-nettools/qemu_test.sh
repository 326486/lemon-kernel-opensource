#!/system/bin/sh
# ============================================================
# lemonlib · qemu_test —— QEMU 真内核测试框架（#264 虚拟机线）
#  v1.1 初版 ｜ v1.2 连跑 ｜ v2.0（2026-09-29）全面升级 ｜ v2.1（2026-09-29）保真度+覆盖率
#
#  v2.0 新增：
#    · --full        增强检查（残留 / taint / 三类用例覆盖率 / 自动报告）
#    · --case <名>   用例驱动（读 testcases/<名>/case.env 声明）
#    · --list        列出全部用例
#    · --json        每轮输出结构化 JSON 结果
#    · 判定规范化     RESULT = PASS|FAIL|NOCOVER|PANIC（带 REASON）
#    · 报告留痕       自动落 检测域 扫描记录/虚拟机/
#
#  v2.1 新增（2026-09-29）：
#    · --cpu <档>     CPU 保真度三档：
#                       legacy = cortex-a57   (ARMv8.0，无 LSE/PAC/BTI/MTE，历史兼容)
#                       modern = cortex-a710  (ARMv9-A，对齐真机特性) ← 默认
#                       max    = -cpu max     (QEMU 全特性，比 a710 更激进)
#    · --cover        函数级覆盖率（kprobe 实现，免 GCOV；参考指标不参与判定）
#    · case.env 支持 CPU= 声明（用例级覆盖全局档位）
#
#  v2.1 实测修正（2 处，均已在虚拟机验证）：
#    修正1  本内核 tracefs 无 events/kprobes/<名>/hits 文件 → init_cover
#           改用读 trace 全文 + 函数名子串计数（原「读 hits」全部落空 COVER=0/0）
#    修正2  JSON / 日志文件名不含时间戳 → 多次运行互相覆盖（轮次证据丢失）
#           → 统一加 -${TSTAMP} 后缀
#    修正3  init_cover 统计挪到 rmmod 之后（一次读 trace 覆盖运行期+退出）
#    修正4  ★MTE 实测不可用：-M virt,mte=on 下真机内核「连 console 都无输出」
#           静默死（-S 暂停态能起 ≠ 能跑，这个坑差点漏掉）→ max 档去掉 mte
# ============================================================
P=/data/data/com.termux/files/usr
CLANG=$P/bin/clang
PY=$P/bin/python3
GZ=/data/adb/magisk/busybox
W=/data/local/tmp/qemu_test_work
KIMG=/data/local/tmp/kernel_Image
MKCPIO=/data/local/tmp/mkcpio3.py
[ -f "$MKCPIO" ] || MKCPIO=/data/local/tmp/mkcpio2.py
LIB=/data/adb/lemon_kernel/lemonlib
LOGDIR=$W/logs
RPTDIR=/data/小柠檬资源/小柠檬bug检测/扫描记录/虚拟机
TC=/data/local/tmp/ko_test/testcases

# ---------- 选项解析（每个分支都 shift，防空转） ----------
MODE=quick
ROUNDS=1
CASE=""
JSONOUT=0
COVER=0
CPUMODE="modern"
while [ $# -gt 0 ]; do
  case "$1" in
    --doctor) exec sh "$LIB/vm_guard.sh" ;;
    --list)   exec sh "$LIB/vm_case.sh" list ;;
    --full)   MODE=full; shift ;;
    --json)   JSONOUT=1; shift ;;
    --cpu)    CPUMODE="${2:-modern}"; shift 2 ;;
    --cover)  COVER=1; shift ;;
    --no-tools) export VM_NO_TOOLS=1; shift ;;
    --case)   CASE="${2:-}"; shift 2 ;;
    -n|--rounds) ROUNDS="${2:-1}"; shift 2 ;;
    --) shift; break ;;
    -*) echo "!! 未知选项: $1"; exit 1 ;;
    *) break ;;
  esac
done

# ---------- CPU 保真度档位（v2.1） ----------
set_cpu_mode() {
  case "$1" in
    legacy) CPUARG="-cpu cortex-a57";  MACHARG="-M virt" ;;
    modern) CPUARG="-cpu cortex-a710"; MACHARG="-M virt" ;;
    max)    CPUARG="-cpu max";        MACHARG="-M virt" ;;
    *) echo "!! 未知 CPU 档位: $1（可选 legacy|modern|max）"; exit 1 ;;
  esac
  CPUMODE="$1"
}
set_cpu_mode "${CPUMODE:-modern}"

KO="${1:-}"; MARGS="${2:-}"; TMO="${3:-200}"; ITYPE="${4:-generic}"

# ---------- 用例驱动：从 case.env 取值（命令行可覆盖） ----------
if [ -n "$CASE" ]; then
  ENVF="$TC/$CASE/case.env"
  [ -f "$ENVF" ] || { echo "!! 用例声明不存在: $ENVF"; exit 1; }
  # ★ 安全解析（禁止 source：case.env 的描述含中文/空格/括号，source 会当命令执行）
  cget() { awk -F= -v k="$1" '$1==k { v=substr($0, index($0,"=")+1); sub(/#.*/,"",v); gsub(/^[ \t]+|[ \t]+$/,"",v); gsub(/^"|"$/,"",v); print v; exit }' "$2"; }
  KO=$(cget KO "$ENVF"); MARGS=$(cget MARGS "$ENVF")
  TMO=$(cget CTMO "$ENVF"); ITYPE=$(cget CITYPE "$ENVF")
  CMINPASS=$(cget CMINPASS "$ENVF"); CEXPECT_FAIL=$(cget CEXPECT_FAIL "$ENVF")
  CEXPECT_TRIAD=$(cget CEXPECT_TRIAD "$ENVF"); CDESC=$(cget CDESC "$ENVF")
  CEXTRA=$(cget EXTRA_FILES "$ENVF")
  CQEMU=$(cget QEMU_ARGS "$ENVF")
  CMEM=$(cget MEM "$ENVF")
  CMAXPL=$(cget MAX_PAYLOAD_MB "$ENVF")
  CCPU=$(cget CPU "$ENVF")
  [ -n "$CCPU" ] && set_cpu_mode "$CCPU"
  [ -z "$TMO" ] && TMO=200
  [ -z "$ITYPE" ] && ITYPE=generic
  KO="${1:-$KO}"; MARGS="${2:-$MARGS}"; TMO="${3:-$TMO}"; ITYPE="${4:-$ITYPE}"
  echo "[case] $CASE ｜ ${CDESC:-无描述}"
fi

[ -z "$KO" ] && { echo "!! 用法: qemu_test <ko> [参数] [超时] [init类型] | --case <用例> | -n <轮次> ... | --full | --list | --doctor"; exit 1; }
case "$ROUNDS" in ''|*[!0-9]*) echo "!! -n 需为正整数"; exit 1 ;; esac
[ "$ROUNDS" -lt 1 ] && ROUNDS=1
[ "$ROUNDS" -gt 20 ] && { echo "!! -n 上限 20（防空转）"; exit 1; }
[ -f "$KO" ] || { echo "!! 模块不存在: $KO"; exit 1; }
[ -f "$KIMG" ] || { echo "!! 内核镜像不存在: $KIMG"; exit 1; }
[ -f "$MKCPIO" ] || { echo "!! mkcpio2.py 不存在: $MKCPIO"; exit 1; }
mkdir -p "$W" "$LOGDIR" "$RPTDIR"

# ---------- --cover：函数级覆盖率准备（v2.1） ----------
if [ "$COVER" = "1" ]; then
  COVERINIT=/data/local/tmp/init_cover.c
  [ -f "$COVERINIT" ] || { echo "!! 缺少覆盖率 init: $COVERINIT"; exit 1; }
  COVERFN="$W/funcs.txt"; COVERPN="$W/params.txt"
  # 函数符号（仅本模块定义的 FUNC，排除 UND；去重；上限 256 与 init 侧一致）
  readelf -sW "$KO" 2>/dev/null | awk '$4=="FUNC" && $7!="UND" {print $8}' \
    | grep -E '^[A-Za-z_][A-Za-z0-9_.]*$' | sort -u | head -256 > "$COVERFN"
  # 模块参数（modinfo 的 parm=；上限 64 与 init 侧一致）
  readelf -p .modinfo "$KO" 2>/dev/null | grep -oE 'parm=[A-Za-z0-9_]+' \
    | sed 's/^parm=//' | sort -u | head -64 > "$COVERPN"
  CN=$(grep -c . "$COVERFN" 2>/dev/null); CN=${CN:-0}
  PN=$(grep -c . "$COVERPN" 2>/dev/null); PN=${PN:-0}
  echo "[cover] 函数符号 $CN 个 ｜ 模块参数 $PN 个"
  [ "$CN" -gt 0 ] || { echo "!! 未提取到函数符号（该 ko 可能无符号表，覆盖率不可用）"; exit 1; }
  ITYPE="cover"
  CEXTRA="$CEXTRA $COVERFN:funcs.txt $COVERPN:params.txt"
  # ★ 覆盖率是参考指标：kprobe 只能覆盖「加载之后仍会触发的路径」，
  #   module_init 期路径抓不到 → 不参与 PASS/FAIL 判定
  CMINPASS=""; CEXPECT_FAIL=""; CEXPECT_TRIAD=""
fi

# ---------- 环境指纹（一次性，供报告与复现） ----------
KO_MD5=$(md5sum "$KO" | cut -d' ' -f1)
KMD5=$(md5sum "$KIMG" | cut -d' ' -f1)
QVER=$("$P/bin/qemu-system-aarch64" --version 2>/dev/null | head -1 | cut -d' ' -f1-3)
KV=$(uname -r)
TSTAMP=$(date '+%Y%m%d-%H%M%S')

# ---------- 准备阶段失败的统一留痕（避免"无结论退出"） ----------
fail_prep() {
  RESULT="FAIL"; REASON="准备阶段失败（$1）"
  PASS_N=0; FAIL_N=0; TN=0; C1=0; C2=0; C3=0
  ELAPSED=0; TEMP_C="?"; RC=9; RESIDUE="none"; TAINT_S="n/a"
  INIT_MD5="-"
  JSONF="$LOGDIR/R${RID}-${CASE:-adhoc}-${RESULT}-${TSTAMP}.json"
  cat > "$JSONF" <<JSONDOC
{"case":"${CASE:-adhoc}","round":$RID,"result":"FAIL","reason":"$REASON",
 "pass":0,"fail":0,"triad_covered":0,"triad_detail":{"positive":0,"negative":0,"closed_loop":0},
 "residue":"none","taint":"n/a","elapsed_s":0,"temp_c":"?","exit_code":9,
 "cpu":"$CPUMODE","cover":"n/a","cover_miss":"-",
 "ko":"$KO","ko_md5":"$KO_MD5","init_md5":"-","kernel_md5":"$KMD5",
 "device_uname":"$KV","qemu":"$QVER","mode":"$MODE",
 "time":"$(date '+%Y-%m-%d %H:%M:%S')","log":"(未生成)"}
JSONDOC
  echo "    ▶ RESULT=$RESULT   REASON=$REASON"
  echo "    JSON: $JSONF"
}

# ---------- 单轮执行 ----------
run_once() {
  RID="$1"
  LOG="$W/qemu_${TSTAMP}_R${RID}.log"
  echo "[1] 模块体检"
  echo "    md5: $KO_MD5  大小: $(wc -c < "$KO") 字节"
  vm=$(readelf -p .modinfo "$KO" 2>/dev/null | grep -oE 'vermagic=[^ ]+ [^ ]+ [^ ]+ [^ ]+ [^ ]+ [^ ]+')
  if echo "${vm#vermagic=}" | grep -q "$KV"; then
    echo "    vermagic: 匹配本机内核"
  else
    echo "    vermagic: ${vm#vermagic=}  (本机 $KV)"
  fi
  segs=0
  for s in .plt .init.plt .text.ftrace_trampoline .init.text .exit.text .modinfo .gnu.linkonce.this_module __versions; do
    readelf -S "$KO" 2>/dev/null | grep -qF "$s" && segs=$((segs+1))
  done
  echo "    关键段: $segs/8"
  echo
  # ★ 安全闸门（前置拦截：防真机设备直通 / 目录共享 / 隐私打包）
  if [ -f "$LIB/vm_safety.sh" ]; then
    if ! sh "$LIB/vm_safety.sh" check-qemu "${CQEMU:-}"; then
      echo "!! 安全闸门拒绝执行：QEMU 参数存在影响真机的风险"; return 9
    fi
    if ! sh "$LIB/vm_safety.sh" check-extra "${CEXTRA:-}"; then
      echo "!! 安全闸门拒绝执行：EXTRA_FILES 含白名单外路径（防隐私外泄）"; return 9
    fi
  fi

  echo "[2] 准备 init"
  case "$ITYPE" in
    generic) INIT_SRC=/data/local/tmp/init_generic.c ;;
    cover)   INIT_SRC=/data/local/tmp/init_cover.c ;;
    part)    INIT_SRC=/data/local/tmp/ko_test/init_nolibc_part.c ;;
    custom:*) INIT_SRC="${ITYPE#custom:}" ;;
    *) echo "    !! 未知 init 类型: $ITYPE"; fail_prep "未知 init 类型"; return 9 ;;
  esac
  [ -f "$INIT_SRC" ] || { echo "    !! init 源码不存在: $INIT_SRC"; fail_prep "init 源码不存在"; return 9; }
  echo "    源码: $INIT_SRC  ($(wc -c < "$INIT_SRC")B)"
  $CLANG --target=aarch64-linux-android24 -nostdlib -static -O2 -ffreestanding \
    -fno-builtin -fno-stack-protector -fno-asynchronous-unwind-tables \
    -o "$W/init" "$INIT_SRC" -Wl,-e,_start > "$W/build.log" 2>&1
  if [ $? != 0 ]; then echo "    编译失败:"; head -8 "$W/build.log"; fail_prep "init 编译失败"; return 9; fi
  echo "    编译成功: $(wc -c < "$W/init") 字节"
  INIT_MD5=$(md5sum "$W/init" | cut -d' ' -f1)
  echo
  echo "[3] 建 initramfs"
  # ★ 载荷上限：case.env 的 MAX_PAYLOAD_MB 可覆盖（默认 32MB，防 initrd 过大）
  VM_MAX_PAYLOAD_MB="${CMAXPL:-32}" $PY "$MKCPIO" "$W/ir.cpio" "$W/init" "$KO" ${CEXTRA:-} 2>&1 | sed 's/^/    /'
  # ★ 联动护栏：initrd(未压缩) 必须 ≤ 内存 × 0.5，否则解包阶段可能压爆内存
  IRSZ=$(wc -c < "$W/ir.cpio" 2>/dev/null); IRSZ=${IRSZ:-0}
  MEMNUM=$(echo "${CMEM:-512M}" | sed 's/[Mm]$//' | sed 's/[Gg]$//')
  case "${CMEM:-512M}" in *G|*g) MEMMB=$((MEMNUM*1024)) ;; *) MEMMB=${MEMNUM:-512} ;; esac
  # ★ 用 MB 比较（禁用 MEMMB*1048576：2048M → 2GB 会触发 mksh 32 位溢出！）
  IRSZ_MB=$((IRSZ / 1048576))
  if [ "$MEMMB" -gt 0 ] && [ "$IRSZ_MB" -gt $((MEMMB / 2)) ]; then
    echo "!! 联动护栏拒绝：initrd 未压缩 ${IRSZ_MB}MB > 内存 ${MEMMB}MB 的一半"
    echo "   → 请在 case.env 提高 MEM=（当前 ${CMEM:-512M}）"
    fail_prep "initrd 过大(相对内存)"; return 9
  fi
  $GZ gzip -9 -c "$W/ir.cpio" > "$W/ir.cpio.gz"
  echo "    压缩后: $(wc -c < "$W/ir.cpio.gz") 字节"
  echo
  echo "[4] 启动 QEMU（${TMO}s 超时）"
  export PATH=$P/bin:$PATH
  export LD_LIBRARY_PATH=$P/lib
  APPEND="console=ttyAMA0 rdinit=/init loglevel=7"
  [ -n "$MARGS" ] && APPEND="$APPEND module_args=$MARGS"
  T0=$(date +%s)
  # ★ 内存：case.env 的 MEM= 优先；QEMU_ARGS 已含 -m 时不重复；默认 512M
  MEMARG="-m ${CMEM:-512M}"
  case "${CQEMU:-}" in *"-m "*) MEMARG="" ;; esac
  timeout "$TMO" $P/bin/qemu-system-aarch64 $MACHARG $CPUARG $MEMARG \
    -nographic -no-reboot -accel tcg ${CQEMU:-} \
    -kernel "$KIMG" -initrd "$W/ir.cpio.gz" \
    -append "$APPEND" > "$LOG" 2>&1
  RC=$?
  T1=$(date +%s); ELAPSED=$((T1-T0))
  TEMP=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null)
  [ -n "${TEMP:-}" ] && TEMP_C=$((TEMP/1000)) || TEMP_C="?"
  echo "    退出码: $RC  耗时: ${ELAPSED}s  温度: ${TEMP_C}°C"
  echo "    日志: $LOG"
  echo
  echo "[5] 测试输出"
  echo "--------------------------------------------------"
  sed -n '/qemu_test · 通用内核模块测试/,$p' "$LOG" 2>/dev/null \
    | grep -vE 'NoHello|KERNEL_SECURITY_CHECK|\+ KP ' | head -60
  echo "--------------------------------------------------"
  echo

  # ---------- [6] 规范化判定 ----------
  echo "[6] 判定（规范化）"
  PASS_N=$(grep -cF '[PASS]' "$LOG" 2>/dev/null)
  FAIL_N=$(grep -cF '[FAIL]' "$LOG" 2>/dev/null)
  PANIC=$(grep -E 'Kernel panic|Unable to handle kernel|Internal error:|kernel BUG at|Oops' "$LOG" 2>/dev/null | grep -vE 'NoHello|\+ KP ' | head -3)
  # 三类用例覆盖率（正例/反例/因果闭环）
  # ★ 判据放宽：同时接受 [正例] 与「正例：」两种写法（避免格式差异造成假 NOCOVER）
  C1=$(grep -cE '\[正例[^]]*\]|正例[：:]' "$LOG" 2>/dev/null); C1=${C1:-0}
  C2=$(grep -cE '\[反例[^]]*\]|反例[：:]' "$LOG" 2>/dev/null); C2=${C2:-0}
  C3=$(grep -cE '\[闭环[^]]*\]|因果闭环|闭环[：:]' "$LOG" 2>/dev/null); C3=${C3:-0}
  TN=0; [ "$C1" -gt 0 ] && TN=$((TN+1)); [ "$C2" -gt 0 ] && TN=$((TN+1)); [ "$C3" -gt 0 ] && TN=$((TN+1))
  # 残留检查（卸载后 /proc/modules 段）
  MODNAME=$(basename "$KO" .ko)
  RESIDUE="none"
  if grep -q "$MODNAME " "$LOG" 2>/dev/null; then
    LAST=$(grep -n '卸载' "$LOG" 2>/dev/null | tail -1 | cut -d: -f1)
    if [ -n "$LAST" ]; then
      AFTER=$(sed -n "$((LAST+1)),\$p" "$LOG" 2>/dev/null | grep -c "$MODNAME ")
      [ "${AFTER:-0}" -gt 0 ] && RESIDUE="$MODNAME(卸载后仍见)"
    fi
  fi
  # 内核 taint 踪迹（日志内）
  TAINT_S=$(grep -oE 'taint[a-z ]*[:=]? *[0-9A-Z]+' "$LOG" 2>/dev/null | tail -1)
  [ -z "$TAINT_S" ] && TAINT_S="n/a"
  # ★ 覆盖率（v2.1）——参考指标，不参与判定
  COVERV=$(grep -oE 'COVER=[0-9]+/[0-9]+' "$LOG" 2>/dev/null | tail -1 | cut -d= -f2)
  COVERM=$(grep -oE 'COVER_MISS=[^ ]*' "$LOG" 2>/dev/null | tail -1 | cut -d= -f2-)
  [ -z "$COVERV" ] && COVERV="n/a"
  [ -z "$COVERM" ] && COVERM="-"

  RESULT="PASS"; REASON="全部断言通过"
  if [ -n "$PANIC" ]; then
    RESULT="PANIC"; REASON="内核异常：$(echo "$PANIC" | head -1)"
  elif [ "$RC" = "9" ]; then
    RESULT="FAIL"; REASON="准备阶段失败（init 编译/路径）"
  elif [ "${PASS_N:-0}" = "0" ]; then
    RESULT="FAIL"; REASON="无任何 PASS 断言（可能未跑起来）"
  elif [ "${FAIL_N:-0}" -gt 0 ]; then
    # ★ 已知预期失败：FAIL 数与 case.env 声明一致 → 判 PASS，但 REASON 如实标注
    if [ -n "${CEXPECT_FAIL:-}" ] && [ "${FAIL_N:-0}" = "$CEXPECT_FAIL" ]; then
      RESULT="PASS"; REASON="通过（含 $FAIL_N 条已知预期失败，已在 case.env 显式声明）"
    else
      RESULT="FAIL"; REASON="存在 FAIL 断言 $FAIL_N 条（声明期望 ${CEXPECT_FAIL:-0} 条）"
    fi
  elif [ -n "${CEXPECT_TRIAD:-}" ] && [ "$CEXPECT_TRIAD" = "required" ] && [ "$TN" -lt 3 ]; then
    RESULT="NOCOVER"; REASON="三类用例覆盖不足（$TN/3）"
  elif [ -n "${CMINPASS:-}" ] && [ "${PASS_N:-0}" -lt "$CMINPASS" ]; then
    RESULT="FAIL"; REASON="PASS 数（$PASS_N）低于声明期望（$CMINPASS）"
  elif [ -n "${CEXPECT_FAIL:-}" ] && [ "${FAIL_N:-0}" != "$CEXPECT_FAIL" ]; then
    RESULT="FAIL"; REASON="FAIL 数（$FAIL_N）与声明期望（$CEXPECT_FAIL）不符"
  fi

  echo "    PASS=$PASS_N  FAIL=$FAIL_N  三类覆盖=$TN/3  (正例$C1/反例$C2/闭环$C3)"
  echo "    残留: $RESIDUE   taint: $TAINT_S"
  [ "$COVERV" != "n/a" ] && echo "    ★ 覆盖率: $COVERV   未命中: $COVERM"
  [ -n "$PANIC" ] && { echo "    ❌ 内核异常："; echo "$PANIC" | sed 's/^/      /'; }
  echo "    ▶ RESULT=$RESULT   REASON=$REASON"

  # ---------- [7] 结构化 JSON ----------
  JSONF="$LOGDIR/R${RID}-${CASE:-adhoc}-${RESULT}-${TSTAMP}.json"
  cat > "$JSONF" <<JSONDOC
{"case":"${CASE:-adhoc}","round":$RID,"result":"$RESULT","reason":"$REASON",
 "pass":${PASS_N:-0},"fail":${FAIL_N:-0},"triad_covered":$TN,
 "triad_detail":{"positive":$C1,"negative":$C2,"closed_loop":$C3},
 "residue":"$RESIDUE","taint":"$TAINT_S","elapsed_s":$ELAPSED,"temp_c":"$TEMP_C",
 "cpu":"$CPUMODE","cover":"$COVERV","cover_miss":"$COVERM",
 "exit_code":$RC,"ko":"$KO","ko_md5":"$KO_MD5","init_md5":"$INIT_MD5",
 "kernel_md5":"$KMD5","device_uname":"$KV","qemu":"$QVER","mode":"$MODE",
 "time":"$(date '+%Y-%m-%d %H:%M:%S')","log":"$LOG"}
JSONDOC
  [ "$JSONOUT" = "1" ] && { echo "    JSON: $JSONF"; }
  return 0
}

echo "=================================================="
echo " 🍋 qemu_test · 真内核测试框架  v2.1"
echo " 模式: $MODE   轮次: $ROUNDS"
echo " 用例: ${CASE:-（临时）}"
echo " 模块: $KO"
echo " 参数: ${MARGS:-（无）}   init: $ITYPE   内存: ${CMEM:-512M}"
[ "$COVER" = "1" ] && CVS=开 || CVS=关
echo " CPU : $CPUMODE  ($CPUARG)   覆盖率: $CVS"
echo " 指纹: ko=${KO_MD5%${KO_MD5#????????}}…  kernel=${KMD5%${KMD5#????????}}…  $QVER"
echo "=================================================="
echo
if [ "$ROUNDS" -gt 1 ] || [ "$MODE" = "full" ]; then
  sh "$LIB/vm_guard.sh" --quiet || echo " ⚠️ 哨兵告警：环境有 FAIL 项"
  echo
fi

SUMTXT=""; CSVF="$LOGDIR/rounds_${TSTAMP}.csv"
echo "round,result,pass,fail,triad,elapsed_s,temp_c,log" > "$CSVF"
K=1
while [ "$K" -le "$ROUNDS" ]; do
  echo "################ 轮次 R$K / $ROUNDS ################"
  run_once "$K"
  RLOG="$LOGDIR/R${K}-${CASE:-adhoc}-${RESULT}-${TSTAMP}.log"
  cp -f "$LOG" "$RLOG" 2>/dev/null
  echo "round,$RESULT,${PASS_N:-0},${FAIL_N:-0},$TN,$ELAPSED,$TEMP_C,$RLOG" >> "$CSVF"
  # ★ 归档进虚拟机专属存储（10GB · #267）
  if [ -d /data/lemon_vm/runs ]; then
    cp -f "$JSONF" /data/lemon_vm/runs/ 2>/dev/null
    cp -f "$RLOG"  /data/lemon_vm/runs/ 2>/dev/null
  fi
  SUMTXT="${SUMTXT}  R${K}: ${RESULT}  PASS=${PASS_N} FAIL=${FAIL_N}  覆盖=${TN}/3  ${ELAPSED}s  ${TEMP_C}°C  -> ${RLOG}
"
  K=$((K+1))
  echo
done

echo "=================================================="
echo " 🍋 轮次汇总"
printf '%s' "$SUMTXT"
echo " CSV: $CSVF"
echo "=================================================="

# ---------- [8] --full：自动报告 ----------
if [ "$MODE" = "full" ]; then
  RP="$RPTDIR/${TSTAMP}-${CASE:-adhoc}-${RESULT}.md"
  {
    echo "# 虚拟机测试报告（--full）"
    echo
    echo "| 项 | 值 |"
    echo "|---|---|"
    echo "| 时间 | $(date '+%Y-%m-%d %H:%M:%S') |"
    echo "| 用例 | ${CASE:-adhoc} |"
    echo "| 模块 | $KO |"
    echo "| ko md5 | $KO_MD5 |"
    echo "| init md5 | $INIT_MD5 |"
    echo "| 内核 md5 | $KMD5 |"
    echo "| 设备内核 | $KV |"
    echo "| QEMU | $QVER |"
    echo "| CPU 档位 | $CPUMODE ($CPUARG) |"
    echo "| 轮次 | $ROUNDS |"
    echo "| 最终结果 | **$RESULT** |"
    echo "| 三类覆盖 | $TN/3（正例$C1 反例$C2 闭环$C3）|"
    echo "| 覆盖率 | $COVERV（未命中: $COVERM）|"
    echo "| 残留 | $RESIDUE |"
    echo "| taint | $TAINT_S |"
    echo
    echo "## 轮次明细"
    echo
    echo '```'
    printf '%s' "$SUMTXT"
    echo '```'
    echo
    echo "## 原始日志"
    echo '```'
    sed -n '/qemu_test · 通用内核模块测试/,$p' "$LOG" 2>/dev/null \
      | grep -vE 'NoHello|KERNEL_SECURITY_CHECK|\+ KP ' | head -50
    echo '```'
    echo
    echo "> 报告由 qemu_test v2.1 --full 自动生成 ｜ 检测域 扫描记录/虚拟机/"
  } > "$RP"
  echo " 📄 报告: $RP"
  if [ -d /data/lemon_vm/runs ]; then cp -f "$RP" /data/lemon_vm/runs/ 2>/dev/null; fi
  echo "=================================================="
fi

echo "VM_RESULT=$RESULT"
[ "$RESULT" = "PASS" ] && exit 0 || exit 1
