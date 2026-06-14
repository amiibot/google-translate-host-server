# Google 翻译 IP 中转服务设计

- 日期: 2026-06-14
- 状态: 已批准，待实现
- 作者: itorash + Claude

## 背景与动机

现有 `GoogleTranslateIpCheck` 工具需要在每台客户端单独运行，扫描可用 Google IP 并写入本地 `hosts`。痛点：

- IP 经常失效或不稳定，需重复跑一轮设置
- 每台客户端都要装、扫、写 hosts，需管理员权限
- 多设备维护成本随设备数线性增长

目标是在局域网常开服务器上部署一个中转，集中扫描与维护可用 IP，客户端只需一次性 hosts 设置即可永久指向中转，由中转自动跟随 Google 真实 IP 变化。

## 方案选择

考虑过三条路线（详见"备选方案"）。最终选择 **TLS 透传反代**：

- 服务器跑 nginx `stream` 模块，监听 443，仅做 4 层 TCP 转发 + SNI 路由
- 不解密 TLS，不需要在客户端装根证书
- 客户端 hosts 直接写"服务器 IP → translate 域名"，行为对客户端等价于直连 Google
- TLS 加密通道仍是客户端 ↔ Google 端到端，证书是 Google 真实证书

## 部署环境

- 服务器: Ubuntu 虚拟机（已确认 443 空闲），`network_mode: host`
- 客户端: Win10/Win11，手动改 hosts 一次
- 仅 IPv4，不支持 IPv6（如未来需要再扩展）

## 架构

```
┌─────────────────────────────────────────────────────────────┐
│  LAN 服务器 (Ubuntu, host 网络模式)                          │
│                                                             │
│   ┌────────────────────┐      ┌───────────────────────┐    │
│   │ nginx (stream)     │◄─────│ updater.sh (常驻)      │    │
│   │ :443 SNI 透传       │ reload│  每 N 周期探活当前 IP   │    │
│   │ upstream = 当前IP  │      │  失败 → 调扫描器       │    │
│   └────────┬───────────┘      │  → 写 upstream.conf  │    │
│            │                  │  → nginx -s reload   │    │
│            │                  └───────┬───────────────┘    │
│            │                          │ 仅失败时调用       │
│            │                          ▼                    │
│            │                  ┌───────────────────────┐    │
│            │                  │ GoogleTranslateIpCheck │    │
│            │                  │ (.NET self-contained)  │    │
│            │                  │ 一次性运行，输出 ip.txt │    │
│            │                  └───────────────────────┘    │
└────────────┼────────────────────────────────────────────────┘
             │ TCP 443, SNI=translate.googleapis.com
             ▼
       Google 真实 IP（每次 reload 更新）

┌──────────────────────────────────────────────┐
│  Win10/11 客户端                              │
│  hosts:                                       │
│   192.168.x.y translate.googleapis.com        │
│   192.168.x.y translate.google.com            │
│   192.168.x.y translate-pa.googleapis.com     │
│  TLS 端到端加密到 Google                       │
└──────────────────────────────────────────────┘
```

## 组件设计

### nginx 配置

用 `stream` 模块，**不是** `http` 模块。前者只搬运 TCP 字节，不解密 TLS。

#### `/etc/nginx/nginx.conf`（构建时固定）

```nginx
worker_processes auto;
events { worker_connections 1024; }

stream {
    log_format basic '$remote_addr [$time_local] '
                     '$ssl_preread_server_name -> $upstream_addr '
                     '$status $bytes_sent $session_time';
    access_log /dev/stdout basic;
    error_log  /dev/stderr warn;

    include /etc/nginx/upstream.conf;

    server {
        listen 443;
        proxy_pass google_translate;
        ssl_preread on;
        proxy_timeout 30s;
        proxy_connect_timeout 5s;
    }
}
```

#### `/etc/nginx/upstream.conf`（运行时由 updater.sh 重写）

```nginx
upstream google_translate {
    server 142.250.196.78:443 max_fails=3 fail_timeout=30s;
    server 142.250.199.110:443 backup;
    server 172.217.160.110:443 backup;
}
```

要点：

