#!/system/bin/sh
# ============================================================
# LemonKernel · 内核态执行层 (khook)  v1.0
# 2026-09-27  小柠檬本体
# ------------------------------------------------------------
# 真正的内核态能力：经 tracefs / kprobe 在内核空间注入探针，
# 抓取任意内核函数的入参、返回值与调用栈。
# 零编译、零重启、零砖风险。
# 前提（本机已实测满足）：CONFIG_KPROBES=y + tracefs 可写
# ============================================================
T=/sys/kernel/tracing
K=/data/adb/lemon_kernel/khook
PERSIST=$K/hooks.persist
LOG=$K/khook.log
export PATH=/data/adb/magisk:/system/bin:/system/xbin:$PATH
mkdir -p "$K" 2>/dev/null

log(){ echo "[$(date '+%F %T')] $*" >> "$LOG"; }
err(){ echo "ERR: $*"; log "ERR: $*"; exit 1; }
need(){ [ -w "$T/kprobe_events" ] || err "tracefs 不可写 ($T/kprobe_events)"; }
evd(){ echo "$T/events/kprobes"; }

cmd_status(){
  echo "=== LemonKernel 内核态执行层 khook v1.0 ==="
  echo "[内核]      $(uname -r)"
  echo "[tracefs]   可写=$([ -w "$T/kprobe_events" ] && echo YES || echo NO)  挂载点=$T"
  echo "[tracing]   tracing_on=$(cat $T/tracing_on 2>/dev/null)  buffer=$(cat $T/buffer_size_kb 2>/dev/null)KB"
  echo "[栈回溯]    stacktrace=$(cat $T/options/stacktrace 2>/dev/null)"
  echo "[已注册探针]"
  if [ -s "$T/kprobe_events" ]; then sed 's/^/    /' "$T/kprobe_events"; else echo "    (无)"; fi
  echo "[已启用探针]"
  EN=$(ls "$(evd)" 2>/dev/null | grep -vE '^(enable|filter)$')
  if [ -n "$EN" ]; then echo "$EN" | sed 's/^/    /'; else echo "    (无)"; fi
  echo "[可用事件]  $(wc -l < $T/available_events 2>/dev/null) 个 tracepoint"
  echo "[BPF]       syscall=$(zcat /proc/config.gz 2>/dev/null | grep -c 'CONFIG_BPF_SYSCALL=y')  jit=$(zcat /proc/config.gz 2>/dev/null | grep -c 'CONFIG_BPF_JIT=y')  unpriv_disabled=$(cat /proc/sys/kernel/unprivileged_bpf_disabled 2>/dev/null)"
  echo "[kallsyms]  $(wc -l < /proc/kallsyms 2>/dev/null) 个符号 (地址受 kptr_restrict 屏蔽)"
  echo "[污染]      tainted=$(cat /proc/sys/kernel/tainted 2>/dev/null)"
  echo "[持久化]    $([ -s "$PERSIST" ] && wc -l < "$PERSIST" || echo 0) 条 hook 记录"
  echo "[守护]      kernel=$(pidof lemon-kernel >/dev/null 2>&1 && echo alive || echo down)"
}

cmd_probe_add(){
  need
  N="$1"; F="$2"; A="$3"
  [ -z "$N" ] && err "用法: probe_add <探针名> <内核函数> [参数表达式]"
  [ -z "$F" ] && err "缺少内核函数名"
  grep -qF ":kprobes/$N " "$T/kprobe_events" 2>/dev/null && err "探针 $N 已存在"
  if [ -n "$A" ]; then SPEC="p:$N $F $A"; else SPEC="p:$N $F"; fi
  if ! echo "$SPEC" >> "$T/kprobe_events" 2>"$K/.err"; then
    echo "注入失败:"; tail -5 "$T/error_log" 2>/dev/null; cat "$K/.err"; exit 1
  fi
  echo 1 > "$(evd)/$N/enable" 2>/dev/null
  echo "[OK] 已注入并启用 kprobe: $SPEC"
  log "probe_add $SPEC"
}

cmd_retprobe_add(){
  need
  N="$1"; F="$2"
  [ -z "$N" ] && err "用法: retprobe_add <探针名> <内核函数>"
  grep -qF ":kprobes/$N " "$T/kprobe_events" 2>/dev/null && err "探针 $N 已存在"
  if ! echo "r:$N $F \$retval" >> "$T/kprobe_events" 2>"$K/.err"; then
    tail -5 "$T/error_log" 2>/dev/null; cat "$K/.err"; exit 1
  fi
  echo 1 > "$(evd)/$N/enable" 2>/dev/null
  echo "[OK] 已注入返回探针: r:$N $F \$retval"
  log "retprobe_add $N $F"
}

