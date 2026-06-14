# 谷歌翻译 IP 中转服务实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 Ubuntu 服务器以 `network_mode: host` 部署一个 Docker 容器，对内网客户端中转 Google 翻译流量；nginx stream + SNI 透传，updater.sh 周期健康检查，失败时调用现有 .NET 扫描器更新最优 IP 并 reload nginx。

**Architecture:** 单容器多进程：nginx 监听 443 做 4 层 TCP 透传；常驻 shell `updater.sh` 周期 curl 探活当前 upstream IP，连续失败达阈值时调用 `GoogleTranslateIpCheck`（一次性 NativeAOT 二进制），从 `ip.txt` 取最佳 IP 重写 `/etc/nginx/upstream.conf` 并 `nginx -s reload`。状态文件持久化到 `/var/lib/translate-proxy`（外挂 `./data`）。

**Tech Stack:** Docker / docker compose v2、nginx 1.27 alpine（含 stream + ssl_preread）、busybox sh、curl、.NET 9 NativeAOT (linux-musl-x64) 复用现有 `src/GoogleTranslateIpCheck`。

**Spec:** `docs/superpowers/specs/2026-06-14-translate-proxy-design.md`

---

## 文件结构

```
GoogleTranslateIpCheck/
├── docker/
│   ├── Dockerfile                     # 多阶段：AOT 编译扫描器 + nginx 运行镜像
│   ├── docker-compose.yml             # host 网络、环境变量、日志/数据卷
│   ├── nginx.conf                     # stream + ssl_preread + 单 server
│   ├── upstream.bootstrap.conf        # 首启动占位 upstream，让 nginx 不报错
│   ├── scanner-config.json            # 注入 .NET 扫描器的初始 config（少数字段会被 entrypoint 覆写）
│   ├── entrypoint.sh                  # 启动顺序：覆写 scanner config → 起 nginx → 跑 updater
│   ├── updater.sh                     # 健康检查主循环 + 按需扫描 + reload
│   └── .dockerignore
├── docs/superpowers/specs/2026-06-14-translate-proxy-design.md   # 已存在
├── docs/superpowers/plans/2026-06-14-translate-proxy.md          # 本文件
└── README.md                          # 末尾加"局域网中转部署"章节
```

设计单元划分：
- 配置（nginx.conf / upstream.bootstrap.conf / scanner-config.json）：构建期固定，由镜像内置
- 控制（updater.sh / entrypoint.sh）：运行期变量驱动；按 shell 函数划分职责，每个函数 < 30 行
- 编排（Dockerfile / docker-compose.yml）：镜像构建 + 部署形态
- 数据（`./data` 卷下 `current_ip` / `last_scan` / `fail_count`）：唯一可写状态

---

## 准备工作

每个任务结束都做小 commit。整个 plan 假设你在 Windows 主机仓库根目录 `E:\ai\GoogleTranslateIpCheck` 工作，使用 PowerShell；可执行验证用到的 `bash` 来自 Git for Windows，仓库自带 `.gitattributes` 已处理 LF。

最后整体验证（Task 13/14）需要一台 Ubuntu 服务器（或本地 WSL2）有 docker compose v2 与到 Google 的直连出网。

---

### Task 1: 创建 docker 目录骨架与 .dockerignore

**Files:**
- Create: `docker/.dockerignore`
- Create: `data/.gitkeep`（空文件，让 `./data` 卷目录纳入 git）
- Modify: `.gitignore`

- [ ] **Step 1: 新建目录与占位文件**

```powershell
New-Item -ItemType Directory -Force docker
New-Item -ItemType Directory -Force data
New-Item -ItemType File     -Force data\.gitkeep
```

- [ ] **Step 2: 写 docker/.dockerignore**

文件内容（`docker/.dockerignore`）：

```
# 仅把扫描器源码 + docker 资源拷进构建上下文
**/.git
**/.vs
**/bin
**/obj
**/*.user
data
docs
*.md
LICENSE.txt
src/GoogleTranslateIpCheck/GoogleTranslateIpCheck/ip.txt
src/GoogleTranslateIpCheck/GoogleTranslateIpCheck/IPv6.txt
src/GoogleTranslateIpCheck/GoogleTranslateIpCheck/fullIp.txt
```

- [ ] **Step 3: 改 .gitignore，忽略运行期 data 但保留占位**

把以下两行追加到 `.gitignore`（如已有同名行可跳过）：

```
# 运行期状态
/data/*
!/data/.gitkeep
```

- [ ] **Step 4: 验证目录结构**

```powershell
Get-ChildItem docker, data -Force
```

期望：`docker/.dockerignore` 存在；`data/.gitkeep` 存在；其他无内容。

- [ ] **Step 5: 提交**

```bash
git add docker/.dockerignore data/.gitkeep .gitignore
git commit -m "🤡 chore: 初始化 docker 目录与 data 占位"
```

---

### Task 2: nginx.conf — stream 配置

**Files:**
- Create: `docker/nginx.conf`