1. **不需要按 SNI 分流**：三个 translate 域名都去 Google，共享一组 GFE，单 upstream 足够。如未来 Google 拆分到不同 IP 段再扩展，当前不为此预留抽象（YAGNI）。
2. **`ssl_preread on`** 仅用于把 SNI 写入日志，不影响转发。
3. **故障切换**：主 IP `max_fails=3 fail_timeout=30s`，失败时 30 秒内自动切到 backup，比等下一轮健康检查更快。
4. **reload 而非 restart**：`nginx -s reload` 平滑生效，已建立连接不断。

### updater.sh：健康检查 + 按需扫描

常驻 shell，约 80 行，事件驱动。

#### 状态文件

```
/var/lib/translate-proxy/current_ip   # 当前在用 IP
/var/lib/translate-proxy/last_scan    # 上次扫描完成时间戳
/var/lib/translate-proxy/fail_count   # 连续失败计数
```

#### 主循环伪代码

```bash
#!/bin/sh
set -eu

: "${HEALTH_CHECK_INTERVAL:=4h}"
: "${HEALTH_CHECK_TIMEOUT:=5}"
: "${HEALTH_CHECK_FAIL_THRESHOLD:=2}"
: "${SCAN_COOLDOWN:=10m}"
: "${HOSTS:=translate.googleapis.com,translate.google.com,translate-pa.googleapis.com}"
PRIMARY_HOST=$(echo "$HOSTS" | cut -d, -f1)

bootstrap_if_needed   # 首次启动且无 current_ip → 立即扫描一次
while true; do
    if check_health "$(cat $CURRENT_IP_FILE)"; then
        echo 0 > $FAIL_FILE
        log "OK current_ip=$(cat $CURRENT_IP_FILE)"
    else
        n=$(($(cat $FAIL_FILE) + 1))
        echo $n > $FAIL_FILE
        log "WARN health-check failed (#$n)"
        if [ $n -ge $HEALTH_CHECK_FAIL_THRESHOLD ]; then
            if cooldown_passed; then
                rescan_and_apply
                echo 0 > $FAIL_FILE
            else
                log "in cooldown, skip rescan"
            fi
        fi
    fi
    sleep "$HEALTH_CHECK_INTERVAL"
done
```

#### 关键函数

`check_health()`：用 `curl --resolve` 直接打 Google API，校验返回包含 `Hello`，与 .NET 扫描器探活逻辑一致。

```bash
check_health() {
    ip=$1
    [ -z "$ip" ] && return 1
    out=$(curl -sk --resolve "$PRIMARY_HOST:443:$ip" \
                --max-time "$HEALTH_CHECK_TIMEOUT" \
                "https://$PRIMARY_HOST/translate_a/single?client=gtx&sl=zh-CN&tl=en&dt=t&q=你好" \
                || true)
    echo "$out" | grep -q "Hello"
}
```

`rescan_and_apply()`：调 .NET 扫描器（参数 `-s` 进入扫描模式），从 `ip.txt` 取首行作为主 IP、随后 4 行作为 backup，写 `upstream.conf` 后 `nginx -s reload`。

```bash
rescan_and_apply() {
    log "=== triggering rescan ==="
    cd /opt/scanner
    if ! ./GoogleTranslateIpCheck -s; then
        log "ERROR scanner failed"
        return 1
    fi
    best=$(head -n1 ip.txt | tr -d '\r\n ')
    backups=$(tail -n +2 ip.txt | head -n4 | tr -d '\r' | grep -v '^$')
    [ -z "$best" ] && { log "ERROR no usable ip found"; return 1; }
    write_upstream_conf "$best" "$backups"
    nginx -s reload
    echo "$best" > $CURRENT_IP_FILE
    date +%s > $LAST_SCAN_FILE
    log "=== applied new ip=$best ==="
}
```

`cooldown_passed()`：若距上次扫描不足 `SCAN_COOLDOWN` 则跳过本轮扫描，防止 IP 半死状态下反复触发。

#### 启动顺序（entrypoint.sh）

1. 启动 `nginx -g "daemon off;" &`（后台），首次无 `upstream.conf` 时使用占位 upstream（`127.0.0.1:1`）让 nginx 不报错
2. `updater.sh`：bootstrap 触发首次扫描；进入主循环
3. `wait $nginx_pid`，任一退出则容器退出，由 `restart=always` 兜底