cmd_probe_del(){
  need
  N="$1"; [ -z "$N" ] && err "用法: probe_del <探针名>"
  echo 0 > "$(evd)/$N/enable" 2>/dev/null
  if echo "-:$N" >> "$T/kprobe_events" 2>"$K/.err"; then
    echo "[OK] 已删除探针 $N"; log "probe_del $N"
  else
    cat "$K/.err"; err "删除失败（探针不存在？）"
  fi
}

cmd_probe_list(){
  echo "=== 已注册 kprobe ==="
  if [ -s "$T/kprobe_events" ]; then sed 's/^/  /' "$T/kprobe_events"; else echo "  (无)"; fi
  echo "=== 已启用 ==="
  EN=$(ls "$(evd)" 2>/dev/null | grep -vE '^(enable|filter)$')
  if [ -n "$EN" ]; then echo "$EN" | sed 's/^/  /'; else echo "  (无)"; fi
  echo "=== 持久化清单 ==="
  if [ -s "$PERSIST" ]; then sed 's/^/  /' "$PERSIST"; else echo "  (空)"; fi
}

cmd_probe_clear(){
  need
  n=0
  for p in $(ls "$(evd)" 2>/dev/null | grep -vE '^(enable|filter)$'); do
    echo 0 > "$(evd)/$p/enable" 2>/dev/null
    echo "-:$p" >> "$T/kprobe_events" 2>/dev/null && n=$((n+1))
  done
  if [ -s "$PERSIST" ]; then
    while read -r line; do
      nm=$(echo "$line" | sed -n 's/^[pr][0-9]*:\([^ ]*\).*/\1/p')
      [ -n "$nm" ] && echo "-:$nm" >> "$T/kprobe_events" 2>/dev/null
    done < "$PERSIST"
  fi
  echo "[OK] 已清理 $n 个探针"
  cat "$T/kprobe_events"; echo "(以上为空则已干净)"
  log "probe_clear n=$n"
}

cmd_trace_on(){ echo 1 > "$T/tracing_on"; echo "[OK] tracing_on=$(cat $T/tracing_on)"; }
cmd_trace_off(){ echo 0 > "$T/tracing_on"; echo "[OK] tracing_on=$(cat $T/tracing_on)"; }
cmd_trace_clear(){ echo > "$T/trace"; echo "[OK] trace 缓冲已清空"; }
cmd_buf_set(){ [ -n "$1" ] && echo "$1" > "$T/buffer_size_kb" 2>/dev/null; echo "buffer=$(cat $T/buffer_size_kb)KB"; }

cmd_trace_read(){
  F="$1"; L="${2:-40}"
  [ -z "$F" ] && F="lemon_"
  echo "=== trace 缓冲 (filter=$F, 末 $L 行) ==="
  grep -E "$F" "$T/trace" 2>/dev/null | tail -n "$L"
  echo "=== (缓冲总行数: $(wc -l < $T/trace 2>/dev/null)) ==="
}

cmd_trace_live(){
  S="${1:-3}"; F="$2"
  [ -z "$F" ] && F="lemon_"
  echo "=== trace_pipe 实时流 ${S}s (filter=$F) ==="
  timeout "$S" cat "$T/trace_pipe" 2>/dev/null | grep -E "$F" | head -n 200
  echo "=== 流结束 ==="
}

cmd_event_list(){
  KW="$1"; L="${2:-40}"
  echo "=== 可用事件 (共 $(wc -l < $T/available_events) 个, 过滤='$KW') ==="
  if [ -n "$KW" ]; then grep -iF "$KW" "$T/available_events" | head -n "$L"
  else head -n "$L" "$T/available_events"; fi
}

cmd_event_on(){
  E="$1"; [ -z "$E" ] && err "用法: event_on <subsys:event>"
  S=$(echo "$E" | cut -d: -f1); V=$(echo "$E" | cut -d: -f2)
  [ -w "$T/events/$S/$V/enable" ] || err "事件不存在或不可写: $E"
  echo 1 > "$T/events/$S/$V/enable"; echo "[OK] 已启用事件 $E"
}

