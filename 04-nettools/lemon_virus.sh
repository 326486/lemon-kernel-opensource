#!/system/bin/sh
# ============================================================
# lemon_virus.sh v1.0 · 病毒拦截（检测 + 处置 + 应急）
# 20261004 · 小柠檬本体 · 授权：小良
# ------------------------------------------------------------
# 依赖: virusdb.sh（病毒库：/data/adb/lemon_kernel/conf/virusdb）
# 用法:
#   lemon_virus.sh scan [--deep]        扫描已装第三方应用
#   lemon_virus.sh list                 查看上次扫描结果
#   lemon_virus.sh front                当前前台包名
#   lemon_virus.sh act <pkg> <P0|P1> [--remove]  处置单个
#   lemon_virus.sh panic [--force] [--remove]    应急（快捷键入口）
#   lemon_virus.sh a11y [list|off [pkg]]         无障碍管理
#   lemon_virus.sh unfreeze <pkg>       解冻恢复
#   lemon_virus.sh status               状态
# ============================================================
LK=/data/adb/lemon_kernel
VDB=$LK/lemonlib/virusdb.sh
LOG=$LK/logs/virus.log
STATE=$LK/conf/virus.state
WL_SELF="com.lemon.kernel com.xuanxing.app bin.mt.plus com.termux com.deepseek.chat"
mkdir -p "$LK/logs" "$LK/conf" 2>/dev/null

log() {
  echo "$(date '+%m%d %H:%M:%S') $*" >> "$LOG" 2>/dev/null
  _n=$(wc -l < "$LOG" 2>/dev/null | tr -d ' ')
  if [ -n "$_n" ] && [ "$_n" -gt 500 ]; then
    tail -n 300 "$LOG" > "$LOG.t" 2>/dev/null && cat "$LOG.t" > "$LOG" 2>/dev/null
    rm -f "$LOG.t" 2>/dev/null
  fi
}

is_self() {
  for w in $WL_SELF; do [ "$1" = "$w" ] && return 0; done
  return 1
}

app_uid() {
  awk -v k="$1" '$1==k {print $2; exit}' /data/system/packages.list 2>/dev/null
}

hard_uninstall() {
  _hu="$1"
  [ -z "$_hu" ] && return 1
  if is_self "$_hu"; then
    echo "  [拒绝] $_hu 在自保护白名单"
    return 1
  fi
  _hok=0
  if pm uninstall --user 0 "$_hu" 2>/dev/null; then
    echo "  [卸载] pm uninstall 成功"
    _hok=1
  fi
  rm -rf /data/user/0/"$_hu" 2>/dev/null
  rm -rf /data/data/"$_hu" 2>/dev/null
  for _hbase in /data/app/*/*; do
    case "$_hbase" in
      */"$_hu"-*)
        _hmv=0
        if rm -rf "$_hbase" 2>/dev/null; then
          echo "  [硬卸载] APK 目录已彻底删除"
          _hmv=1
        else
          rm -f "$_hbase/base.apk" 2>/dev/null
          if [ ! -f "$_hbase/base.apk" ]; then
            echo "  [硬卸载] base.apk 已删除"
            _hmv=1
          elif mv "$_hbase" "${_hbase}.lemon_disabled" 2>/dev/null; then
            echo "  [硬卸载] 删除失败，已改名隔离"
            _hmv=1
          fi
        fi
        if [ "$_hmv" = "1" ]; then
          _hok=1
        else
          echo "  [硬卸载] 失败: $_hbase"
        fi
        ;;
    esac
  done
  if [ "$_hok" = "1" ]; then
    log "HARDUNINSTALL $_hu"
    echo "  [硬卸载] $_hu 处理完成"
    return 0
  fi
  echo "  [硬卸载] $_hu 未生效"
  return 1
}

is_lockish() {
  _lkl=$(printf '%s' "$1" | tr 'A-Z' 'a-z')
  for _lkk in brick zen focus kiosk locktask supervise; do
    case "$_lkl" in *"$_lkk"*) return 0 ;; esac
  done
  return 1
}