- [ ] **Step 1: 写 docker/nginx.conf**

```nginx
worker_processes auto;
error_log /dev/stderr warn;
pid       /tmp/nginx.pid;

events {
    worker_connections 1024;
}

# 关键：用 stream 而不是 http，做 4 层 TCP 透传，不解密 TLS
stream {
    log_format basic '$remote_addr [$time_local] '
                     'sni=$ssl_preread_server_name -> $upstream_addr '
                     'bytes=$bytes_sent dur=$session_time';
    access_log /dev/stdout basic;

    # 由 updater.sh 在运行期重写
    include /etc/nginx/upstream.conf;

    server {
        listen 443;
        proxy_pass google_translate;
        ssl_preread on;            # 仅读 SNI 字段，不终止 TLS
        proxy_timeout 30s;
        proxy_connect_timeout 5s;
    }
}
```

- [ ] **Step 2: 用 docker 一次性容器跑 nginx -t 做语法校验**

```powershell
docker run --rm -v "${PWD}\docker\nginx.conf:/etc/nginx/nginx.conf:ro" `
  -v "${PWD}\docker\upstream.bootstrap.conf:/etc/nginx/upstream.conf:ro" `
  nginx:1.27-alpine nginx -t
```

期望：尚不能跑（upstream.bootstrap.conf 还不存在）。**跳过本步**，留到 Task 3 之后联合验证。

- [ ] **Step 3: 提交**

```bash
git add docker/nginx.conf
git commit -m "🤡 feat: 新增 nginx stream 透传配置"
```

---

### Task 3: upstream.bootstrap.conf — 占位 upstream

让首启动期 nginx 能起来（在 updater.sh 写出真正 upstream 之前）。

**Files:**
- Create: `docker/upstream.bootstrap.conf`

- [ ] **Step 1: 写占位 upstream**

```nginx
# 占位：首启动时 updater.sh 还没扫到真实 IP。
# 指向不可达地址即可，反正客户端此时也未配置。
upstream google_translate {
    server 127.0.0.1:1 max_fails=0;
}
```

- [ ] **Step 2: 联合 nginx.conf 做语法校验**

```powershell
docker run --rm `
  -v "${PWD}\docker\nginx.conf:/etc/nginx/nginx.conf:ro" `
  -v "${PWD}\docker\upstream.bootstrap.conf:/etc/nginx/upstream.conf:ro" `
  nginx:1.27-alpine nginx -t
```

期望输出末尾：
```
nginx: configuration file /etc/nginx/nginx.conf test is successful
```

如果报 `unknown directive "stream"`：你用错镜像了，必须是官方 `nginx:1.27-alpine`（含 stream 模块）。

- [ ] **Step 3: 提交**

```bash
git add docker/upstream.bootstrap.conf
git commit -m "🤡 feat: 新增 nginx 占位 upstream 配置"
```

---

### Task 4: scanner-config.json — 扫描器初始配置

复用现有 `src/GoogleTranslateIpCheck/GoogleTranslateIpCheck/config.json` 字段，但远程 IP 文件、Hosts、IP 段全部沿用上游默认；少数字段（`扫描超时` / `扫描并发数` / `IP扫描限制数量`）由 `entrypoint.sh` 启动时按环境变量覆写。

**Files:**
- Create: `docker/scanner-config.json`

- [ ] **Step 1: 写默认 scanner-config.json**

```json
{
  "远程IP文件": "https://mirror.ghproxy.com/https://raw.githubusercontent.com/Ponderfly/GoogleTranslateIpCheck/master/src/GoogleTranslateIpCheck/GoogleTranslateIpCheck/ip.txt",
  "远程IPv6文件": "https://mirror.ghproxy.com/https://raw.githubusercontent.com/Ponderfly/GoogleTranslateIpCheck/master/src/GoogleTranslateIpCheck/GoogleTranslateIpCheck/IPv6.txt",
  "IP扫描限制数量": 5,
  "扫描超时": 4,
  "扫描并发数": 80,
  "Hosts": [
    "translate.googleapis.com",
    "translate.google.com",
    "translate-pa.googleapis.com"
  ],
  "IP段": [
    "142.250.0.0/15",
    "172.217.0.0/16",
    "172.253.0.0/16",
    "108.177.0.0/17",
    "72.14.192.0/18",
    "74.125.0.0/16",
    "216.58.192.0/19"
  ],
  "IPv6段": [
    "2404:6800:4008:c15::0/112"
  ]
}
```

- [ ] **Step 2: JSON 语法校验**

```powershell
Get-Content docker\scanner-config.json -Raw | ConvertFrom-Json | Out-Null
```

期望：无报错（命令静默成功）。

- [ ] **Step 3: 提交**

```bash
git add docker/scanner-config.json
git commit -m "🤡 feat: 新增扫描器初始 config.json"
```

---

### Task 5: updater.sh — 头部、环境变量默认值、日志与状态路径

把 updater.sh 拆成 4 个小任务（Task 5 → Task 8），每段函数都自带 syntax check。

**Files:**
- Create: `docker/updater.sh`

- [ ] **Step 1: 写 updater.sh 第一段（头部 + 环境变量默认值 + log 函数 + 路径常量）**

```bash
#!/bin/sh
# updater.sh — 健康检查 + 按需触发 .NET 扫描器 + nginx reload。
# 在 Alpine busybox sh 下运行（不是 bash），避免使用 bash-only 语法。
set -eu