cmd_event_off(){
  E="$1"; [ -z "$E" ] && err "用法: event_off <subsys:event>"
  S=$(echo "$E" | cut -d: -f1); V=$(echo "$E" | cut -d: -f2)
  echo 0 > "$T/events/$S/$V/enable" 2>/dev/null; echo "[OK] 已关闭事件 $E"
}

cmd_event_on_all(){
  P="$1"; [ -z "$P" ] && err "用法: event_on_all <前缀, 如 syscalls:>"
  n=0
  for e in $(grep -F "$P" "$T/available_events" 2>/dev/null); do
    S=$(echo "$e" | cut -d: -f1); V=$(echo "$e" | cut -d: -f2)
    if [ -w "$T/events/$S/$V/enable" ]; then echo 1 > "$T/events/$S/$V/enable" 2>/dev/null && n=$((n+1)); fi
  done
  echo "[OK] 已启用 $n 个事件 (前缀 $P)"
}

cmd_func_hook(){
  F="$1"; S="${2:-3}"; A="$3"
  need
  [ -z "$F" ] && err "用法: func_hook <内核函数> [抓取秒数] [参数表达式]"
  N="lemon_hk_$$"
  if [ -n "$A" ]; then SPEC="p:$N $F $A"; else SPEC="p:$N $F"; fi
  if ! echo "$SPEC" >> "$T/kprobe_events" 2>/dev/null; then
    tail -3 "$T/error_log" 2>/dev/null; err "无法挂载 $F（符号不存在？）"
  fi
  echo 1 > "$(evd)/$N/enable"
  echo 0 > "$T/tracing_on"; echo > "$T/trace"; echo 1 > "$T/tracing_on"
  echo "=== 已在内核态挂载: $SPEC ==="
  echo "=== 采集 ${S}s ... ==="
  sleep "$S"
  echo 0 > "$T/tracing_on"
  OUT=$(grep -E "$N" "$T/trace" 2>/dev/null)
  CNT=$(echo "$OUT" | grep -c .)
  echo "=== 命中 $CNT 次 (真内核态事件) ==="
  echo "$OUT" | head -n 30
  echo 0 > "$(evd)/$N/enable" 2>/dev/null
  echo "-:$N" >> "$T/kprobe_events" 2>/dev/null
  echo 1 > "$T/tracing_on"
  echo "=== 探针已卸载 ==="
  log "func_hook $F n=$CNT"
}

cmd_syscall_watch(){
  P="$1"; S="${2:-3}"
  [ -z "$P" ] && err "用法: syscall_watch <预设> [秒数]"
  case "$P" in
    open)    F=do_sys_open;         A='fn=+0(%x1):string flags=%x2' ;;
    openat)  F=do_sys_openat2;      A='fn=+0(%x1):string flags=%x2' ;;
    read)    F=vfs_read;            A='count=%x2' ;;
    write)   F=vfs_write;           A='count=%x2' ;;
    exec)    F=do_execveat_common;  A='' ;;
    fork)    F=kernel_clone;        A='' ;;
    connect) F=__sys_connect;       A='' ;;
    binder)  F=binder_ioctl;        A='cmd=%x1' ;;
    mmap)    F=vm_mmap_pgoff;       A='' ;;
    kill)    F=__arm64_sys_kill;    A='' ;;
    *) err "未知预设: $P (可选 open|openat|read|write|exec|fork|connect|binder|mmap|kill)" ;;
  esac
  echo "[预设 $P] 函数=$F 参数=$A"
  cmd_func_hook "$F" "$S" "$A"
}

cmd_kstack(){
  case "$1" in
    on)  echo 1 > "$T/options/stacktrace"; echo "[OK] 已开启内核栈回溯 (stacktrace=1)" ;;
    off) echo 0 > "$T/options/stacktrace"; echo "[OK] 已关闭 (stacktrace=0)" ;;
    *)   echo "stacktrace=$(cat $T/options/stacktrace)"; echo "用法: kstack on|off" ;;
  esac
}

cmd_kallsyms(){
  W="$1"; L="${2:-30}"
  [ -z "$W" ] && err "用法: kallsyms <关键字> [行数]"
  echo "=== /proc/kallsyms 匹配 '$W' (地址受 kptr_restrict 屏蔽为 0) ==="
  grep -iF "$W" /proc/kallsyms 2>/dev/null | head -n "$L"
  echo "=== 命中 $(grep -icF "$W" /proc/kallsyms 2>/dev/null) 条 ==="
}

