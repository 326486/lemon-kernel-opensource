# 闭源组件说明
本开源包不含：safe 安全门面(safe_proxy_v160.py,8793 确认门/路径保护/审计) 与 guard 内核模块(07-lemonguard)。
开源版链路：客户端→隧道→令牌闸8796→slim门面8792→lemoncore8788/Java8790/插件（跳过8793）。
安全由令牌闸+cmdguard白名单+输出门禁承担；guard 为可选内核加固，开源版省略。
docs 中涉及 safe/guard 的章节仅作架构说明，源码不在本仓库。需闭源组件请联系作者。

## guard 能力纠正（261117 实测）
在本机 PAC+SCS+kCFI GKI 内核上，guard 的 kprobe 拦截结构性不可用（触发即 FPAC panic），**仅能记录与隐藏**。
live 已降级只读（dry_run=Y/hard_deny=N）。目录保护改由用户态 guard_userspace.py（检测+恢复）承担。
详见 GUARD_STATUS.md。开源包不含 guard 源码与 KO。