# ---- 环境变量默认值（全部可被 docker -e 覆盖）----
: "${HEALTH_CHECK_INTERVAL:=4h}"
: "${HEALTH_CHECK_TIMEOUT:=5}"
: "${HEALTH_CHECK_FAIL_THRESHOLD:=2}"
: "${SCAN_COOLDOWN:=10m}"
: "${HOSTS:=translate.googleapis.com,translate.google.com,translate-pa.googleapis.com}"

PRIMARY_HOST=$(echo "$HOSTS" | cut -d, -f1)

# ---- 路径常量 ----
STATE_DIR=/var/lib/translate-proxy
CURRENT_IP_FILE="$STATE_DIR/current_ip"
LAST_SCAN_FILE="$STATE_DIR/last_scan"
FAIL_FILE="$STATE_DIR/fail_count"
UPSTREAM_CONF=/etc/nginx/upstream.conf
SCANNER_DIR=/opt/scanner
SCANNER_BIN="$SCANNER_DIR/GoogleTranslateIpCheck"
SCANNER_IP_TXT="$SCANNER_DIR/ip.txt"

mkdir -p "$STATE_DIR"
[ -f "$FAIL_FILE" ] || echo 0 > "$FAIL_FILE"

log() {
    printf '%s [updater] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

# 把 "10m" / "4h" / "30s" 这种时长字符串转成秒。busybox sleep 支持原样字符串，
# 但 cooldown 比较需要数值，所以提供这个转换函数。
to_seconds() {
    val="$1"
    num=$(echo "$val" | sed 's/[^0-9]//g')
    unit=$(echo "$val" | sed 's/[0-9]//g')
    [ -z "$num" ] && { echo 0; return; }
    case "$unit" in
        s|"") echo "$num" ;;
        m)    echo $((num * 60)) ;;
        h)    echo $((num * 3600)) ;;
        d)    echo $((num * 86400)) ;;
        *)    echo "$num" ;;
    esac
}

log "boot: HEALTH_CHECK_INTERVAL=$HEALTH_CHECK_INTERVAL FAIL_THRESHOLD=$HEALTH_CHECK_FAIL_THRESHOLD COOLDOWN=$SCAN_COOLDOWN"
```

- [ ] **Step 2: 语法检查（busybox 兼容）**

```powershell
docker run --rm -v "${PWD}\docker\updater.sh:/u.sh:ro" alpine:3.20 sh -n /u.sh
```

期望：无输出（语法 OK）。

- [ ] **Step 3: 单测 to_seconds 函数**

```powershell
docker run --rm -v "${PWD}\docker\updater.sh:/u.sh:ro" alpine:3.20 sh -c '
. /u.sh 2>/dev/null || true
[ "$(to_seconds 10s)"  = "10"   ] || { echo "FAIL 10s"; exit 1; }
[ "$(to_seconds 4h)"   = "14400" ] || { echo "FAIL 4h"; exit 1; }
[ "$(to_seconds 10m)"  = "600"  ] || { echo "FAIL 10m"; exit 1; }
[ "$(to_seconds 7)"    = "7"    ] || { echo "FAIL 7"; exit 1; }
echo OK
'
```

期望：最后一行 `OK`。

> 注：`. /u.sh` 会顺带执行后面的主循环占位代码，但本任务里 updater.sh 没有循环，所以正常返回。后续任务里加了 while 循环后这种 source 测试就不再适用——届时改用别的方式验证。

- [ ] **Step 4: 提交**

```bash
git add docker/updater.sh
git commit -m "🤡 feat(updater): 头部、环境变量默认值与日志/路径常量"
```

---

### Task 6: updater.sh — check_health 与 cooldown_passed

**Files:**
- Modify: `docker/updater.sh`（追加在文件末尾、`log "boot: ..."` 之后）

- [ ] **Step 1: 在 updater.sh 末尾追加 check_health 与 cooldown_passed**

打开 `docker/updater.sh`，**保留 Task 5 的内容**，在文件末尾追加：

```bash
# ---- 健康检查 ----
# 用 curl --resolve 把 PRIMARY_HOST 强制解析到给定 IP，
# 只看返回是否包含 "Hello"——和 .NET 扫描器探活逻辑一致。
check_health() {
    ip="$1"
    [ -z "$ip" ] && return 1
    out=$(curl -sk \
              --resolve "$PRIMARY_HOST:443:$ip" \
              --max-time "$HEALTH_CHECK_TIMEOUT" \
              "https://$PRIMARY_HOST/translate_a/single?client=gtx&sl=zh-CN&tl=en&dt=t&q=%E4%BD%A0%E5%A5%BD" \
              2>/dev/null || true)
    echo "$out" | grep -q "Hello"
}