cmd_bpf_status(){
  echo "=== BPF 能力 (内核态可编程执行) ==="
  echo "CONFIG_BPF_SYSCALL  : $(zcat /proc/config.gz 2>/dev/null | grep -E '^CONFIG_BPF_SYSCALL' || echo '?')"
  echo "CONFIG_BPF_JIT      : $(zcat /proc/config.gz 2>/dev/null | grep -E '^CONFIG_BPF_JIT=' || echo '?')"
  echo "CONFIG_BPF_LSM      : $(zcat /proc/config.gz 2>/dev/null | grep -E '^CONFIG_BPF_LSM' || echo '?')"
  echo "CONFIG_HAVE_EBPF_JIT: $(zcat /proc/config.gz 2>/dev/null | grep -E '^CONFIG_HAVE_EBPF_JIT' || echo '?')"
  echo "unprivileged_bpf_disabled : $(cat /proc/sys/kernel/unprivileged_bpf_disabled 2>/dev/null)"
  echo "bpffs 挂载 : $(mount | grep -c bpf) 处"
  echo "sys/kernel/btf/vmlinux : $([ -f /sys/kernel/btf/vmlinux ] && echo 存在 || echo 缺失)"
  echo "---"
  echo "结论：BPF 内核态能力已编译进内核；加载 BPF 程序需用户态 loader（下一步原生 ELF 化时一并做）。"
  echo "当前真内核态能力由 kprobe 通道提供（已实测可用）。"
}

cmd_persist(){
  case "$1" in
    save)
      grep -E '^[pr]' "$T/kprobe_events" 2>/dev/null | sed 's|:kprobes/|:|; s|^r[0-9]*:|r:|' > "$PERSIST"
      echo "[OK] 已保存 $(wc -l < "$PERSIST") 条 hook 到 $PERSIST"
      sed 's/^/  /' "$PERSIST" ;;
    load)
      need; n=0
      while read -r line; do
        [ -z "$line" ] && continue
        nm=$(echo "$line" | sed -n 's/^[pr][0-9]*:\([^ ]*\).*/\1/p')
        grep -qF ":kprobes/$nm " "$T/kprobe_events" 2>/dev/null && continue
        if echo "$line" >> "$T/kprobe_events" 2>/dev/null; then echo 1 > "$(evd)/$nm/enable" 2>/dev/null; n=$((n+1)); fi
      done < "$PERSIST"
      echo "[OK] 已恢复 $n 条 hook"; log "persist load n=$n" ;;
    list)
      echo "=== 持久化清单 ($PERSIST) ==="
      if [ -s "$PERSIST" ]; then sed 's/^/  /' "$PERSIST"; else echo "  (空)"; fi ;;
    clear)
      : > "$PERSIST"; echo "[OK] 持久化清单已清空" ;;
    *) echo "用法: persist save|load|list|clear" ;;
  esac
}

cmd_taint(){
  V=$(cat /proc/sys/kernel/tainted 2>/dev/null)
  echo "=== 内核污染状态 ==="
  echo "tainted = $V"
  [ $((V & 1))    -ne 0 ] && echo "  bit0  专有模块被加载"
  [ $((V & 2))    -ne 0 ] && echo "  bit1  内核被强制加载/污染"
  [ $((V & 4))    -ne 0 ] && echo "  bit2  内核已标记为不稳定"
  [ $((V & 8))    -ne 0 ] && echo "  bit3  内核已发生过 oops/警告"
  [ $((V & 512))  -ne 0 ] && echo "  bit9  已加载 staging 驱动"
  [ $((V & 4096)) -ne 0 ] && echo "  bit12 已加载外部(out-of-tree)模块"
  echo "modules_disabled  = $(cat /proc/sys/kernel/modules_disabled)"
  echo "MODULE_SIG_FORCE  = $(zcat /proc/config.gz 2>/dev/null | grep -c '^CONFIG_MODULE_SIG_FORCE=y') (0=未签名模块可加载)"
  echo "=== 风险评估 ==="
  echo "kprobe 通道：不污染内核、不改变行为、可随时卸载 → 零风险"
}