### 配置参数（环境变量）

全部可选，未设置时走默认值。

| 变量 | 默认值 | 含义 |
|---|---|---|
| `HEALTH_CHECK_INTERVAL` | `4h` | 健康检查间隔（支持 `s/m/h`） |
| `HEALTH_CHECK_TIMEOUT` | `5` | 单次 curl 超时（秒） |
| `HEALTH_CHECK_FAIL_THRESHOLD` | `2` | 连续失败几次才触发扫描 |
| `SCAN_TIMEOUT` | `4` | 扫描器单 IP 超时（秒，传给 .NET） |
| `SCAN_CONCURRENCY` | `80` | 扫描并发数 |
| `SCAN_LIMIT` | `5` | 找到几个可用 IP 后停止扫描 |
| `SCAN_COOLDOWN` | `10m` | 两次扫描的最小间隔 |
| `LISTEN_PORT` | `443` | nginx 监听端口（实际不应改，hosts 不支持端口） |
| `HOSTS` | `translate.googleapis.com,translate.google.com,translate-pa.googleapis.com` | 接管的域名 |

`SCAN_TIMEOUT` / `SCAN_CONCURRENCY` / `SCAN_LIMIT` 由 `entrypoint.sh` 启动时改写到 `/opt/scanner/config.json` 的 `扫描超时` / `扫描并发数` / `IP扫描限制数量` 字段，其它字段（IP 段）走 .NET 默认。

## Docker 镜像与部署

### Dockerfile（多阶段，最终镜像 ~30MB）

```dockerfile
# Stage 1: 编译 .NET 扫描器为 self-contained 单文件
FROM mcr.microsoft.com/dotnet/sdk:8.0-alpine AS build
WORKDIR /src
COPY src/GoogleTranslateIpCheck/ ./
RUN dotnet publish GoogleTranslateIpCheck/GoogleTranslateIpCheck.csproj \
    -c Release -r linux-musl-x64 \
    --self-contained true \
    -p:PublishSingleFile=true \
    -p:PublishTrimmed=true \
    -o /out

# Stage 2: 运行镜像
FROM nginx:1.27-alpine
RUN apk add --no-cache curl bash icu-libs \
 && mkdir -p /var/lib/translate-proxy /opt/scanner

COPY --from=build /out/GoogleTranslateIpCheck /opt/scanner/
COPY docker/nginx.conf              /etc/nginx/nginx.conf
COPY docker/upstream.bootstrap.conf /etc/nginx/upstream.conf
COPY docker/updater.sh              /usr/local/bin/updater.sh
COPY docker/entrypoint.sh           /usr/local/bin/entrypoint.sh
COPY docker/scanner-config.json     /opt/scanner/config.json
RUN chmod +x /usr/local/bin/updater.sh \
             /usr/local/bin/entrypoint.sh \
             /opt/scanner/GoogleTranslateIpCheck

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
```

### `docker-compose.yml`

```yaml
services:
  translate-proxy:
    build: .
    image: translate-proxy:latest
    container_name: translate-proxy
    network_mode: host
    restart: always
    environment:
      TZ: Asia/Shanghai
      # 全部可选，注释掉走默认值
      # HEALTH_CHECK_INTERVAL: 4h
      # HEALTH_CHECK_TIMEOUT: 5
      # HEALTH_CHECK_FAIL_THRESHOLD: 2
      # SCAN_TIMEOUT: 4
      # SCAN_CONCURRENCY: 80
      # SCAN_LIMIT: 5
      # SCAN_COOLDOWN: 10m
      # HOSTS: "translate.googleapis.com,translate.google.com,translate-pa.googleapis.com"
    volumes:
      - ./data:/var/lib/translate-proxy
    logging:
      driver: json-file
      options: { max-size: "10m", max-file: "3" }
```

### 仓库目录布局（新增部分）

```
GoogleTranslateIpCheck/
├── src/...                           # 现有 .NET，不动
├── docker/                           # 新增
│   ├── Dockerfile
│   ├── docker-compose.yml
│   ├── nginx.conf
│   ├── upstream.bootstrap.conf
│   ├── updater.sh
│   ├── entrypoint.sh
│   └── scanner-config.json
└── docs/superpowers/specs/2026-06-14-translate-proxy-design.md
```