# ---- 扫描冷却 ----
# 距上次成功扫描 < SCAN_COOLDOWN 时跳过，防止 IP 抖动期反复触发扫描烧机器。
cooldown_passed() {
    [ ! -f "$LAST_SCAN_FILE" ] && return 0
    last=$(cat "$LAST_SCAN_FILE")
    cooldown_sec=$(to_seconds "$SCAN_COOLDOWN")
    now=$(date +%s)
    [ $((now - last)) -ge "$cooldown_sec" ]
}
```

- [ ] **Step 2: 语法检查**

```powershell
docker run --rm -v "${PWD}\docker\updater.sh:/u.sh:ro" alpine:3.20 sh -n /u.sh
```

期望：无输出。

- [ ] **Step 3: 提交**

```bash
git add docker/updater.sh
git commit -m "🤡 feat(updater): 增加 check_health 与 cooldown_passed"
```

---

### Task 7: updater.sh — write_upstream_conf 与 rescan_and_apply

**Files:**
- Modify: `docker/updater.sh`（继续追加在末尾）

- [ ] **Step 1: 追加 write_upstream_conf 与 rescan_and_apply**

```bash
# ---- 重写 nginx upstream.conf ----
# 第 1 个参数：主 IP；第 2 个参数：以换行分隔的 backup IP 列表（可空）。
write_upstream_conf() {
    primary="$1"
    backups="$2"
    {
        echo "upstream google_translate {"
        echo "    server $primary:443 max_fails=3 fail_timeout=30s;"
        # 如果 backup IP 集合非空，逐行写入
        echo "$backups" | while IFS= read -r b; do
            [ -n "$b" ] && echo "    server $b:443 backup;"
        done
        echo "}"
    } > "$UPSTREAM_CONF.tmp"
    mv "$UPSTREAM_CONF.tmp" "$UPSTREAM_CONF"
}

# ---- 触发一次扫描，把结果应用到 nginx ----
rescan_and_apply() {
    log "=== triggering rescan ==="
    cd "$SCANNER_DIR" || { log "ERROR cannot cd $SCANNER_DIR"; return 1; }
    rm -f "$SCANNER_IP_TXT"
    # -s = 进入扫描模式
    if ! "$SCANNER_BIN" -s; then
        log "ERROR scanner exited non-zero"
        return 1
    fi
    if [ ! -s "$SCANNER_IP_TXT" ]; then
        log "ERROR scanner did not produce ip.txt"
        return 1
    fi
    best=$(head -n 1 "$SCANNER_IP_TXT" | tr -d '\r\n ')
    backups=$(tail -n +2 "$SCANNER_IP_TXT" | head -n 4 | tr -d '\r' | grep -v '^$' || true)
    if [ -z "$best" ]; then
        log "ERROR no usable ip in ip.txt"
        return 1
    fi
    write_upstream_conf "$best" "$backups"
    if ! nginx -s reload; then
        log "ERROR nginx reload failed"
        return 1
    fi
    echo "$best" > "$CURRENT_IP_FILE"
    date +%s > "$LAST_SCAN_FILE"
    log "=== applied new ip=$best (backups: $(echo "$backups" | tr '\n' ' '))==="
}
```

- [ ] **Step 2: 语法检查**

```powershell
docker run --rm -v "${PWD}\docker\updater.sh:/u.sh:ro" alpine:3.20 sh -n /u.sh
```

期望：无输出。

- [ ] **Step 3: 验证 write_upstream_conf 输出格式**

```powershell
docker run --rm -v "${PWD}\docker\updater.sh:/u.sh:ro" alpine:3.20 sh -c '
UPSTREAM_CONF=/tmp/upstream.conf
. /u.sh > /dev/null 2>&1 || true
write_upstream_conf "1.2.3.4" "$(printf "5.6.7.8\n9.10.11.12\n")"
cat $UPSTREAM_CONF
'
```

期望输出：

```
upstream google_translate {
    server 1.2.3.4:443 max_fails=3 fail_timeout=30s;
    server 5.6.7.8:443 backup;
    server 9.10.11.12:443 backup;
}
```

- [ ] **Step 4: 提交**

```bash
git add docker/updater.sh
git commit -m "🤡 feat(updater): 增加 write_upstream_conf 与 rescan_and_apply"
```

---

### Task 8: updater.sh — 主循环 + bootstrap

**Files:**
- Modify: `docker/updater.sh`（继续追加在末尾）

- [ ] **Step 1: 追加 bootstrap_if_needed 与主循环**

```bash
# ---- 首次启动若没有 current_ip 立即扫一次 ----
bootstrap_if_needed() {
    if [ ! -s "$CURRENT_IP_FILE" ]; then
        log "bootstrap: no current_ip, performing initial scan"
        if ! rescan_and_apply; then
            log "bootstrap: initial scan failed; will retry on next cycle"
        fi
    else
        log "bootstrap: reusing current_ip=$(cat "$CURRENT_IP_FILE")"
    fi
}

