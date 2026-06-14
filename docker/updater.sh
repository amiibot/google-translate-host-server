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