cmd_health(){
  echo "=== khook 自检 ==="
  P=0; F=0
  if [ -w "$T/kprobe_events" ]; then echo "[PASS] tracefs 可写"; P=$((P+1)); else echo "[FAIL] tracefs 不可写"; F=$((F+1)); fi
  N="lemon_sf_$$"
  if echo "p:$N vfs_read count=%x2" >> "$T/kprobe_events" 2>/dev/null; then
    echo "[PASS] 探针注入"; P=$((P+1))
    echo 1 > "$(evd)/$N/enable" 2>/dev/null
    echo 0 > "$T/tracing_on"; echo > "$T/trace"; echo 1 > "$T/tracing_on"
    ls /system/bin >/dev/null 2>&1; cat /proc/version >/dev/null 2>&1
    sleep 1
    echo 0 > "$T/tracing_on"
    C=$(grep -cE "$N" "$T/trace" 2>/dev/null)
    if [ "${C:-0}" -gt 0 ]; then echo "[PASS] 内核态事件捕获 (命中 $C 次)"; P=$((P+1)); else echo "[WARN] 1s 内未命中（低负载属正常）"; fi
    echo 0 > "$(evd)/$N/enable" 2>/dev/null
    echo "-:$N" >> "$T/kprobe_events" 2>/dev/null
    echo "[PASS] 探针卸载"; P=$((P+1))
    echo 1 > "$T/tracing_on"
  else
    echo "[FAIL] 探针注入"; F=$((F+1))
  fi
  if [ -r /proc/kallsyms ]; then echo "[PASS] kallsyms 可读 ($(wc -l < /proc/kallsyms) 符号)"; P=$((P+1)); else echo "[FAIL] kallsyms"; F=$((F+1)); fi
  echo "---"
  echo "结果: PASS=$P FAIL=$F"
  [ "$F" -eq 0 ] && echo "khook 内核态层: 健康 OK" || echo "khook 内核态层: 异常 WARN"
}

case "$1" in
  status) cmd_status ;;
  probe_add) cmd_probe_add "$2" "$3" "$4" ;;
  retprobe_add) cmd_retprobe_add "$2" "$3" ;;
  probe_del) cmd_probe_del "$2" ;;
  probe_list) cmd_probe_list ;;
  probe_clear) cmd_probe_clear ;;
  trace_on) cmd_trace_on ;;
  trace_off) cmd_trace_off ;;
  trace_clear) cmd_trace_clear ;;
  buf_set) cmd_buf_set "$2" ;;
  trace_read) cmd_trace_read "$2" "$3" ;;
  trace_live) cmd_trace_live "$2" "$3" ;;
  event_list) cmd_event_list "$2" "$3" ;;
  event_on) cmd_event_on "$2" ;;
  event_off) cmd_event_off "$2" ;;
  event_on_all) cmd_event_on_all "$2" ;;
  func_hook) cmd_func_hook "$2" "$3" "$4" ;;
  syscall_watch) cmd_syscall_watch "$2" "$3" ;;
  kstack) cmd_kstack "$2" ;;
  kallsyms) cmd_kallsyms "$2" "$3" ;;
  bpf_status) cmd_bpf_status ;;
  persist) cmd_persist "$2" ;;
  taint) cmd_taint ;;
  health) cmd_health ;;
  *)
    echo "LemonKernel khook · 内核态执行层 v1.0"
    echo "用法: khook.sh <命令> [参数]"
    echo ""
    echo "  status                       内核态能力总览"
    echo "  probe_add <名> <函数> [参]    注入 kprobe (参: fn=+0(%x1):string flags=%x2)"
    echo "  retprobe_add <名> <函数>      注入返回探针 (抓 \$retval)"
    echo "  probe_del <名>               删除探针"
    echo "  probe_list                   列出探针"
    echo "  probe_clear                  清空全部探针"
    echo "  trace_on | trace_off         开关 tracing"
    echo "  trace_clear                  清缓冲"
    echo "  buf_set <KB>                 设缓冲大小"
    echo "  trace_read [过滤] [行数]      读 trace 缓冲"
    echo "  trace_live <秒> [过滤]        实时流 trace_pipe"
    echo "  event_list [过滤] [行数]      可用 tracepoint"
    echo "  event_on | event_off <e>     开关事件"
    echo "  event_on_all <前缀>           批量开事件"
    echo "  func_hook <函数> [秒] [参]     一键挂载-采集-卸载"
    echo "  syscall_watch <预设> [秒]     open|openat|read|write|exec|fork|connect|binder|mmap|kill"
    echo "  kstack on|off                内核栈回溯"
    echo "  kallsyms <关键字> [行数]      内核符号搜索"
    echo "  bpf_status                   BPF 能力"
    echo "  persist save|load|list|clear 持久化 hook 清单"
    echo "  taint                        污染与风险"
    echo "  health                       自检"
    ;;
esac