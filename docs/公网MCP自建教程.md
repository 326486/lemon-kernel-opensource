# 公网 MCP 自建教程（把手机内核暴露成公网 MCP 服务）

> 目标：让别人/别的设备通过一个 HTTPS URL + Bearer 令牌连到你手机上的内核。
> 原则：**只暴露令牌闸 8796**，绝不直接暴露 8788/8791/8792/8794/8795。隧道负责把公网 HTTPS 转到本机 8796。
> 前置：已按《完整版教程》把内核+闸跑起来（8796 本机 initialize 通过）。

## 0. 三种方案对比

| 方案 | 需要 | 优点 | 缺点 |
|---|---|---|---|
| Cloudflare Quick Tunnel | 仅手机装 cloudflared | 零配置、免费、即开即用 | 临时域名每次变、不可定制 |
| Cloudflare Named Tunnel | 免费 CF 账号+域名 | 固定域名、稳定 | 需绑域名/配置 |
| frp + 自有 VPS | 一台公网 VPS | 完全自控、固定 | 需 VPS+备案/域名可选 |
| nginx TLS 反代 | VPS+域名+证书 | 正式 HTTPS、可加限流 | 配置最多 |

新手推荐 Quick Tunnel 先跑通，再升级 Named/frp/nginx。

## 1. Cloudflare Quick Tunnel（最快）

```bash
pkg install -y cloudflared
# 前台试跑（Ctrl+C 停）：
cloudflared tunnel --url http://127.0.0.1:8796
```
输出里找 `https://<随机>.trycloudflare.com` → 这就是公网 URL。
后台常驻：
```bash
nohup cloudflared tunnel --url http://127.0.0.1:8796 > /data/lemonbrain/tunnel.log 2>&1 &
grep -o 'https://[a-z0-9-]*\.trycloudflare\.com' /data/lemonbrain/tunnel.log | head -1
```
客户端配置：
```json
{"mcpServers":{"lemon":{"url":"https://<随机>.trycloudflare.com/","headers":{"Authorization":"Bearer <令牌>"}}}}
```
验证：`curl -s -X POST <url> -H "Authorization: Bearer <令牌>" -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}'`
预期 serverInfo。失败查排错手册"隧道"条。

## 2. Cloudflare Named Tunnel（固定域名）

1. `cloudflared tunnel login`（浏览器授权 CF 账号）。
2. `cloudflared tunnel create lemon` → 得 tunnel id + 凭证 json。
3. 绑域名：`cloudflared tunnel route dns lemon mcp.你的域名.com`。
4. 配置 `~/.cloudflared/config.yml`：
```yaml
tunnel: <tunnel-id>
credentials-file: /data/data/com.termux/files/home/.cloudflared/<tunnel-id>.json
ingress:
  - hostname: mcp.你的域名.com
    service: http://127.0.0.1:8796
  - service: http_status:404
```
5. `nohup cloudflared tunnel run lemon > tunnel.log 2>&1 &`
客户端 url = `https://mcp.你的域名.com/`。

## 3. frp + 自有 VPS

VPS 跑 frps（`frps.toml`: `bindPort=7000`），手机 frpc：
```toml
# frpc.toml
serverAddr = "你的VPS_IP"
serverPort = 7000
[[proxies]]
name = "lemon-mcp"
type = "tcp"
localIP = "127.0.0.1"
localPort = 8796
remotePort = 8796
```
`nohup frpc -c frpc.toml > frpc.log 2>&1 &`
公网入口 = `http://VPS_IP:8796`（建议再套 nginx TLS，见下）。
安全：VPS 安全组只放行 8796 给信任 IP，或套 nginx+TLS+限流。

## 4. nginx TLS 反代（正式 HTTPS，套在 frp/隧道后）

VPS nginx：
```nginx
server {
  listen 443 ssl;
  server_name mcp.你的域名.com;
  ssl_certificate     /path/fullchain.pem;
  ssl_certificate_key /path/privkey.pem;
  location / {
    proxy_pass http://127.0.0.1:8796;   # 经 frp/隧道到手机
    proxy_http_version 1.1;
    proxy_buffering off;               # MCP 流式响应必须关缓冲
    proxy_read_timeout 300s;           # 长任务余量
    proxy_set_header Host $host;
  }
}
```
`nginx -t && nginx -s reload`。客户端 url=https://mcp.你的域名.com/。
**proxy_buffering off 关键**：默认 on 会把流式响应攒住，客户端表现为"一直转圈"。

## 5. 令牌与安全（必做）

- 令牌 = tokens.json 里的随机串；客户端 `Authorization: Bearer <令牌>`。
- 轮换：改 tokens.json + 重启闸；旧令牌立即失效（错误令牌返回防御性 -32001）。
- 只暴露 8796；8788/8791/8792/8794/8795 保持 127.0.0.1。
- 隧道/VPS 加限流防刷；破坏性工具靠 cmdguard 白名单 + 调用方 confirm。
- 不用时停隧道（`pkill cloudflared`/`pkill frpc`），减少暴露面。
- 切勿把令牌写进公开仓库/截图。

## 6. 作者自用方案（zeronews，供参考）

作者链路用 zeronews 隧道客户端（本地 API 127.0.0.1:37271）把公网 endpoint 转到 8796。
若你用 zeronews：在其客户端建一条映射 公网域名→127.0.0.1:8796，其余与上文客户端配置相同。
（zeronews 为作者环境组件，开源包不附带；用 cloudflared/frp 即可等价替代。）

## 7. 自检

| 检查 | 命令 | 预期 |
|---|---|---|
| 本机闸 | curl 127.0.0.1:8796 initialize +Bearer | serverInfo |
| 隧道进程 | pgrep cloudflared / pgrep frpc | 有pid |
| 公网 | curl 隧道URL initialize +Bearer | serverInfo |
| 无令牌 | curl 隧道URL initialize 不带Bearer | -32001(防御) |

---

内容由 AI 生成