# ---- 主循环 ----
bootstrap_if_needed

while true; do
    cur=$(cat "$CURRENT_IP_FILE" 2>/dev/null || true)
    if [ -n "$cur" ] && check_health "$cur"; then
        echo 0 > "$FAIL_FILE"
        log "OK current_ip=$cur"
    else
        n=$(( $(cat "$FAIL_FILE") + 1 ))
        echo "$n" > "$FAIL_FILE"
        log "WARN health-check failed (#$n) for ip=${cur:-<none>}"
        if [ "$n" -ge "$HEALTH_CHECK_FAIL_THRESHOLD" ]; then
            if cooldown_passed; then
                if rescan_and_apply; then
                    echo 0 > "$FAIL_FILE"
                fi
            else
                log "in cooldown ($SCAN_COOLDOWN since last scan), skip"
            fi
        fi
    fi
    sleep "$HEALTH_CHECK_INTERVAL"
done
```

- [ ] **Step 2: 语法检查**

```powershell
docker run --rm -v "${PWD}\docker\updater.sh:/u.sh:ro" alpine:3.20 sh -n /u.sh
```

期望：无输出。

- [ ] **Step 3: 提交**

```bash
git add docker/updater.sh
git commit -m "🤡 feat(updater): 增加 bootstrap 与主循环"
```

---

### Task 9: entrypoint.sh — 启动顺序

职责：
1. 把 `SCAN_TIMEOUT` / `SCAN_CONCURRENCY` / `SCAN_LIMIT` 三个环境变量改写到 `/opt/scanner/config.json` 中对应的中文字段
2. 后台启动 `nginx -g "daemon off;"`
3. 前台跑 `updater.sh`
4. nginx 退出则容器退出（由 `restart=always` 兜底）

**Files:**
- Create: `docker/entrypoint.sh`

- [ ] **Step 1: 写 entrypoint.sh**

```bash
#!/bin/sh
set -eu

: "${SCAN_TIMEOUT:=4}"
: "${SCAN_CONCURRENCY:=80}"
: "${SCAN_LIMIT:=5}"

CONFIG=/opt/scanner/config.json

# 用 sed 改写中文字段值。这是最朴素方式，避免引入 jq；
# 字段名固定且独占整行 "key": value, 风险可控。
patch_config() {
    key="$1"; val="$2"
    # 整数值，匹配 "key": <数字>,? 替换为 "key": $val,
    sed -i -E "s/(\"$key\"[[:space:]]*:[[:space:]]*)[0-9]+/\\1$val/" "$CONFIG"
}

patch_config "扫描超时"        "$SCAN_TIMEOUT"
patch_config "扫描并发数"      "$SCAN_CONCURRENCY"
patch_config "IP扫描限制数量"  "$SCAN_LIMIT"

echo "[entrypoint] scanner config patched: 扫描超时=$SCAN_TIMEOUT 扫描并发数=$SCAN_CONCURRENCY IP扫描限制数量=$SCAN_LIMIT"

# 启动 nginx（后台），失败立即退出
nginx -g "daemon off;" &
NGINX_PID=$!

# 启动 updater 主循环（前台）
/usr/local/bin/updater.sh &
UPDATER_PID=$!

# 任一退出则整个容器退出
wait -n "$NGINX_PID" "$UPDATER_PID"
EXIT=$?
echo "[entrypoint] subprocess exited with $EXIT, shutting down"
kill "$NGINX_PID" "$UPDATER_PID" 2>/dev/null || true
exit "$EXIT"
```

- [ ] **Step 2: 语法检查**

```powershell
docker run --rm -v "${PWD}\docker\entrypoint.sh:/e.sh:ro" alpine:3.20 sh -n /e.sh
```

期望：无输出。

- [ ] **Step 3: 验证 patch_config 对中文 key 工作正常**

```powershell
docker run --rm `
  -v "${PWD}\docker\entrypoint.sh:/e.sh:ro" `
  -v "${PWD}\docker\scanner-config.json:/orig.json:ro" `
  alpine:3.20 sh -c '
cp /orig.json /tmp/c.json
sed -i -E "s/(\"扫描超时\"[[:space:]]*:[[:space:]]*)[0-9]+/\\17/" /tmp/c.json
grep "扫描超时" /tmp/c.json
'
```

期望输出含：`"扫描超时": 7,`

- [ ] **Step 4: 提交**

```bash
git add docker/entrypoint.sh
git commit -m "🤡 feat: 新增 entrypoint.sh"
```

---

### Task 10: Dockerfile — 多阶段（NativeAOT 编译 + nginx 运行镜像）

注意：现有 `.csproj` 用 **net9.0** 且 `<PublishAot>true</PublishAot>`。AOT 在 Alpine 上需要 `clang` / `build-base` / `zlib-dev` 工具链。

