# GoogleTranslateIpCheck
#### 扫描国内可用的谷歌翻译IP
#### 如果都不能使用可以删除 ip.txt 文件调用远程IP或进入扫描模式
#### 使用参数 -s 可以直接进入扫描模式  -y 自动写入Host文件   -6 进入IPv6模式(如果支持IPv6推荐优先使用)
##### Windows 需要使用管理员权限运行
##### Mac和Linux运行 需要在终端中导航到软件目录然后执行
```
chmod +x GoogleTranslateIpCheck
sudo ./GoogleTranslateIpCheck
```

#### 下载地址

##### Window
##### https://github.com/Ponderfly/GoogleTranslateIpCheck/releases/download/1.8/win-x64.zip
##### https://github.com/Ponderfly/GoogleTranslateIpCheck/releases/download/1.8/win-x86.zip
##### 推荐使用 底层基于 WinDivert 的 [TurboSyn](https://github.com/spartacus-soft/TurboSyn) 进行快速扫描,需管理员运行,只支持Windows系统,使用 -t 可进入自动扫描模式
##### 🌟 https://github.com/Ponderfly/GoogleTranslateIpCheck/releases/download/1.10/win-x64.TurboSyn.zip
 
##### Mac OS
##### https://github.com/Ponderfly/GoogleTranslateIpCheck/releases/download/1.8/osx-arm64.zip
##### https://github.com/Ponderfly/GoogleTranslateIpCheck/releases/download/1.8/osx-x64.zip
 
##### Linux
##### https://github.com/Ponderfly/GoogleTranslateIpCheck/releases/download/1.8/linux-x64.zip
##### https://github.com/Ponderfly/GoogleTranslateIpCheck/releases/download/1.8/linux-arm64.zip
##### 静态链接版，适合glibc过低的老系统 https://github.com/user-attachments/files/23772336/linux-musl-x64.zip

#### 常见问题
##### 1.如果所有IP都超时,请检查是否开了代理 
##### 2.Mac 中使用: 打开终端 输入cd 把解压后的文件夹拖进终端，点击回车 复制粘贴代码，点击回车
```
chmod +x GoogleTranslateIpCheck
sudo ./GoogleTranslateIpCheck
```
##### 3.Mac 提示来自不明身份: 系统偏好设置－－>安全性与隐私--->选择允许


#### 扫描逻辑参考 https://repo.or.cz/gscan_quic.git 项目,感谢大佬


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