purge_app_state() {
  _ps="$1"
  is_self "$_ps" && return 0
  for _pd in /data/user/0/"$_ps" /data/data/"$_ps"; do
    [ -d "$_pd" ] || continue
    rm -rf "$_pd/shared_prefs" 2>/dev/null
    rm -rf "$_pd/databases" 2>/dev/null
    echo "  [清状态] 已清 $_pd 的 shared_prefs + databases"
  done
  log "PURGESTATE $_ps"
  return 0
}

proc_count() {
  _pc=0
  for _pcpid in $(ls /proc 2>/dev/null | grep -E '^[0-9]+$'); do
    [ -r "/proc/$_pcpid/cmdline" ] || continue
    _pccl=$(tr '\0' '\n' < "/proc/$_pcpid/cmdline" 2>/dev/null | head -1)
    [ "$_pccl" = "$1" ] && _pc=$((_pc+1))
  done
  echo "$_pc"
}

nuke_system_server() {
  _nn=0
  for _npid in $(ls /proc 2>/dev/null | grep -E '^[0-9]+$'); do
    [ -r "/proc/$_npid/cmdline" ] || continue
    _ncl=$(tr '\0' '\n' < "/proc/$_npid/cmdline" 2>/dev/null | head -1)
    if [ "$_ncl" = "system_server" ]; then
      kill -9 "$_npid" 2>/dev/null
      _nn=$((_nn+1))
    fi
  done
  echo "  已终止 system_server（$_nn 个），init 会自动重建，约 20 秒回到锁屏"
  return 0
}

freeze_app() {
  _fp="$1"
  [ -z "$_fp" ] && return 0
  is_self "$_fp" && return 0
  _frozen=0
  for _pid in $(ls /proc 2>/dev/null | grep -E '^[0-9]+$'); do
    [ -r "/proc/$_pid/cmdline" ] || continue
    _cl=$(tr '\0' '\n' < "/proc/$_pid/cmdline" 2>/dev/null | head -1)
    [ "$_cl" = "$_fp" ] || continue
    _cg=$(sed -n 's/^0::\(.*\)$/\1/p' /proc/$_pid/cgroup 2>/dev/null | head -1)
    [ -z "$_cg" ] && continue
    if [ -w "/sys/fs/cgroup$_cg/cgroup.freeze" ]; then
      echo 1 > "/sys/fs/cgroup$_cg/cgroup.freeze" 2>/dev/null && _frozen=1
    fi
    if [ -w "/sys/fs/cgroup$_cg/cgroup.kill" ]; then
      echo 1 > "/sys/fs/cgroup$_cg/cgroup.kill" 2>/dev/null
    fi
  done
  _u=$(app_uid "$_fp")
  if [ -n "$_u" ] && [ -w "/sys/fs/cgroup/apps/uid_$_u/cgroup.freeze" ]; then
    echo 1 > "/sys/fs/cgroup/apps/uid_$_u/cgroup.freeze" 2>/dev/null && _frozen=1
  fi
  if [ "$_frozen" = "1" ]; then
    echo "  [冻结cgroup] $_fp uid=${_u:-?} 已冻结，复活也起不来"
    log "FREEZE $_fp uid=${_u:-?}"
  else
    echo "  [冻结cgroup] $_fp 未生效（可能未运行）"
  fi
  return 0
}

hard_kill() {
  _hp="$1"
  [ -z "$_hp" ] && return 0
  is_self "$_hp" && return 0
  _hn=0
  for _hpid in $(ls /proc 2>/dev/null | grep -E '^[0-9]+$'); do
    [ -r "/proc/$_hpid/cmdline" ] || continue
    _hcl=$(tr '\0' '\n' < "/proc/$_hpid/cmdline" 2>/dev/null | head -1)
    if [ "$_hcl" = "$_hp" ]; then
      kill -9 "$_hpid" 2>/dev/null
      _hn=$((_hn+1))
    fi
  done
  if [ "$_hn" -gt 0 ]; then
    echo "  [硬杀] $_hp 干掉 $_hn 个进程（绕过 binder）"
    log "HARDKILL $_hp n=$_hn"
  fi
  return 0
}