### 部署前置条件

- 服务器 443 端口空闲（`sudo ss -lntp | grep ':443 '` 空输出）
- 服务器 LAN IP 静态化（路由器 DHCP 静态绑定或系统内静态配置）
- 防火墙放行 LAN 入站 443，例如 `ufw allow from 192.168.0.0/16 to any port 443`
- **服务器自己能直连 Google IP**（这是整套方案的前提，扫描器需要直接探测 Google）

### 部署命令

```bash
docker compose up -d --build
docker logs -f translate-proxy
```

## 客户端配置（Win10/11）

一次性手动操作，需管理员权限：

1. 管理员身份打开记事本
2. 打开 `C:\Windows\System32\drivers\etc\hosts`（文件类型选"所有文件"）
3. 末尾追加：

   ```
   192.168.x.y translate.googleapis.com
   192.168.x.y translate.google.com
   192.168.x.y translate-pa.googleapis.com
   ```

4. 保存。新进程立即生效。
5. 可选：管理员 PowerShell `ipconfig /flushdns`

## 端到端验证 checklist

部署完后按顺序验证：

1. **容器启动 + 首次扫描**：`docker logs -f translate-proxy` 看到 `[apply] new ip=...` 与 `[health] OK`
2. **服务器本机自测**：

   ```bash
   curl -sk --resolve translate.googleapis.com:443:127.0.0.1 \
     "https://translate.googleapis.com/translate_a/single?client=gtx&sl=zh-CN&tl=en&dt=t&q=你好" | head -c 200
   ```

   返回包含 `Hello`
3. **局域网其他机器测**：把 `127.0.0.1` 换成服务器 LAN IP 重跑同 curl
4. **客户端 hosts 生效**：`ping translate.googleapis.com` 回显 IP 应为服务器 LAN IP
5. **客户端实际翻译**：浏览器访问 https://translate.google.com 能正常使用
6. **故障切换演练**（可选）：手动改坏 `data/current_ip` 为 `1.2.3.4`，临时调短 `HEALTH_CHECK_INTERVAL=2m`，观察日志触发重扫并自愈

## 故障排查速查

| 症状 | 大概率原因 |
|---|---|
| `ping translate.googleapis.com` 仍指向 Google | hosts 未保存 / BOM / 没用管理员 |
| 浏览器 `ERR_CERT_AUTHORITY_INVALID` | 误改成 TLS 终止模式（应只用 stream + ssl_preread） |
| 浏览器 `ERR_CONNECTION_REFUSED` | 服务器 443 未监听 / 防火墙拦截 |
| 浏览器超时 | 当前 upstream IP 失效，等下一轮健康检查或手动删 `data/current_ip` 触发重扫 |
| 日志持续 `ERROR scanner failed` | 服务器到 Google 出网不通；需先解决服务器侧出网 |

## 备选方案（已否决）

- **本地 DNS 服务**：客户端改 DNS 指向服务器，dnsmasq 解析 translate.* 到当前最优 IP。否决：浏览器 DoH 会绕过；客户端要改网络设置而非简单改 hosts。
- **仅 IP 分发**：服务器只暴露 ip.txt，客户端继续跑 .NET 工具拉远程 IP 写本地 hosts。否决：没解决"客户端要定时跑工具/写 hosts"的核心痛点。
- **TLS 终止**：服务器自签证书冒充 Google。否决：Chrome 对 Google 域名有证书钉扎，必失败；且需要分发根证书。
- **群晖 host 网络模式**：群晖 DSM 7.2.1 自带 nginx 占用 80/443，host 模式直接冲突。改用 Ubuntu 虚拟机绕开。
- **群晖 macvlan 模式**：可行但有"宿主访问不到容器 IP"等坑，且依赖路由器 DHCP 静态绑定。Ubuntu 方案更干净，本次不采用。

## 不在范围

- IPv6 支持（占位字段保留默认，不实现）
- 状态查询 HTTP 端口（仅日志即可）
- Prometheus / metrics 接口
- 客户端一键安装脚本
- 服务器侧出网到 Google 的代理配置（前提，由用户自行解决）
