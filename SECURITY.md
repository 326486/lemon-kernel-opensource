# 安全说明（必读）

## shell_exec_root 风险
shell_exec_root 以 root 执行任意命令，监听 127.0.0.1 明文端口、**无鉴权**。任何能访问本机 localhost 的 App 都可借用此 root 通道。
缓解：
- 仅在本机可信环境使用；不要把 8788/8792 暴露公网（对外只经 8796 令牌闸+隧道）。
- 启用闭源 safe 门面(8793)获得确认门/路径保护/审计；或配置 cmdguard 白名单限制命令。
- 用 SELinux/防火墙限制哪些进程可连 8788。
- 破坏性操作务必 confirm + 备份。

## 开源版面板
panel_server 已加回退：safe(8793) 不在时自动改用 slim(8792)，开源版面板工具调用可用。

## 已修复 bug
- shell_exec_root 退出码丢失（管道 head 恒0）→ 现保留真实退出码。
- dumpsys_list/pm_list_pkg 空 filter 报 grep no REGEX → 现空 filter 等价全量。
- reload 标志路径与插件目录不一致 → 统一为 /data/adb/lemon_kernel/.reload_req。
