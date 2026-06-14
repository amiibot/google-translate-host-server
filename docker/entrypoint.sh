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

# busybox sh 不支持 wait -n，改用 kill -0 轮询任一子进程退出。
# trap 负责把容器收到的 SIGTERM/SIGINT 转给两个子进程，确保 docker stop 可优雅退出。
EXIT=0
shutdown() {
    kill -TERM "$NGINX_PID" "$UPDATER_PID" 2>/dev/null || true
}
trap shutdown TERM INT

while kill -0 "$NGINX_PID" 2>/dev/null && kill -0 "$UPDATER_PID" 2>/dev/null; do
    sleep 2
done

# 判断谁先死，把它的退出码作为容器退出码
if ! kill -0 "$NGINX_PID" 2>/dev/null; then
    wait "$NGINX_PID" 2>/dev/null
    EXIT=$?
    echo "[entrypoint] nginx exited with $EXIT, shutting down updater"
else
    wait "$UPDATER_PID" 2>/dev/null
    EXIT=$?
    echo "[entrypoint] updater exited with $EXIT, shutting down nginx"
fi

kill -TERM "$NGINX_PID" "$UPDATER_PID" 2>/dev/null || true
wait 2>/dev/null || true
exit "$EXIT"