**Files:**
- Create: `docker/Dockerfile`

- [ ] **Step 1: 写 Dockerfile**

```dockerfile
# syntax=docker/dockerfile:1.6

# ============================================================
# Stage 1: 用 .NET 9 SDK + AOT 工具链编译扫描器为 native 单文件
# ============================================================
FROM mcr.microsoft.com/dotnet/sdk:9.0-alpine AS build
RUN apk add --no-cache build-base clang zlib-dev

WORKDIR /src
# 只拷扫描器源码，不拷整个仓库（.dockerignore 也兜底）
COPY src/GoogleTranslateIpCheck/ ./

# Restore + AOT publish
RUN dotnet restore GoogleTranslateIpCheck/GoogleTranslateIpCheck.csproj \
        -r linux-musl-x64 \
 && dotnet publish GoogleTranslateIpCheck/GoogleTranslateIpCheck.csproj \
        -c Release \
        -r linux-musl-x64 \
        --no-restore \
        -o /out

# ============================================================
# Stage 2: nginx 1.27 alpine + curl + bash + 扫描器二进制
# ============================================================
FROM nginx:1.27-alpine

# curl 用于健康检查；icu-libs 是 .NET 国际化所需（保险起见装上，AOT 也可能用到）
RUN apk add --no-cache curl icu-libs ca-certificates \
 && mkdir -p /var/lib/translate-proxy /opt/scanner

# 拷贝扫描器二进制（NativeAOT 输出的可执行文件名就是 GoogleTranslateIpCheck）
COPY --from=build /out/GoogleTranslateIpCheck /opt/scanner/GoogleTranslateIpCheck

# 镜像内置默认 scanner config
COPY docker/scanner-config.json     /opt/scanner/config.json

# nginx 配置
COPY docker/nginx.conf              /etc/nginx/nginx.conf
COPY docker/upstream.bootstrap.conf /etc/nginx/upstream.conf

# 控制脚本
COPY docker/updater.sh              /usr/local/bin/updater.sh
COPY docker/entrypoint.sh           /usr/local/bin/entrypoint.sh

RUN chmod +x /usr/local/bin/updater.sh \
             /usr/local/bin/entrypoint.sh \
             /opt/scanner/GoogleTranslateIpCheck

# host 模式下 EXPOSE 仅做文档
EXPOSE 443

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
```

- [ ] **Step 2: 本地构建镜像**

> 此步需要 docker 引擎；Windows 主机用 Docker Desktop。如果你打算只在 Ubuntu 服务器上构建，这步可以**推迟到 Task 13**，但越早构建越早暴露问题。

```powershell
docker build -f docker\Dockerfile -t translate-proxy:dev .
```

期望：Stage 1 完成 AOT 编译（耗时几分钟），Stage 2 拷贝并最终输出镜像。最终镜像 `docker images translate-proxy:dev` 应在 80–120 MB 之间（AOT binary 比 SingleFile 略大）。

如果失败：
- `Microsoft.NET.Sdk` 找不到 net9.0：换 `mcr.microsoft.com/dotnet/sdk:9.0` 而不是 `9.0-alpine` 试试，但运行时仍要 musl 平台
- AOT 链接报缺 `lld`：在 `RUN apk add` 那行追加 `lld`

- [ ] **Step 3: 验证镜像内文件就位**

```powershell
docker run --rm --entrypoint sh translate-proxy:dev -c "
ls -l /opt/scanner /etc/nginx /usr/local/bin/updater.sh /usr/local/bin/entrypoint.sh
"
```

期望：
- `/opt/scanner/GoogleTranslateIpCheck` 可执行
- `/opt/scanner/config.json` 存在
- `/etc/nginx/nginx.conf`、`/etc/nginx/upstream.conf` 存在
- 两个脚本可执行

- [ ] **Step 4: 验证镜像内 nginx 配置语法**

```powershell
docker run --rm --entrypoint nginx translate-proxy:dev -t
```

期望：`nginx: configuration file /etc/nginx/nginx.conf test is successful`

- [ ] **Step 5: 提交**

```bash
git add docker/Dockerfile
git commit -m "🤡 feat: 新增多阶段 Dockerfile (AOT 扫描器 + nginx 镜像)"
```

---

### Task 11: docker-compose.yml

**Files:**
- Create: `docker/docker-compose.yml`

- [ ] **Step 1: 写 compose 文件**

```yaml
services:
  translate-proxy:
    build:
      context: ..              # compose 文件在 docker/，build 上下文是仓库根
      dockerfile: docker/Dockerfile
    image: translate-proxy:latest
    container_name: translate-proxy
    network_mode: host
    restart: always
    environment:
      TZ: Asia/Shanghai
      # 全部可选，默认值见 spec/updater.sh
      # HEALTH_CHECK_INTERVAL: 4h
      # HEALTH_CHECK_TIMEOUT: 5
      # HEALTH_CHECK_FAIL_THRESHOLD: 2
      # SCAN_TIMEOUT: 4
      # SCAN_CONCURRENCY: 80
      # SCAN_LIMIT: 5
      # SCAN_COOLDOWN: 10m
      # HOSTS: "translate.googleapis.com,translate.google.com,translate-pa.googleapis.com"
    volumes:
      - ../data:/var/lib/translate-proxy
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
```

