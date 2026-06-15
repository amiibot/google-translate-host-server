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