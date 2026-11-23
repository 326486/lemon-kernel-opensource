# 闭源组件说明（261123 更正）

## 1. safe 安全门面：**已开源**
`safe_proxy_v160.py`（186 行，监听 8793：风险注解 / 确认门 / 路径保护 / 审计 / 语义检索）**源码已收录在本仓库** `02-mcp-server/` 下。

- 原声明"本开源包不含 safe 门面"已过期，现予更正。
- 源码中**没有任何硬编码令牌**：运行令牌从环境变量 `LEMON_MCP_TOKEN` 读取，未设置时回退读 `/data/lemonbrain/.mcp_token`；两者都为空则不发送 `Authorization` 头。
- 部署前须自行注入令牌（建议令牌文件 `chmod 600`）。

## 2. guard 内核模块：**仍未开源**
`07-lemonguard`（kprobe 拦截 + KO）源码与 KO 均不在本仓库。

- 开源版链路：客户端 → 隧道 → 令牌闸 8796 → slim 门面 8792 → lemoncore 8788 / Java 8790 / 插件（8793 可选）。
- 安全由令牌闸 + cmdguard 白名单 + 输出门禁承担；guard 属可选内核加固。
- 本仓库提供的是**用户态替代**：`08-guard-userspace/`（检测 + 恢复 + 开机自启，4 个文件）。
- 需完整内核加固组件请联系作者。

## guard 能力纠正（261117 实测）
在本机 PAC+SCS+kCFI GKI 内核上，guard 的 kprobe 拦截结构性不可用（触发即 FPAC panic），**仅能记录与隐藏**。
live 已降级只读（dry_run=Y/hard_deny=N）。目录保护改由用户态 guard_userspace.py（检测+恢复）承担。
详见 GUARD_STATUS.md。开源包不含 guard 源码与 KO。