- [ ] **Step 2: compose 配置语法校验**

```powershell
docker compose -f docker\docker-compose.yml config | Out-Null
```

期望：无报错。如有 deprecation 警告（`version:` 被废弃等）属正常。

- [ ] **Step 3: 提交**

```bash
git add docker/docker-compose.yml
git commit -m "🤡 feat: 新增 docker-compose.yml (host 网络)"
```

---

### Task 12: README 增补部署章节

**Files:**
- Modify: `README.md`（在文件末尾追加新章节）

- [ ] **Step 1: 在 README.md 末尾追加部署说明**

把以下内容追加到 `README.md` 文件末尾：

```markdown

---

## 局域网中转部署 (Docker)

把扫描器 + nginx 透传打包成单个容器，部署在局域网 Linux 服务器（推荐 Ubuntu 虚拟机）。客户端只需一次性改 hosts 指向服务器，无需在每台机器上单独跑工具。

设计与权衡详见 [`docs/superpowers/specs/2026-06-14-translate-proxy-design.md`](docs/superpowers/specs/2026-06-14-translate-proxy-design.md)。

### 服务器前置条件

- 能直连 Google IP（这是整个方案的前提：服务器自己得能扫到可用 IP）
- 443 端口空闲：`sudo ss -lntp | grep ':443 '` 无输出
- LAN IP 静态化（路由器 DHCP 静态绑定或系统内静态配置）
- 防火墙放行入站 443，例如 `sudo ufw allow from 192.168.0.0/16 to any port 443`

### 部署

```bash
git clone <this-repo>
cd GoogleTranslateIpCheck
docker compose -f docker/docker-compose.yml up -d --build
docker logs -f translate-proxy
```

启动后看到 `[apply] new ip=...` 与 `[updater] OK current_ip=...` 即成功。

### 客户端 (Win10/11) 配置

以管理员身份编辑 `C:\Windows\System32\drivers\etc\hosts`，末尾追加（把 `192.168.x.y` 换成服务器 LAN IP）：

```
192.168.x.y translate.googleapis.com
192.168.x.y translate.google.com
192.168.x.y translate-pa.googleapis.com
```

可选：管理员 PowerShell 跑 `ipconfig /flushdns` 立即刷新。

### 可调参数

`docker/docker-compose.yml` 的 `environment` 节里全部可选，未设置时走默认：

| 变量 | 默认值 | 含义 |
|---|---|---|
| `HEALTH_CHECK_INTERVAL` | `4h` | 健康检查间隔（`s/m/h/d`） |
| `HEALTH_CHECK_TIMEOUT` | `5` | 单次 curl 超时秒 |
| `HEALTH_CHECK_FAIL_THRESHOLD` | `2` | 连续失败几次才触发扫描 |
| `SCAN_TIMEOUT` | `4` | 扫描器单 IP 超时（秒） |
| `SCAN_CONCURRENCY` | `80` | 扫描并发数 |
| `SCAN_LIMIT` | `5` | 找到几个可用 IP 后停止扫描 |
| `SCAN_COOLDOWN` | `10m` | 两次扫描的最小间隔 |
| `HOSTS` | `translate.googleapis.com,translate.google.com,translate-pa.googleapis.com` | 接管的域名 |

修改后 `docker compose up -d` 重建生效。

### 故障排查速查

| 症状 | 大概率原因 |
|---|---|
| `ping translate.googleapis.com` 仍指向 Google | hosts 未保存 / BOM / 没用管理员 |
| 浏览器 `ERR_CERT_AUTHORITY_INVALID` | 不应出现：本方案是 TLS 透传不解密 |
| 浏览器 `ERR_CONNECTION_REFUSED` | 服务器 443 未监听 / 防火墙拦截 |
| 浏览器超时 | 当前 upstream IP 失效；等下轮健康检查或 `rm data/current_ip` 后重启容器立即触发重扫 |
| 日志持续 `ERROR scanner failed` | 服务器到 Google 出网不通；先解决服务器侧出网 |
```

- [ ] **Step 2: 提交**

```bash
git add README.md
git commit -m "🤡 docs: README 增补局域网中转部署说明"
```

---

### Task 13: 服务器侧本地构建 + smoke test

> 此任务在**目标 Ubuntu 服务器**（或本地 WSL2）上执行。前 12 个任务是在 Windows 工作站完成代码与 commit，本任务起切到服务器跑实物验证。

**Files:** 无

- [ ] **Step 1: 拉代码到服务器**

```bash
# 服务器上
git clone <repo-url> ~/translate-proxy
cd ~/translate-proxy
```

