# 小柠檬 slim 门面 v1.5.0 —— 备用维护通道 + 熔断 + 金丝雀切换

> 261111 断链事故的直接产物。核心目标：**主通道更新/维护时，随时有一条备用通道可切，且切换本身不会把服务搞挂。**

## 本次新增（4 个新组件 + 1 个升级）

| 文件 | 说明 |
|---|---|
| `maint_server.py` | **备用维护通道**，独立进程，监听 127.0.0.1:8795，只有 4 个保命工具（sh / file_read / file_write_text / upstream_ping），独立令牌 `.token_maint`（缺失回落 `.token`），无令牌拒绝启动 |
| `slim_proxy_v132.py` | 主代理 v1.3.2，新增 **LOCKDOWN 熔断**：`slimproxy/LOCKDOWN` 文件一建，公网口所有令牌立即降级为只读（sh/写文件被拒，tool_find 等只读工具仍可用）；删掉即恢复，热生效免重启 |
| `switch.sh` | **金丝雀切换脚本**：①备用通道先验活（死的就先拉起，拉不起拒绝开工）→ ②新版 8793 预热自检 → ③停旧（确认死透，5 秒后强杀）→ ④双口自检，失败自动回滚旧版 |
| `watchdog_v150.sh` | 看门狗 v5.0 **双活版**：primary/secondary 互写心跳（30 秒失联即接管），secondary 还会盯着 primary 看门狗本体、死了补位；巡检范围扩到 8791/8792/8795/zeronews |
| `start_maint.sh` | 备用通道启动器（幂等，无令牌拒绝） |

## 安装（全部用 su，一行一条）

```
su -c 'mkdir -p /data/lemonbrain/slimproxy /data/lemonbrain/logs'
```

```
su -c 'cp maint_server.py slim_proxy_v132.py switch.sh start_maint.sh watchdog_v150.sh /data/lemonbrain/slimproxy/'
```

给备用通道生成独立令牌（不想独立就跳过，自动回落用主令牌）：

```
su -c 'head -c 24 /dev/urandom | base64 | tr -dc a-zA-Z0-9 > /data/lemonbrain/slimproxy/.token_maint'
```

```
su -c 'chmod 600 /data/lemonbrain/slimproxy/.token_maint'
```

起备用通道：

```
su -c 'sh /data/lemonbrain/slimproxy/start_maint.sh'
```

换双活看门狗（先停旧的 v130 看门狗，主备各起一个）：

```
su -c 'pkill -f "watchdog_v130" ; nohup sh /data/lemonbrain/slimproxy/watchdog_v150.sh primary >/dev/null 2>&1 &'
```

```
su -c 'nohup sh /data/lemonbrain/slimproxy/watchdog_v150.sh secondary >/dev/null 2>&1 &'
```

## zeronews 第二条公网隧道（可选增强）

备用通道监听本机 127.0.0.1:8795。要让它能被外面的 AI 连上，需要第二条隧道。

**已验证**：zeronews 4.0.9 支持 CLI 直接加隧道，不用登录网页控制台：

```
su -c '/data/local/tmp/zn_tmp/zeronews/zeronews add https --port=8795 --bw=1 --workdir /data/local/tmp/zeronews_home'
```

**但当前套餐隧道数上限为 1 条**（控制面返回 tunnel count limit reached），现有隧道已被主通道占用。两个选择：

- **A. 升级套餐**：在 zeronews.cc 控制台升级后，直接跑上面那条命令即可，公网域名会自动打印出来。备用通道完整接入地址为：`https://<新域名>/mcp/<.token_maint内容>`
- **B. 不加第二条隧道（推荐现状）**：备用通道本机可用，日常升级完全够用——因为 `switch.sh` 切换是全自动的（预热→替换→自检→失败自动回滚），全程十几秒，切换瞬间不需要任何外部连接守着。看门狗双活 + 自动回滚已是双保险。

**主通道彻底死透时的救命路径**（无第二隧道情况下）：手机本机 Termux 里跑：

```
su -c 'sh /data/lemonbrain/slimproxy/start_maint.sh'
```

然后本机任何 MCP 客户端连 `http://127.0.0.1:8795/mcp/<.token_maint内容>` 即可进场维修。

## 日常使用

### 主通道升级（以后就用这个，别再手动 pkill）

```
su -c 'cd /data/lemonbrain/slimproxy && sh switch.sh slim_proxy_v133.py'
```

退出码：0=成功；1=文件不存在；2=备用通道不可用（拒绝开工）；3=新版预热失败（旧版没动）；4=旧版拒绝退出；5=上线自检失败（已自动回滚）。

### 维护期间切客户端到备用通道

把客户端 MCP 地址换成备用通道地址即可。备用通道工具少（4 个），但 sh + 文件读写都有，足够干活。维护完切回主通道。

### 紧急熔断（怀疑令牌泄露 / 公网被扫）

```
su -c 'touch /data/lemonbrain/slimproxy/LOCKDOWN'
```

公网口立即全只读，本机口 127.0.0.1:8791 不受影响（本机操作不受限）。解除：

```
su -c 'rm /data/lemonbrain/slimproxy/LOCKDOWN'
```

## 测试

- `test_v150.py`：39 项断言（备用通道 20 + LOCKDOWN 8 + 切换故障注入 8 + 双活看门狗 3），连跑 3 轮全过
- `test_slim_v130.py` 对 v1.3.2 回归：140 项断言 × 3 轮全过
- 沙箱运行：`python3 test_v150.py`（需要 python3.8+，自动起 mock 上游，不碰真机任何东西）

## 红线（沿袭 v1.3.x）

- 一切令牌级别都无法读取 `.token` / `.tokens.json` / `.token_maint`
- `rm -rf /`、`rm --no-preserve-root`、写块设备、覆写系统镜像永远被护栏拦截（无论令牌级别）
- 危险命令只在 mock 环境测，真机永不实测
