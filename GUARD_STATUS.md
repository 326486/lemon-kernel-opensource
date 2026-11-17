# guard 状态与正确用法（261117）
- 本机内核 PAC+SCS+kCFI，kprobe 改流程拦截必 FPAC/CFI panic，结构性不可修。
- guard 定位=只读记录器+隐藏，不做拦截。live 参数 dry_run=Y hard_deny=N lg_hide=0 sys_protected=N。
- 目录保护=用户态 guard_userspace.py（基线比对+告警+可选恢复），不碰内核。
- 真拦截需求=LSM hook（高风险 bootloop，需重启验证窗口）或用户态检测+恢复；不建议 kprobe。
- 重编 guard 须 clang+kcfi+normalize-integers、/proc/config.gz 取 .config、BTF 校准 struct module=1600；源码真实化(probes_ok)待重启窗口。
