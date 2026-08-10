# VPS 自动化脚本集合（Automation Script Library）

> 面向个人开发者与小团队的 **VPS 自动化运维脚本库**：从初始化、部署、备份到告警，全部用可读、可审计、可复用的 Shell 脚本完成。
> 本仓库的定位不是"工具箱陈列"，而是 **一套可以直接抄进生产环境的脚本工程规范**。

![Shell](https://img.shields.io/badge/Shell-Bash%204.4%2B-121011?logo=gnu-bash&logoColor=white)
![Platform](https://img.shields.io/badge/Platform-Debian%20%7C%20Ubuntu%20%7C%20CentOS%20%7C%20Rocky-blue)
![License](https://img.shields.io/badge/License-MIT-green)

---

## 目录

- [一、这个仓库解决什么问题](#一这个仓库解决什么问题)
- [二、脚本工程规范（先读这一节）](#二脚本工程规范先读这一节)
- [三、脚本索引与参数手册](#三脚本索引与参数手册)
- [四、系统管理类脚本](#四系统管理类脚本)
- [五、部署类脚本](#五部署类脚本)
- [六、备份与恢复脚本](#六备份与恢复脚本)
- [七、安全加固脚本](#七安全加固脚本)
- [八、监控与告警脚本](#八监控与告警脚本)
- [九、定时任务（cron / systemd timer）集成](#九定时任务cron--systemd-timer集成)
- [十、日志、退出码与错误处理约定](#十日志退出码与错误处理约定)
- [十一、幂等性与灰度执行](#十一幂等性与灰度执行)
- [十二、批量执行：多台机器怎么跑](#十二批量执行多台机器怎么跑)
- [十三、测试与 CI](#十三测试与-ci)
- [十四、常见故障排查](#十四常见故障排查)
- [十五、脚本运行环境推荐](#十五脚本运行环境推荐)
- [十六、FAQ](#十六faq)
- [十七、相关项目与资源](#十七相关项目与资源)

---

## 一、这个仓库解决什么问题

大部分人的 VPS 运维现状是这样的：

| 场景 | 常见做法 | 问题 |
|------|----------|------|
| 新机初始化 | 手敲十几条命令 | 每台机器状态不一致，无法复现 |
| 部署服务 | 复制别人的一键脚本 | 不知道改了什么，出问题无从排查 |
| 数据库备份 | 写个 `mysqldump` 塞进 crontab | 从没验证过能不能恢复 |
| 安全加固 | 改了 SSH 端口就算完事 | 缺少 fail2ban / 内核参数 / 审计 |
| 出问题 | SSH 上去 `top` 一下 | 没有历史数据，只能靠猜 |

本仓库的做法：**把每一件重复的事情变成一个带参数、带日志、带退出码、可重复执行的脚本**。

三条硬性原则：

1. **幂等（Idempotent）** —— 同一个脚本跑 10 次，结果和跑 1 次一样。
2. **可审计（Auditable）** —— 任何修改系统的动作都要落日志，并且能回滚。
3. **零交互（Non-interactive）** —— 所有脚本都能在 cron / CI 里无人值守跑完。

---

## 二、脚本工程规范（先读这一节）

### 2.1 每个脚本的标准头部

```bash
#!/usr/bin/env bash
#
# Script:      docker-manager.sh
# Description: Docker 容器生命周期管理
# Author:      clashforwindows-net
# Version:     2.1.0
# Requires:    bash>=4.4, docker>=20.10
# Exit codes:  0=success 1=generic 2=usage 3=dependency 4=permission
#
set -Eeuo pipefail
IFS=$'\n\t'
```

`set -Eeuo pipefail` 四个开关缺一不可：

| 开关 | 作用 | 不加会怎样 |
|------|------|-----------|
| `-e` | 命令失败立即退出 | 脚本"带病继续跑"，后面的命令在错误状态上执行 |
| `-u` | 引用未定义变量报错 | `rm -rf "$DIR/"` 在 `DIR` 为空时删掉根目录 |
| `-o pipefail` | 管道中任一环节失败即失败 | `cmd_a \| cmd_b` 中 `cmd_a` 挂了却返回 0 |
| `-E` | ERR trap 在函数内也生效 | 函数里的错误捕获不到 |

### 2.2 通用函数库 `lib/common.sh`

```bash
#!/usr/bin/env bash
# 所有脚本 source 这个文件，避免重复造轮子

readonly LOG_DIR="${LOG_DIR:-/var/log/vps-scripts}"
readonly LOG_FILE="${LOG_FILE:-$LOG_DIR/$(basename "${0%.sh}").log}"

_ts()  { date '+%Y-%m-%d %H:%M:%S'; }
log()  { printf '[%s] [INFO]  %s\n'  "$(_ts)" "$*" | tee -a "$LOG_FILE"; }
warn() { printf '[%s] [WARN]  %s\n'  "$(_ts)" "$*" | tee -a "$LOG_FILE" >&2; }
err()  { printf '[%s] [ERROR] %s\n'  "$(_ts)" "$*" | tee -a "$LOG_FILE" >&2; }
die()  { err "$*"; exit "${2:-1}"; }

require_root() {
  [[ $EUID -eq 0 ]] || die "需要 root 权限，请使用 sudo 执行" 4
}

require_cmd() {
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "缺少依赖命令: $c" 3
  done
}

confirm() {
  [[ "${ASSUME_YES:-0}" == "1" ]] && return 0
  read -rp "$1 [y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]]
}

# 备份文件后再修改，保证可回滚
backup_file() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  local bak="${f}.bak.$(date +%Y%m%d%H%M%S)"
  cp -a "$f" "$bak" && log "已备份 $f -> $bak"
}

# 全局错误捕获，打印出错行号
trap 'err "脚本在第 $LINENO 行异常退出 (exit=$?)"' ERR
```

### 2.3 目录结构约定

```
vps-scripts/
├── lib/
│   └── common.sh            # 通用函数库
├── scripts/
│   ├── init/                # 初始化
│   │   ├── system-init.sh
│   │   └── swap-setup.sh
│   ├── deploy/              # 部署
│   │   ├── docker-install.sh
│   │   ├── nginx-deploy.sh
│   │   └── certbot-auto.sh
│   ├── ops/                 # 日常运维
│   │   ├── docker-manager.sh
│   │   ├── disk-cleanup.sh
│   │   └── log-rotate.sh
│   ├── backup/              # 备份恢复
│   │   ├── mysql-backup.sh
│   │   ├── mysql-restore.sh
│   │   └── rclone-sync.sh
│   ├── security/            # 安全
│   │   ├── ssh-hardening.sh
│   │   ├── fail2ban-setup.sh
│   │   └── audit-check.sh
│   └── monitor/             # 监控
│       ├── health-check.sh
│       └── alert-notify.sh
├── conf/
│   └── vps-scripts.env      # 集中配置
└── tests/
    └── bats/                # bats-core 测试用例
```

### 2.4 集中配置 `conf/vps-scripts.env`

```bash
# 所有脚本读取同一个配置文件，避免参数散落各处
LOG_DIR=/var/log/vps-scripts
BACKUP_DIR=/data/backup
BACKUP_KEEP_DAYS=14

MYSQL_HOST=127.0.0.1
MYSQL_USER=backup
MYSQL_PASS_FILE=/root/.my.cnf     # 密码写文件，不写变量

RCLONE_REMOTE=r2:vps-backup
ALERT_WEBHOOK=""                   # 留空则只写日志不推送
ALERT_MIN_INTERVAL=1800            # 同类告警最小间隔（秒），防轰炸
```

---

## 三、脚本索引与参数手册

| 脚本 | 类别 | 主要参数 | 幂等 | 需要 root |
|------|------|----------|:----:|:--------:|
| `system-init.sh` | 初始化 | `--hostname --timezone --no-swap` | ✅ | ✅ |
| `swap-setup.sh` | 初始化 | `--size 2G --swappiness 10` | ✅ | ✅ |
| `docker-install.sh` | 部署 | `--mirror aliyun --compose-v2` | ✅ | ✅ |
| `docker-manager.sh` | 运维 | `start\|stop\|restart\|status\|logs\|clean` | ✅ | ⭕ |
| `nginx-deploy.sh` | 部署 | `--domain --upstream --ssl` | ✅ | ✅ |
| `certbot-auto.sh` | 部署 | `--domain --email --dns-api` | ✅ | ✅ |
| `disk-cleanup.sh` | 运维 | `--dry-run --keep-days 7` | ✅ | ✅ |
| `mysql-backup.sh` | 备份 | `--db --all --compress --upload` | ✅ | ⭕ |
| `mysql-restore.sh` | 备份 | `--file --db --force` | ❌ | ⭕ |
| `rclone-sync.sh` | 备份 | `--src --remote --bwlimit` | ✅ | ⭕ |
| `ssh-hardening.sh` | 安全 | `--port --no-root --key-only` | ✅ | ✅ |
| `fail2ban-setup.sh` | 安全 | `--bantime --maxretry` | ✅ | ✅ |
| `audit-check.sh` | 安全 | `--report json\|text` | ✅ | ✅ |
| `health-check.sh` | 监控 | `--cpu 85 --mem 90 --disk 85` | ✅ | ⭕ |
| `alert-notify.sh` | 监控 | `--level --title --body` | ✅ | ⭕ |

所有脚本统一支持：

```
-h, --help        显示帮助
-v, --verbose     输出调试日志（等价 set -x）
-y, --yes         跳过所有交互确认（cron 场景必备）
    --dry-run     只打印将要执行的动作，不真正执行
    --version     打印版本号
```

---

## 四、系统管理类脚本

### 4.1 `system-init.sh` —— 新机 5 分钟标准化

```bash
sudo ./scripts/init/system-init.sh \
  --hostname web-hk-01 \
  --timezone Asia/Shanghai \
  --yes
```

它做的事情（每一步都幂等）：

1. 设置主机名与 `/etc/hosts` 对应关系
2. 设置时区并启用 `systemd-timesyncd` 校时
3. 更换软件源镜像（自动识别 Debian/Ubuntu/CentOS/Rocky）
4. 安装基础工具集：`curl wget vim git htop iftop iotop unzip jq net-tools dnsutils`
5. 配置 `ulimit`（`nofile 65535`）与 `sysctl` 网络参数
6. 创建非 root 运维账户并写入公钥
7. 启用自动安全更新（`unattended-upgrades` / `dnf-automatic`）

关键的 `sysctl` 片段：

```bash
cat > /etc/sysctl.d/99-vps-tuning.conf <<'EOF'
# 文件句柄与连接数
fs.file-max = 1000000
net.core.somaxconn = 32768
net.ipv4.tcp_max_syn_backlog = 8192

# TIME_WAIT 复用（不要开 tcp_tw_recycle，NAT 环境会出问题）
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15

# 缓冲区
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216

# 拥塞控制
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# 转发（做代理/网关时需要）
net.ipv4.ip_forward = 1
EOF
sysctl --system
```

### 4.2 `docker-manager.sh` —— 容器生命周期

```bash
# 查看所有容器状态（带健康检查、重启次数、占用资源）
./scripts/ops/docker-manager.sh status

# 重启指定容器并等待健康
./scripts/ops/docker-manager.sh restart nginx --wait-healthy 60

# 拉取最新镜像并滚动更新（保留旧镜像用于回滚）
./scripts/ops/docker-manager.sh update nginx --keep-old

# 一键清理（悬空镜像 + 停止容器 + 未使用卷 + 构建缓存）
./scripts/ops/docker-manager.sh clean --dry-run
```

`status` 子命令核心实现：

```bash
docker ps -a --format '{{.Names}}\t{{.Status}}\t{{.Image}}' | \
while IFS=$'\t' read -r name status image; do
  health=$(docker inspect --format \
    '{{if .State.Health}}{{.State.Health.Status}}{{else}}-{{end}}' "$name")
  restarts=$(docker inspect --format '{{.RestartCount}}' "$name")
  printf '%-22s %-24s %-8s restarts=%s\n' "$name" "$status" "$health" "$restarts"
done
```

### 4.3 `disk-cleanup.sh` —— 磁盘告急时的第一反应

```bash
sudo ./scripts/ops/disk-cleanup.sh --dry-run --keep-days 7
```

清理顺序（从最安全到最激进，逐级执行并实时输出释放量）：

1. 包管理器缓存：`apt clean` / `dnf clean all`
2. journald 日志压缩：`journalctl --vacuum-size=200M`
3. 轮转日志中 `.gz`、`.1` 超过 N 天的文件
4. `/tmp`、`/var/tmp` 中 7 天未访问文件
5. Docker：`docker system prune -af --volumes`（**需显式加 `--aggressive`**）
6. 输出 Top 20 大文件供人工判断

```bash
# 找出真正的空间黑洞
du -x -h --max-depth=3 / 2>/dev/null | sort -rh | head -30
# 找出已删除但句柄未释放的文件（磁盘满但 du 看不到时用这个）
lsof -nP +L1 | awk '$5=="REG" && $7>1e8'
```

---

## 五、部署类脚本

### 5.1 `nginx-deploy.sh` —— 反向代理一步到位

```bash
sudo ./scripts/deploy/nginx-deploy.sh \
  --domain api.example.com \
  --upstream 127.0.0.1:8080 \
  --ssl --email admin@example.com
```

生成的配置模板（含常见安全头与 gzip）：

```nginx
server {
    listen 80;
    server_name api.example.com;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl http2;
    server_name api.example.com;

    ssl_certificate     /etc/letsencrypt/live/api.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/api.example.com/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256;
    ssl_session_cache   shared:SSL:10m;

    add_header Strict-Transport-Security "max-age=31536000" always;
    add_header X-Content-Type-Options nosniff always;
    add_header X-Frame-Options SAMEORIGIN always;

    gzip on;
    gzip_types text/plain text/css application/json application/javascript;
    gzip_min_length 1024;

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_http_version 1.1;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Upgrade           $http_upgrade;
        proxy_set_header Connection        "upgrade";
        proxy_read_timeout 300s;
    }
}
```

部署后脚本会自动执行 `nginx -t`，**校验失败则回滚到备份配置**，绝不留下一个起不来的 nginx。

### 5.2 `certbot-auto.sh` —— 证书申请与自动续期

```bash
# HTTP-01 验证
sudo ./scripts/deploy/certbot-auto.sh --domain example.com --email me@example.com

# DNS-01 验证（泛域名证书必须用这个）
sudo ./scripts/deploy/certbot-auto.sh \
  --domain '*.example.com' --dns-api cloudflare --email me@example.com
```

续期钩子写进 systemd timer，而不是裸 crontab：

```ini
# /etc/systemd/system/certbot-renew.timer
[Unit]
Description=Certbot renewal twice a day

[Timer]
OnCalendar=*-*-* 03,15:17:00
RandomizedDelaySec=1800
Persistent=true

[Install]
WantedBy=timers.target
```

---

## 六、备份与恢复脚本

> **没有验证过恢复的备份，等于没有备份。** 这是本仓库反复强调的一点。

### 6.1 `mysql-backup.sh`

```bash
# 备份全部数据库，压缩并上传到对象存储
./scripts/backup/mysql-backup.sh --all --compress --upload

# 只备份单库并保留 30 天
./scripts/backup/mysql-backup.sh --db myapp --keep-days 30
```

核心逻辑：

```bash
backup_one() {
  local db="$1"
  local ts; ts=$(date +%Y%m%d_%H%M%S)
  local out="$BACKUP_DIR/${db}_${ts}.sql.gz"

  mysqldump --defaults-file="$MYSQL_PASS_FILE" \
    --single-transaction \
    --quick \
    --routines --triggers --events \
    --set-gtid-purged=OFF \
    --default-character-set=utf8mb4 \
    "$db" | gzip -6 > "$out"

  # 校验完整性：gzip 尾部 CRC + 文件尺寸下限
  gzip -t "$out" || die "备份文件损坏: $out"
  local size; size=$(stat -c%s "$out")
  (( size > 1024 )) || die "备份文件异常过小 (${size}B): $out"

  sha256sum "$out" > "${out}.sha256"
  log "备份完成 $db -> $out ($(numfmt --to=iec "$size"))"
}
```

要点说明：

- `--single-transaction`：InnoDB 表在线一致性备份，**不锁表**
- `--quick`：逐行取数据，避免大表把内存吃爆
- `--set-gtid-purged=OFF`：避免恢复到从库时 GTID 冲突
- `.sha256` 校验文件：上传后可在远端验证是否损坏

### 6.2 恢复演练（每月必做）

```bash
# 在临时库上做恢复演练，不碰生产库
./scripts/backup/mysql-restore.sh \
  --file /data/backup/myapp_20260810_030000.sql.gz \
  --db myapp_drill --create-db

# 校验行数是否与生产一致
mysql -e "SELECT table_name, table_rows FROM information_schema.tables
          WHERE table_schema='myapp_drill' ORDER BY table_rows DESC LIMIT 10;"
```

### 6.3 3-2-1 备份策略落地

| 层级 | 位置 | 保留期 | 脚本 |
|------|------|--------|------|
| 本地 | `/data/backup` | 7 天 | `mysql-backup.sh` |
| 异地对象存储 | R2 / S3 / B2 | 30 天 | `rclone-sync.sh` |
| 冷归档 | 归档存储层 | 365 天 | `rclone-sync.sh --archive` |

```bash
./scripts/backup/rclone-sync.sh \
  --src /data/backup \
  --remote r2:vps-backup/$(hostname) \
  --bwlimit 10M \
  --transfers 4
```

`--bwlimit` 很重要：小带宽 VPS 上传备份时不限速，会把线上业务的带宽全部挤掉。

---

## 七、安全加固脚本

### 7.1 `ssh-hardening.sh`

```bash
sudo ./scripts/security/ssh-hardening.sh --port 22022 --key-only --no-root
```

修改前自动 `backup_file /etc/ssh/sshd_config`，修改后执行 `sshd -t` 校验，**并保持当前会话不断开**（改完不立刻 restart，而是先起一个新端口监听让你验证）。

```
Port 22022
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
ChallengeResponseAuthentication no
MaxAuthTries 3
LoginGraceTime 30
ClientAliveInterval 300
ClientAliveCountMax 2
AllowUsers ops
Protocol 2
X11Forwarding no
```

> ⚠️ **执行前务必先确认你的公钥已经写进 `~/.ssh/authorized_keys`**，否则改完 `PasswordAuthentication no` 就把自己锁在门外了。脚本会主动检查这一点，检查不通过直接拒绝执行。

### 7.2 `fail2ban-setup.sh`

```bash
sudo ./scripts/security/fail2ban-setup.sh --bantime 86400 --maxretry 3
```

```ini
[sshd]
enabled  = true
port     = 22022
filter   = sshd
logpath  = /var/log/auth.log
maxretry = 3
findtime = 600
bantime  = 86400
ignoreip = 127.0.0.1/8 10.0.0.0/8
```

```bash
# 查看当前封禁情况
fail2ban-client status sshd
# 手动解封
fail2ban-client set sshd unbanip 1.2.3.4
```

### 7.3 `audit-check.sh` —— 一键安全体检

```bash
sudo ./scripts/security/audit-check.sh --report text
```

检查项（共 32 条，输出 PASS/WARN/FAIL 与修复建议）：

- root 是否可密码登录、是否存在空密码账户
- `/etc/passwd` 中 UID=0 的非 root 账户
- SUID/SGID 异常文件清单
- 监听端口与对应进程（对比白名单）
- 最近 7 天登录失败 Top IP
- 内核版本与已知 CVE 提示
- 防火墙规则是否放行了不该放行的端口
- crontab 中是否存在可疑外部下载执行

---

## 八、监控与告警脚本

### 8.1 `health-check.sh`

```bash
./scripts/monitor/health-check.sh --cpu 85 --mem 90 --disk 85 --load 4
```

```bash
check_disk() {
  df -P -x tmpfs -x devtmpfs | awk -v th="$DISK_TH" 'NR>1 {
    gsub("%","",$5);
    if ($5+0 >= th) printf "DISK %s used %s%% (mount %s)\n", $1, $5, $6
  }'
}

check_mem() {
  local used
  used=$(free | awk '/^Mem:/ {printf "%d", ($2-$7)/$2*100}')
  (( used >= MEM_TH )) && echo "MEM used ${used}%"
}

check_load() {
  local l1 cores
  l1=$(awk '{print $1}' /proc/loadavg)
  cores=$(nproc)
  awk -v l="$l1" -v c="$cores" -v t="$LOAD_TH" \
    'BEGIN { if (l/c >= t) printf "LOAD %.2f (per-core %.2f)\n", l, l/c }'
}
```

### 8.2 `alert-notify.sh` —— 统一告警出口

```bash
./scripts/monitor/alert-notify.sh \
  --level critical \
  --title "磁盘告警 web-hk-01" \
  --body "/ 使用率 92%"
```

带**去重与冷却**，避免同一条告警一分钟刷 60 遍：

```bash
send_alert() {
  local key; key=$(printf '%s' "$1$2" | md5sum | cut -c1-16)
  local stamp="/tmp/.alert_$key"
  if [[ -f "$stamp" ]]; then
    local age=$(( $(date +%s) - $(stat -c %Y "$stamp") ))
    (( age < ALERT_MIN_INTERVAL )) && { log "告警冷却中($age s)，跳过"; return 0; }
  fi
  curl -fsS -m 10 -X POST "$ALERT_WEBHOOK" \
    -H 'Content-Type: application/json' \
    -d "$(jq -n --arg t "$1" --arg b "$2" '{title:$t, body:$b}')" \
    && touch "$stamp"
}
```

---

## 九、定时任务（cron / systemd timer）集成

### 9.1 推荐的 crontab 布局

```cron
# /etc/cron.d/vps-scripts
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
MAILTO=""

# 每 5 分钟健康检查
*/5  *  *  *  * root /opt/vps-scripts/scripts/monitor/health-check.sh -y >>/var/log/vps-scripts/cron.log 2>&1

# 每天 03:10 数据库备份
10   3  *  *  * root /opt/vps-scripts/scripts/backup/mysql-backup.sh --all --compress --upload -y >>/var/log/vps-scripts/cron.log 2>&1

# 每天 04:00 磁盘清理
0    4  *  *  * root /opt/vps-scripts/scripts/ops/disk-cleanup.sh --keep-days 7 -y >>/var/log/vps-scripts/cron.log 2>&1

# 每周日 05:00 安全体检
0    5  *  *  0 root /opt/vps-scripts/scripts/security/audit-check.sh --report text -y >>/var/log/vps-scripts/audit.log 2>&1
```

### 9.2 cron 三大踩坑点

| 坑 | 现象 | 解决 |
|----|------|------|
| PATH 不同 | 手动能跑，cron 里 `command not found` | 在 crontab 顶部显式声明 `PATH` |
| 无 TTY | 脚本卡在交互确认处永不结束 | 所有脚本支持 `-y` / `ASSUME_YES=1` |
| 并发重入 | 上一次没跑完下一次又启动 | 用 `flock` 加互斥锁 |

```bash
# 用 flock 保证同一脚本不会并发执行
exec 200>"/var/lock/$(basename "$0").lock"
flock -n 200 || { echo "另一实例正在运行，退出"; exit 0; }
```

### 9.3 更推荐：systemd timer

```ini
# /etc/systemd/system/mysql-backup.service
[Unit]
Description=MySQL backup
After=network-online.target

[Service]
Type=oneshot
EnvironmentFile=/opt/vps-scripts/conf/vps-scripts.env
ExecStart=/opt/vps-scripts/scripts/backup/mysql-backup.sh --all --compress --upload -y
```

```ini
# /etc/systemd/system/mysql-backup.timer
[Timer]
OnCalendar=*-*-* 03:10:00
RandomizedDelaySec=300
Persistent=true

[Install]
WantedBy=timers.target
```

比 cron 强在：机器关机错过的任务开机会补跑（`Persistent=true`）、日志自动进 journald、可以 `systemctl status` 直接看上次执行结果。

```bash
systemctl enable --now mysql-backup.timer
systemctl list-timers --all | grep mysql
journalctl -u mysql-backup.service -n 50 --no-pager
```

---

## 十、日志、退出码与错误处理约定

### 10.1 统一退出码

| 退出码 | 含义 | 监控侧处理 |
|:------:|------|-----------|
| 0 | 成功 | 无 |
| 1 | 一般错误 | 记录，累计 3 次告警 |
| 2 | 参数错误 | 立即告警（说明调用方写错了） |
| 3 | 依赖缺失 | 立即告警 |
| 4 | 权限不足 | 立即告警 |
| 5 | 外部服务不可达 | 重试 3 次后告警 |
| 130 | 用户中断 | 忽略 |

### 10.2 日志轮转

```
# /etc/logrotate.d/vps-scripts
/var/log/vps-scripts/*.log {
    daily
    rotate 14
    compress
    delaycompress
    missingok
    notifempty
    create 0640 root adm
    sharedscripts
}
```

---

## 十一、幂等性与灰度执行

幂等的三个实现套路：

**1）先判断状态再动手**

```bash
# ❌ 每次都追加，跑 5 次就有 5 行
echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf

# ✅ 存在就替换，不存在才追加
grep -q '^net.ipv4.ip_forward' /etc/sysctl.conf \
  && sed -i 's/^net.ipv4.ip_forward.*/net.ipv4.ip_forward=1/' /etc/sysctl.conf \
  || echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
```

**2）用标记块包裹托管内容**

```bash
MARK_BEGIN="# >>> vps-scripts managed >>>"
MARK_END="# <<< vps-scripts managed <<<"
sed -i "/$MARK_BEGIN/,/$MARK_END/d" "$CONF"
{ echo "$MARK_BEGIN"; cat "$TMP_BLOCK"; echo "$MARK_END"; } >> "$CONF"
```

**3）`--dry-run` 默认友好**

任何会写磁盘、改配置、删数据的脚本，都必须先支持 `--dry-run` 打印计划。新脚本上线的标准流程：

```
--dry-run 看一遍  →  单台机器实跑  →  观察 24h  →  灰度 10%  →  全量
```

---

## 十二、批量执行：多台机器怎么跑

### 12.1 轻量方案：`ssh` + `xargs -P`

```bash
# hosts.txt 每行一个 host
xargs -a hosts.txt -P 8 -I{} \
  ssh -o BatchMode=yes -o ConnectTimeout=8 ops@{} \
  'sudo /opt/vps-scripts/scripts/monitor/health-check.sh -y' \
  2>&1 | tee batch-health.log
```

### 12.2 同步脚本到所有机器

```bash
while read -r h; do
  rsync -az --delete \
    --exclude '.git' \
    /opt/vps-scripts/ "ops@$h:/opt/vps-scripts/" &
done < hosts.txt
wait
```

### 12.3 结果聚合

```bash
grep -H 'FAIL\|ERROR' batch-health.log | awk -F: '{print $1}' | sort | uniq -c | sort -rn
```

---

## 十三、测试与 CI

### 13.1 静态检查：ShellCheck

```bash
shellcheck -S warning -x scripts/**/*.sh lib/*.sh
```

**任何 PR 必须 ShellCheck 零 warning 才允许合并。**

### 13.2 单元测试：bats-core

```bash
# tests/bats/common.bats
setup() { load '../../lib/common.sh'; }

@test "require_cmd 在命令缺失时返回 3" {
  run require_cmd definitely_not_a_command
  [ "$status" -eq 3 ]
}

@test "backup_file 会创建备份副本" {
  tmp=$(mktemp); echo hello > "$tmp"
  run backup_file "$tmp"
  [ "$status" -eq 0 ]
  ls "${tmp}".bak.* >/dev/null
}
```

### 13.3 GitHub Actions

```yaml
name: shell-ci
on: [push, pull_request]
jobs:
  lint-and-test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: ShellCheck
        run: |
          sudo apt-get update && sudo apt-get install -y shellcheck
          shellcheck -S warning -x $(find . -name '*.sh')
      - name: bats
        run: |
          sudo apt-get install -y bats
          bats tests/bats
```

---

## 十四、常见故障排查

| 现象 | 排查命令 | 常见原因 |
|------|----------|----------|
| 脚本 cron 里不执行 | `grep CRON /var/log/syslog` | PATH / 权限 / 文件无执行位 |
| `Permission denied` | `ls -l script.sh` | 缺 `chmod +x` |
| `bad interpreter: ^M` | `file script.sh` | Windows CRLF 换行，用 `dos2unix` |
| 备份文件是 0 字节 | `journalctl -u mysql-backup` | 凭据错误 / 磁盘满 |
| Docker 命令要 sudo | `groups $USER` | 用户不在 `docker` 组 |
| 磁盘满但 `du` 看不到 | `lsof -nP +L1` | 已删除文件句柄未释放 |
| 脚本卡住不返回 | `ps -ef \| grep script` | 等待交互输入，加 `-y` |
| SSH 改端口后连不上 | 云厂商安全组 | 防火墙/安全组未放行新端口 |

**CRLF 问题一次性解决：**

```bash
find . -name '*.sh' -exec sed -i 's/\r$//' {} +
# 或者在仓库根加 .gitattributes
echo '*.sh text eol=lf' >> .gitattributes
```

---

## 十五、脚本运行环境推荐

这些脚本对硬件要求很低，但对 **网络质量和磁盘 IO** 比较敏感（尤其是备份上传和 Docker 拉镜像）。选机时建议关注：

- **磁盘类型**：NVMe SSD 优先，备份压缩是 IO 密集操作
- **出口带宽**：异地备份上传需要稳定的上行带宽
- **快照功能**：能一键快照的服务商，回滚成本低很多
- **IP 纯净度**：拉取镜像仓库、证书签发都依赖正常出网

选购参考与实测数据：

- 🖥️ **VPS 评测与推荐**：[https://vpsvip.net](https://vpsvip.net)
- 🚀 **网络加速方案**：[ClashVIP](https://clashvip.net)
- 🧭 **工具与资源导航**：[nav.clashvip.net](https://nav.clashvip.net)

---

## 十六、FAQ

**Q1：这些脚本能在 CentOS 7 上跑吗？**
可以，但 CentOS 7 自带 Bash 4.2，部分关联数组语法需要降级。建议使用 Rocky Linux 9 / Debian 12 / Ubuntu 22.04+。

**Q2：为什么密码要写在 `.my.cnf` 而不是环境变量？**
环境变量会出现在 `ps -ef` 和 `/proc/<pid>/environ` 里，同机任意用户可读。`.my.cnf` 配 `chmod 600` 更安全。

**Q3：`docker system prune -af --volumes` 会删掉我的数据吗？**
会删掉**未被任何容器引用**的卷。如果你的数据卷当时没有挂载在运行中的容器上，就会被删。所以本仓库把它放在 `--aggressive` 开关后面，默认不执行。

**Q4：健康检查脚本能不能对接 Prometheus？**
可以。用 node_exporter 的 textfile collector，把 `health-check.sh` 的输出写成 `.prom` 文件即可。详见 [server-monitoring](https://github.com/clashforwindows-net/server-monitoring)。

**Q5：脚本改坏了配置怎么回滚？**
所有修改配置的脚本都会调用 `backup_file`，备份在同目录下 `xxx.bak.YYYYmmddHHMMSS`。直接 `cp -a` 覆盖回去再重启服务即可。

**Q6：为什么强调 `--single-transaction` 而不用 `--lock-all-tables`？**
后者会锁全库，业务直接不可写。前者利用 InnoDB MVCC 拿一致性快照，对线上无影响。但注意：MyISAM 表不支持，需要单独处理。

**Q7：告警接哪里比较好？**
Webhook 通用即可（企业微信/飞书/Telegram/Discord 都支持）。关键是配好 `ALERT_MIN_INTERVAL` 去重，否则半夜磁盘满会给你发几百条。

**Q8：如何贡献新脚本？**
Fork → 按第二节规范写脚本 → 补一个 bats 用例 → ShellCheck 通过 → 提 PR，并在 README 的脚本索引表里加一行。

---

## 十七、相关项目与资源

### 本组织其他仓库

| 仓库 | 说明 |
|------|------|
| [vps-tools](https://github.com/clashforwindows-net/vps-tools) | VPS 运维工具集（诊断/监控/分析） |
| [server-monitoring](https://github.com/clashforwindows-net/server-monitoring) | Prometheus + Grafana 完整监控方案 |
| [vps-security-20260327](https://github.com/clashforwindows-net/vps-security-20260327) | VPS 安全加固完全手册 |
| [vps-bench-20260327](https://github.com/clashforwindows-net/vps-bench-20260327) | VPS 性能测试与评分体系 |
| [linux-server-20260402](https://github.com/clashforwindows-net/linux-server-20260402) | Linux 服务器运维实战手册 |

### 快速使用

```bash
git clone https://github.com/clashforwindows-net/vps-scripts.git /opt/vps-scripts
cd /opt/vps-scripts
find . -name '*.sh' -exec chmod +x {} +
cp conf/vps-scripts.env.example conf/vps-scripts.env
sudo ./scripts/init/system-init.sh --hostname "$(hostname)" -y
```

### 关键词

`VPS自动化` `Shell脚本` `Bash最佳实践` `运维自动化` `MySQL备份` `Docker管理` `SSH加固` `fail2ban` `systemd timer` `crontab` `ShellCheck` `幂等脚本` `服务器初始化` `磁盘清理` `日志轮转` `批量运维`

---

## 免责声明

本仓库脚本会修改系统配置。请务必：

1. 先在测试机执行，确认无误后再上生产
2. 执行前做好快照或配置备份
3. 仔细阅读 `--help` 输出与本文档的参数说明
4. 遵守所在地区的法律法规与服务商条款

---

## 赞助与支持

- 💡 **VPS 评测与选购**：[vpsvip.net](https://vpsvip.net)
- 🌐 **网络工具导航**：[nav.clashvip.net](https://nav.clashvip.net)
- ⭐ 觉得有用请点个 Star，这是持续维护的最大动力

**License**: MIT

---

*最后更新: 2026-08-10 | 维护者: clashforwindows-net | 赞助商: [vpsvip.net](https://vpsvip.net)*
