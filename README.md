# 小柠檬内核源码仓库

> 备份时间：2026-11-15 23:01 ｜ 用途：上传云端仓库保存 ｜ 由千问Go!白名单备份生成

## 目录结构

| 目录 | 内容 | 文件数 |
| --- | --- | --- |
| 01-lemoncore | C 核心 | 14 |
| 02-mcp-server | MCP 服务器 / 门面 | 24 |
| 03-sherry_keeper | 雪莉模块 | 16 |
| 04-nettools | 联网与逆向实现层总库 | 181 |
| 05-panel | 控制面板后端 / UI / APK 壳 | 11 |
| 06-plugins | 公开工具薄壳 JSON | 358 |
| 06-plugins-private | 私有工具薄壳 JSON | 522（521 JSON + 1 说明） |
| 08-guard-userspace | 用户态加固 | 4 |
| docs | 文档 | 4 |
| 根目录散件 | LICENSE / README / SECURITY 等 | 7 |
| **合计**（`git ls-files`） | | **1141** |

> 以上数字为 2026-11-23 按仓库实际文件核对（`find <dir> -type f | wc -l`），此前 README 的 19 / 15 / 5 与实际不符，已修正。

### 01-lemoncore（C 核心）
LemonCore.c 主源码 + conf/lemoncore.conf（端口配置，无密钥）+ tests 审计脚本 + 构建/启动脚本。
当前运行版本：lemoncore 8788，注册工具约 867 个。

### 02-mcp-server（MCP 服务器 / slim 门面）
slim_proxy_v150.py 当前生产版（含异步长任务接口 task_submit/status/result）+ lemon_res.py 输出脱敏 + maint_server.py 备用维护通道 + 令牌闸 mcp_gate_8787.py + switch.sh 金丝雀切换 + 启动/看门狗脚本 + 测试。
当前版本：v1.5.0。

### 03-sherry_keeper（雪莉模块）
sherry_agent.sh 入口 + lib/ 功能库（安全/清理/归类/深扫/AI判断/ReAct/15类分类）+ tests/test_sherry.sh（34项）+ sherry_autoclean.sh 定时管线。
当前版本：v9.3.1-retention。

### 04-nettools（联网与逆向实现层总库）
**181 个文件**，不是"联网工具 5 文件"。这里放的是整个仓库的实现层：核心 C 外壳之外，绝大部分可执行能力都在这个目录。

- 内核/注入挂钩：`dynhook.sh`（212 行）、`khook.sh`（354 行）、`ko_mgr.sh`（KO 模块装卸）
- 逆向与静态分析：`gnaw` 系列（guard / guard2 / hetui / censor / inject2）、`binary_scan.py`、`binary_analyze.py`、`binary_quick.py`、`dexdump` 辅助
- 审计与留痕：`audit_auto.py`、`audit_java.py`、`audit_python.py`、`audit_web.py`、`audit_learn.py`、`incident_check.py`、`compliance_checker.py`
- 探测与扫描：`http_probe.py`、`cloud_scan.py`、`waf_detect.py`、`xxe_scanner.py`、`url_phish_check.py`、`hash_id.py` 等
- 旁路与提权辅助：`cmd_bypass.py`、`adaptive_bypass.py`、`appops_*` / `appmem.sh` / `clip_*` 系列
- 算法助手对接：`algo_call.sh`
- 联网底座：`web_search.py`（小浣熊 AI 搜索 + 四源回退）、`web_fetch.py`（SSRF 防护正文抓取）、`ai_call.py` / `llm_route.py` / `intent_router.py`

> 该目录内容仅用于自有设备的运维与安全研究；对外分发时请自行评估合规性。

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
- 06-plugins: **358** 个公开工具薄壳 JSON；`06-plugins-private` 另有 **521** 个私有 JSON，合计 **879**（原写 881 / 356+516 已过期，已修正）
- 08-guard-userspace: 用户态 guard（检测 + 恢复 + 开机自启，4 文件）
- 07-lemonguard: **内核模块源码不在本仓库**，详见 CLOSED_SOURCE.md / GUARD_STATUS.md
- 04-nettools: **181** 个联网与逆向实现脚本（实现层总库，非"5 文件联网工具"）
- 02-mcp-server: `safe_proxy_v160.py` 源码**已收录在本仓库**（186 行，令牌已改为环境变量/文件注入），CLOSED_SOURCE.md 的旧声明已同步更正
- 所有凭据/私有路径/隧道地址已脱敏为占位符, 见 MANIFEST.json
