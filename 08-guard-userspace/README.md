# 08-guard-userspace 用户态目录防护

内核 guard 在本机 PAC+SCS+kCFI GKI 上只能记录不能拦截(见 GUARD_STATUS.md)。
本目录提供**用户态**替代防护: 基线比对+变更告警+可选恢复, 不碰内核、不会崩。

## 用法
python3 guard_userspace.py            # 检测+告警
python3 guard_userspace.py --restore  # 检测+从 /data/lemonbrain/snapshots 恢复变更
保护目录默认: /data/adb/modules, /data/lemonbrain/core, /sdcard/小柠檬工作室 (脚本内 PROTECT 可改)
基线: /data/lemonbrain/guard_us_baseline.json  告警: /data/lemonbrain/logs/guard_us_alert.log

## 开机自启(二选一)
- Termux:Boot: 把 boot/start-guard-us.sh 放到 ~/.termux/boot/
- Magisk: 把 magisk/service.sh 放入模块目录(late_start)

## 部署
cp guard_userspace.py /data/lemonbrain/maintenance/