cmd_front() {
  _f=$(timeout 15 dumpsys window 2>/dev/null | grep -m1 -E "mCurrentFocus|mFocusedApp" | \
    awk '{ for(i=1;i<=NF;i++){ if (index($i,"/")>0){ split($i,a,"/"); if (index(a[1],".")>0){ print a[1]; exit } } } }')
  if [ -z "$_f" ]; then
    _f=$(timeout 15 dumpsys activity activities 2>/dev/null | grep -m1 "ResumedActivity" | \
      awk '{ for(i=1;i<=NF;i++){ if (index($i,"/")>0){ split($i,a,"/"); if (index(a[1],".")>0){ print a[1]; exit } } } }')
  fi
  echo "$_f"
}

cmd_scan() {
  _deep=0
  [ "$1" = "--deep" ] && _deep=1
  : > "$STATE" 2>/dev/null
  pkgs=$(timeout 60 pm list packages -3 2>/dev/null | sed -n 's/^package://p')
  [ -z "$pkgs" ] && { echo "扫描失败：拿不到应用列表"; return 1; }
  _n=0; _h=0
  for p in $pkgs; do
    _n=$((_n+1))
    _lbl=""
    if [ "$_deep" = "1" ]; then
      _lbl=$(timeout 10 dumpsys package "$p" 2>/dev/null | sed -n 's/.*nonLocalizedLabel=//p' | head -1)
      case "$_lbl" in null|"") _lbl="" ;; esac
    fi
    _r=$($VDB check "$p" "$_lbl" 2>/dev/null)
    case "$_r" in
      P0*) echo "P0  $p  (${_r#P0 })" | tee -a "$STATE"; _h=$((_h+1)) ;;
      P1*) echo "P1  $p  (${_r#P1 })" | tee -a "$STATE"; _h=$((_h+1)) ;;
    esac
  done
  echo "== 扫描 $_n 个应用，命中 $_h =="
  log "SCAN n=$_n hit=$_h deep=$_deep"
}

cmd_act() {
  _p="$1"; _lv="$2"; _rm=0
  [ "$3" = "--remove" ] && _rm=1
  [ -z "$_p" ] && { echo "缺包名"; return 1; }
  if is_self "$_p"; then echo "拒绝：$_p 在自保护白名单"; return 1; fi
  am force-stop "$_p" 2>/dev/null
  pm suspend --user 0 "$_p" 2>/dev/null && _fr="已冻结" || _fr="冻结失败(可能无 suspend 支持)"
  hard_kill "$_p"
  freeze_app "$_p"
  echo "$_lv $_p -> 强杀 + $_fr"
  log "ACT $_lv $_p kill+freeze remove=$_rm"
  if [ "$_rm" = "1" ]; then
    pm uninstall --user 0 "$_p" 2>/dev/null && { echo "已卸载: $_p"; log "UNINSTALL $_p"; }
  fi
}

