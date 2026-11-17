# 小柠檬内核源码仓库

> 备份时间：2026-11-15 23:01 ｜ 用途：上传云端仓库保存 ｜ 由千问Go!白名单备份生成

## 目录结构

| 目录 | 内容 | 文件数 |
| --- | --- | --- |
| 01-lemoncore | 见下 | 14 |
| 02-mcp-server | 见下 | 19 |
| 03-sherry_keeper | 见下 | 15 |
| 04-nettools | 见下 | 5 |

### 01-lemoncore（C 核心）
LemonCore.c 主源码 + conf/lemoncore.conf（端口配置，无密钥）+ tests 审计脚本 + 构建/启动脚本。
当前运行版本：lemoncore 8788，注册工具约 867 个。

### 02-mcp-server（MCP 服务器 / slim 门面）
slim_proxy_v150.py 当前生产版（含异步长任务接口 task_submit/status/result）+ lemon_res.py 输出脱敏 + maint_server.py 备用维护通道 + 令牌闸 mcp_gate_8787.py + switch.sh 金丝雀切换 + 启动/看门狗脚本 + 测试。
当前版本：v1.5.0。

### 03-sherry_keeper（雪莉模块）
sherry_agent.sh 入口 + lib/ 功能库（安全/清理/归类/深扫/AI判断/ReAct/15类分类）+ tests/test_sherry.sh（34项）+ sherry_autoclean.sh 定时管线。
当前版本：v9.3.1-retention。

### 04-nettools（联网工具）
web_search.py（小浣熊AI搜索+四源回退）+ web_fetch.py（SSRF防护正文抓取）+ 包装脚本 + 测试。

## ⚠️ 已排除的敏感文件（切勿上传真实凭据）

以下文件含密钥/令牌，**未备份**，仓库中仅保留 `.example` 脱敏模板：

- `slimproxy/.token` `.token_maint` `.tokens.json` `.cmdguard.json`（MCP 令牌与护栏规则）
- `sherry_keeper/files/ai.conf`（小浣熊网关密钥）
- `nettools/search.conf`（小浣熊网关密钥）

同时排除：所有 `*.bak*` 历史备份、`*.pyc`/`__pycache__`、`*.log`、运行时目录（tasks/logs/recycle/status）、编译二进制（lemoncore/full.cpio）。

## 恢复部署要点

1. 将各 `.example` 模板复制为真实配置文件，填入密钥，`chmod 600`。
2. C 核心需按设备真内核重新编译（参见 #274 QEMU 测试线），不可直接套用他机二进制。
3. 门面经 switch.sh 金丝雀部署；雪莉/联网工具为纯 shell+python3，落位即用。
4. `.gitignore` 已防止凭据与运行时被误提交。


## 发布版补充（本次刷新）
- 02-mcp-server: slim_proxy_v154(当前生产)+safe_proxy_v160(安全门面)+mcp_gate 当前版
- 05-panel: 控制面板后端+UI+WebView壳APK源码+Magisk模块
- 06-plugins: 881 个工具薄壳JSON
- 07-lemonguard: guard 内核模块源码
- 04-nettools: 补充联网工具脚本
- 所有凭据/私有路径/隧道地址已脱敏为占位符, 见 MANIFEST.json