- [ ] **Step 2: 验证 443 空闲**

```bash
sudo ss -lntp | grep ':443 ' || echo "443 free"
```

期望：输出 `443 free`。

- [ ] **Step 3: 构建镜像**

```bash
docker compose -f docker/docker-compose.yml build
```

期望：无报错；可看到 stage 1 AOT 编译过程。

- [ ] **Step 4: 启动容器**

```bash
docker compose -f docker/docker-compose.yml up -d
docker logs -f translate-proxy
```

期望日志关键行（按时间顺序）：

```
[entrypoint] scanner config patched: ...
... [updater] boot: HEALTH_CHECK_INTERVAL=4h ...
... [updater] bootstrap: no current_ip, performing initial scan
... [updater] === triggering rescan ===
... (.NET 扫描器输出，找到的 IP 列表)
... [updater] === applied new ip=<某 IP> (backups: ...)===
... [updater] OK current_ip=<某 IP>
```

如果初次扫描失败，updater 会进入主循环并在下个 `HEALTH_CHECK_INTERVAL` 重试。开发期可先临时把 interval 调短再观察：

```bash
docker compose -f docker/docker-compose.yml down
HEALTH_CHECK_INTERVAL=2m docker compose -f docker/docker-compose.yml up -d
```

- [ ] **Step 5: 服务器本机自测转发**

```bash
curl -sk --resolve translate.googleapis.com:443:127.0.0.1 \
  --max-time 10 \
  "https://translate.googleapis.com/translate_a/single?client=gtx&sl=zh-CN&tl=en&dt=t&q=你好" \
  | head -c 200
```

期望返回里包含 `Hello`。返回大致形如 `[[["Hello","你好",null,null,10]],null,"zh-CN"...]`。

- [ ] **Step 6: 局域网另一台机器自测（手机/Mac/另一台 Linux）**

```bash
SERVER_IP=192.168.x.y   # 换成服务器 LAN IP
curl -sk --resolve translate.googleapis.com:443:$SERVER_IP \
  --max-time 10 \
  "https://translate.googleapis.com/translate_a/single?client=gtx&sl=zh-CN&tl=en&dt=t&q=你好" \
  | head -c 200
```

期望同上含 `Hello`。失败 → 多半是 Ubuntu 防火墙没放行，跑：

```bash
sudo ufw allow from 192.168.0.0/16 to any port 443
```

---

### Task 14: Win10/11 客户端端到端验证

**Files:** 无（修改客户端 hosts）

- [ ] **Step 1: 改 hosts**

按 README 部署章节步骤改 `C:\Windows\System32\drivers\etc\hosts`，写入服务器 LAN IP 与三个 translate 域名。保存。

- [ ] **Step 2: 验证 hosts 生效**

```powershell
ping translate.googleapis.com
```

期望首行 `正在 Ping translate.googleapis.com [192.168.x.y]`，**IP 是服务器 LAN IP，不是 Google 真实 IP**。

如果不是：hosts 没保存（编辑器没用管理员）/ 有 BOM / 行尾混乱。重新用记事本管理员打开。

- [ ] **Step 3: 浏览器实测**

在 Edge / Chrome 打开 https://translate.google.com，输入"你好"，能正常翻译为 "Hello"。

- [ ] **Step 4: API 实测**

PowerShell：

```powershell
curl.exe -sk --max-time 10 `
  "https://translate.googleapis.com/translate_a/single?client=gtx&sl=zh-CN&tl=en&dt=t&q=你好"
```

期望返回 JSON 含 `Hello`。

- [ ] **Step 5: 故障切换演练（可选，建议做）**

在服务器：

```bash
docker exec translate-proxy sh -c 'echo "1.2.3.4" > /var/lib/translate-proxy/current_ip'
docker compose -f docker/docker-compose.yml down
HEALTH_CHECK_INTERVAL=2m HEALTH_CHECK_FAIL_THRESHOLD=1 SCAN_COOLDOWN=30s \
  docker compose -f docker/docker-compose.yml up -d
docker logs -f translate-proxy
```

期望几分钟内日志出现：

```
[updater] WARN health-check failed (#1) for ip=1.2.3.4
[updater] === triggering rescan ===
[updater] === applied new ip=<某真实 IP> ===
[updater] OK current_ip=<某真实 IP>
```

演练完恢复默认 env：

```bash
docker compose -f docker/docker-compose.yml down
docker compose -f docker/docker-compose.yml up -d
```

- [ ] **Step 6: 整 PR / 合并主线**

到此整个方案落地。如果在 feature 分支：

```bash
git push origin <branch>
# 在 GitHub 开 PR 合并到 master
```

如果直接 master：

```bash
git push origin master
```

---

## 遗留事项 / 不在范围

- IPv6 支持（spec 已明确不做）
- HTTP /status 与 /metrics 端口（spec 已明确不做）
- 客户端一键 hosts 安装脚本（spec 已明确不做）
- 服务器侧出网到 Google 的代理配置（前提，使用方自备）