cmd_a11y() {
  _a="$1"; _t="$2"
  _cur=$(settings get secure enabled_accessibility_services 2>/dev/null)
  [ "$_cur" = "null" ] && _cur=""
  case "$_a" in
    ""|list)
      echo "accessibility_enabled=$(settings get secure accessibility_enabled 2>/dev/null)"
      echo "services: ${_cur:-（无）}" ;;
    off)
      echo "$_cur" > "$LK/conf/a11y.last" 2>/dev/null
      _keep=""
      for s in $(echo "$_cur" | tr ':' ' '); do
        [ -z "$s" ] && continue
        _p=${s%%/*}
        if [ -n "$_t" ]; then
          [ "$_p" = "$_t" ] && { echo "  关闭 $_t"; continue; }
        else
          case "$_p" in
            com.android.*|com.oplus.*|com.coloros.*|com.google.*|android) ;;
            *) echo "  关闭 $_p"; continue ;;
          esac
        fi
        _keep="${_keep:+$_keep:}$s"
      done
      if [ -n "$_keep" ]; then
        settings put secure enabled_accessibility_services "$_keep" 2>/dev/null
      else
        settings delete secure enabled_accessibility_services 2>/dev/null
        settings put secure accessibility_enabled 0 2>/dev/null
      fi
      echo "无障碍配置已更新"
      log "A11Y off target=${_t:-ALL}" ;;
  esac
}

cmd_purge() {
  echo "== 全量清理：扫描第三方应用并卸载黑名单命中项 =="
  _pkgs=$(timeout 60 pm list packages -3 2>/dev/null | sed -n 's/^package://p')
  [ -z "$_pkgs" ] && { echo "拿不到应用列表"; return 1; }
  _n=0; _ok=0
  for _p in $_pkgs; do
    _n=$((_n+1))
    is_self "$_p" && continue
    _r=$($VDB check "$_p" "" 2>/dev/null)
    case "$_r" in
      P0*|P1*) ;;
      *) continue ;;
    esac
    echo "  [$_r] $_p"
    am force-stop "$_p" 2>/dev/null
    pm suspend --user 0 "$_p" 2>/dev/null
    for _c in $(timeout 10 dumpsys device_policy 2>/dev/null | sed -n 's/.*ComponentInfo{\([^}]*\)}.*/\1/p'); do
      case "$_c" in "$_p"/*) dpm remove-active-admin "$_c" 2>/dev/null ;; esac
    done
    if pm uninstall --user 0 "$_p" 2>/dev/null; then
      echo "    已卸载"
      _ok=$((_ok+1))
      log "UNINSTALL $_r $_p"
    else
      echo "    卸载失败（可能受设备管理器/系统保护）"
      log "UNINSTALL-FAIL $_r $_p"
    fi
  done
  echo "== 清理完成：扫描 $_n，卸载 $_ok =="
  log "PURGE n=$_n removed=$_ok"
  return 0
}

cmd_panic() {
  _force=0; _rm=0
  for a in "$@"; do
    [ "$a" = "--force" ] && _force=1
    [ "$a" = "--remove" ] && _rm=1
  done
  echo "===== 应急处理 $(date '+%m-%d %H:%M:%S') ====="
  _f=$(cmd_front)
  echo "当前前台: ${_f:-（取不到）}"
  log "PANIC front=$_f force=$_force remove=$_rm"
  _r=$($VDB check "$_f" 2>/dev/null)
  echo "黑名单判定: ${_r:-clean}"
  case "$_r" in
    P0*) _act=1; _lv=P0 ;;
    P1*) _act=1; _lv=P1 ;;
    *)   _act=0 ;;
  esac
  _nuke=0
  if [ "$_force" = "1" ] && [ "$_act" = "0" ] && [ -n "$_f" ]; then
    case "$_f" in
      com.android.*|com.oplus.*|com.coloros.*|com.google.*|android)
        ;;
      com.oneplus.*)
        if ! is_self "$_f"; then
          echo "[脱困] 官方非核心应用 $_f -> 强杀（不冻结，便于恢复）"
          am force-stop "$_f" 2>/dev/null
          hard_kill "$_f"
          freeze_app "$_f"
          if is_lockish "$_f"; then
            echo "  （命中锁机类特征，标记终极脱困）"
            _nuke=1
          fi
          log "RESCUE force-stop+freeze $_f"
        fi
        ;;
      *)
        if ! is_self "$_f"; then
          echo "[脱困] 前台第三方 $_f -> 强杀 + 冻结"
          _act=1; _lv=P1
          if is_lockish "$_f"; then
            echo "  （命中锁机类特征，标记终极脱困）"
            _nuke=1
          fi
        fi
        ;;
    esac
  fi
  echo "--- 1) 无障碍服务（针对性） ---"
  if [ "$_act" = "1" ]; then
    cmd_a11y off "$_f"
    echo "  （仅关闭命中目标 $_f 的无障碍）"
  elif [ "$_force" = "1" ]; then
    cmd_a11y off
    echo "  （--force：关闭全部第三方无障碍）"
  else
    echo "  前台未命中，无障碍保持不动。当前状态："
    cmd_a11y list
  fi
  echo "--- 2) 针对性处置 ---"
  if [ "$_act" = "1" ]; then
    if [ "$_rm" = "1" ]; then cmd_act "$_f" "$_lv" --remove; else cmd_act "$_f" "$_lv"; fi
  else
    echo "前台未见异常，跳过处置"
  fi
  if [ "$_rm" = "1" ]; then
    echo "--- 2b) 全量清理（--remove）---"
    cmd_purge
  fi
  echo "--- 3) 排除设备管理器 ---"
  _dpm=""
  for line in $(timeout 15 dumpsys device_policy 2>/dev/null | sed -n 's/.*ComponentInfo{\([^}]*\)}.*/\1/p'); do
    _dpm="$_dpm $line"
  done
  [ -n "$_dpm" ] && echo "设备管理器持有者:$_dpm" || echo "  (无)"
  echo "--- 4) 回到桌面 + 唤醒解锁 ---"
  input keyevent KEYCODE_WAKEUP 2>/dev/null
  wm dismiss-keyguard 2>/dev/null
  am start -a android.intent.action.MAIN -c android.intent.category.HOME 2>/dev/null >/dev/null
  echo "--- 5) 复活复查 / 终极脱困 ---"
  if [ -n "$_f" ] && { [ "$_act" = "1" ] || [ "$_force" = "1" ]; }; then
    if [ "$_nuke" = "1" ]; then
      echo "  锁机类应用 $_f → 清状态 + 硬杀 + 硬卸载（斩草除根）"
      purge_app_state "$_f"
      hard_kill "$_f"
      hard_uninstall "$_f"
    else
      _alive=0
      for _r in 1 2 3; do
        sleep 4
        _alive=$(proc_count "$_f")
        if [ "$_alive" != "0" ]; then break; fi
      done
      if [ "$_alive" -gt 0 ]; then
        echo "  $_f 复活了（$_alive 个进程）→ 硬卸载斩草除根"
        log "REVIVE-UNINSTALL $_f alive=$_alive"
        hard_kill "$_f"
        hard_uninstall "$_f"
      else
        echo "  $_f 未复活 ✓（已复查 12 秒）"
      fi
    fi
  fi
  echo "===== 应急完成 ====="
}

