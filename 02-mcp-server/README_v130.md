# 小柠檬内核 · slim 门面 v1.3.0 升级包

> 261111 · 自用版（免发布门禁）· 与 v1.2.0 完全并存，随时可回滚
> 测试：135 项自动化断言 × 连续 3 轮全部通过（mock 上游环境，不碰真机 8788）
> 红队复查：逮出并修复 4 个漏洞（凭证读取提权、引号/长选项/双斜杠绕过护栏）

## 包里有什么

| 文件 | 说明 |
|---|---|
| `slim_proxy_v130.py` | 新版门面主程序（不动旧文件） |
| `start_v130.sh` | 启动 v1.3.0（幂等，仿原 start.sh） |
| `watchdog_v130.sh` | 守护 v1.3.0 的看门狗（可选换用） |
| `test_slim_v130.py` | 验收测试，手机上可复跑 |
| `README_v130.md` | 本说明 |

## 新增能力

1. **危险命令护栏**：`sh`/`shell_exec`/`shell_exec_root`/`shell_script`/`file_write_text` 前置拦截 rm 毁根、dd/mkfs 写块设备、fork 炸弹、刷分区、写 .token/门面包身等规则（含引号、长选项、双斜杠、`..` 穿越等绕过形态，红队回归覆盖）；`tool_call` 转发前对目标工具二次检查。配置：`/data/lemonbrain/slimproxy/.cmdguard.json`，如 `{"disabled":true}` 或 `{"extra_cmd_patterns":["..."],"protected_paths":["..."]}`（60 秒热加载）。
   - **凭证读取保护**：`file_read`/`file_cat`/`file_head`/`text_search_regex` 及 shell 的 `cat`/`head`/`base64` 等一律禁止读 `.token`/`.tokens.json`（读凭证=偷权限，任何级别令牌都不放行；确需读取请临时 `LEMON_GUARD=0`）。
2. **写前快照**：`file_write_text` 覆盖已存在文件前，自动备份到 `/data/lemonbrain/snapshots/`（单文件上限 5MB，保留最近 200 份）。
3. **分级令牌（可选）**：新建 `/data/lemonbrain/slimproxy/.tokens.json`，形如 `{"readonly":"令牌R","write":"令牌W","root":"令牌X","default_scope":"write"}` 即启用三级权限；不建 = 旧行为（.token = root 全权），**现有 takin 链接不受影响**。旧 .token 在分级模式下仍按 root 兼容。
4. **file_read 分段读取**：新门面工具，`{path, offset, limit}` 按字节分段（UTF-8 安全，单段上限 3968B 受 4KB 门禁约束），返回自带下段 offset。读大文件不用再发明 base64 对账。
5. **结构化截断**：截断时在 `result._meta.slim.events` 里带 `truncated/total_bytes/full_path`，文本提示保留，老客户端无感。
6. **审计日志**：`/data/lemonbrain/logs/audit.jsonl`，记录工具名、参数 sha256、耗时、拦截原因，不落明文参数和令牌。
7. **/metrics 指标端点**：仅本机口 8791（公网口访问回 404），含调用数/拦截数/截断数/快照数/by_tool 分桶。
8. **环境开关**：`LEMON_GUARD=0`（关护栏）/`LEMON_SNAPSHOT=0` / `LEMON_AUDIT=0` / `LEMON_HOME=<目录>`（测试用）。

## 部署（逐行执行）

```sh
cp /sdcard/下载/小柠檬slim门面_v1.3.0_升级包/slim_proxy_v130.py /data/lemonbrain/slimproxy/
```

```sh
cp /sdcard/下载/小柠檬slim门面_v1.3.0_升级包/start_v130.sh /data/lemonbrain/slimproxy/
```

```sh
cp /sdcard/下载/小柠檬slim门面_v1.3.0_升级包/watchdog_v130.sh /data/lemonbrain/slimproxy/
```

```sh
chmod 755 /data/lemonbrain/slimproxy/slim_proxy_v130.py /data/lemonbrain/slimproxy/start_v130.sh /data/lemonbrain/slimproxy/watchdog_v130.sh
```

先停旧门面和旧看门狗：

```sh
sh /data/lemonbrain/slimproxy/stop.sh
```

```sh
kill $(cat /data/lemonbrain/slimproxy/.watchdog.pid) 2>/dev/null
```

启动新版：

```sh
sh /data/lemonbrain/slimproxy/start_v130.sh
```

换新看门狗（可选但推荐）：

```sh
nohup sh /data/lemonbrain/slimproxy/watchdog_v130.sh >/dev/null 2>&1 &
```

验证（应显示 version 1.3.0、guard/snapshot 为 true）：

```sh
curl -s http://127.0.0.1:8791/
```

## 回滚（30 秒）

```sh
sh /data/lemonbrain/slimproxy/stop.sh
```

```sh
kill $(cat /data/lemonbrain/slimproxy/.watchdog.pid) 2>/dev/null
```

```sh
sh /data/lemonbrain/slimproxy/start.sh
```

```sh
nohup sh /data/lemonbrain/slimproxy/watchdog.sh >/dev/null 2>&1 &
```

## 手机上复跑测试

```sh
python3 /data/lemonbrain/slimproxy/test_slim_v130.py /data/lemonbrain/slimproxy/slim_proxy_v130.py
```

（自带 mock 上游，用临时目录，不碰真 8788 与真配置）

## 已知边界

- file_read 单段 ≤3968B（4KB 输出门禁是钦定铁律，段大小让位门禁）；读 54KB 提示词约 14 段。
- 分级令牌改动 `.tokens.json` 需重启门面生效（`.cmdguard.json` 才是热加载）。
- SSE 会话 scope 取建立流时的令牌级别。

## 下一步建议（v1.4.0）

`tool_find` 语义向量检索（bge-small-zh 量化版，1266 条 desc 离线索引，关键词结果融合兜底）——等你发话。