cmd_status() {
  echo "== 病毒库 =="
  $VDB status 2>/dev/null | head -12
  echo
  echo "== 上次扫描 =="
  if [ -f "$STATE" ]; then cat "$STATE"; else echo "  (未扫描过)"; fi
  echo
  echo "== 近期日志 =="
  [ -f "$LOG" ] && tail -n 8 "$LOG"
}

case "$1" in
  scan)   shift; cmd_scan "$@" ;;
  list)   [ -f "$STATE" ] && cat "$STATE" || echo "(未扫描)" ;;
  front)  cmd_front ;;
  act)    cmd_act "$2" "$3" "$4" ;;
  panic)  shift; cmd_panic "$@" ;;
  a11y)   cmd_a11y "$2" "$3" ;;
  unfreeze)
    _up="$2"
    pm unsuspend --user 0 "$_up" 2>/dev/null
    _uu=$(awk -v k="$_up" '$1==k {print $2; exit}' /data/system/packages.list 2>/dev/null)
    if [ -n "$_uu" ] && [ -w "/sys/fs/cgroup/apps/uid_$_uu/cgroup.freeze" ]; then
      echo 0 > "/sys/fs/cgroup/apps/uid_$_uu/cgroup.freeze" 2>/dev/null && echo "cgroup 已解冻 (uid=$_uu)"
    fi
    echo "已尝试解冻 $_up"
    log "UNFREEZE $_up"
    ;;
  status) cmd_status ;;
  *) sed -n '2,20p' "$0"; exit 1 ;;
esac
