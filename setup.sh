#!/usr/bin/env bash
set -euo pipefail

# 必须以 root 运行
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "Please run as root"
  exit 1
fi

# APT 非交互，避免卡住
export DEBIAN_FRONTEND=noninteractive

# 记录发起脚本的用户（用于 docker 组）
TARGET_USER="${SUDO_USER:-$USER}"

# 1. 基础更新
apt-get update
apt-get -y -o Dpkg::Options::="--force-confnew" upgrade
apt-get -y autoremove

# 2. 基础工具
apt-get -y install curl wget git vim tmux htop net-tools dnsutils ufw fail2ban \
  unattended-upgrades netdata ca-certificates gnupg lsb-release

# 3. 防火墙
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp          # SSH
ufw allow 80/tcp          # HTTP
ufw allow 443/tcp         # HTTPS (TCP)
ufw allow 443/udp         # HTTPS/QUIC (UDP)
ufw --force enable

# 4. SSH Harden
sed -i -e 's/^#*PermitRootLogin.*/PermitRootLogin no/' \
       -e 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' \
       -e 's/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/' \
       /etc/ssh/sshd_config
# 重启前先校验配置，避免锁死
if command -v sshd >/dev/null 2>&1; then
  sshd -t
fi
(systemctl restart ssh || systemctl restart sshd)

# 5. Fail2Ban (sshd 规则)
install -d -m 0755 /etc/fail2ban/jail.d
cat > /etc/fail2ban/jail.d/sshd.local <<'EOF'
[sshd]
enabled = true
port    = ssh
logpath = %(sshd_log)s
backend = systemd
maxretry = 5
findtime = 10m
bantime  = 1h
EOF
systemctl enable --now fail2ban

# 6. Sysctl 调优（分文件）
cat > /etc/sysctl.d/99-tuning.conf <<'EOF'
vm.swappiness=10
net.core.somaxconn=1024
net.ipv4.ip_local_port_range=1024 65535
EOF
sysctl --system

# 7. 文件句柄限制（同时覆盖 systemd）
cat > /etc/security/limits.d/99-nofile.conf <<'EOF'
* soft nofile 65535
* hard nofile 65535
EOF
# 配置 systemd 默认 NOFILE 限制
if grep -q '^[# ]*DefaultLimitNOFILE=' /etc/systemd/system.conf; then
  sed -i 's/^[# ]*DefaultLimitNOFILE=.*/DefaultLimitNOFILE=65535:65535/' /etc/systemd/system.conf
else
  echo 'DefaultLimitNOFILE=65535:65535' >> /etc/systemd/system.conf
fi
systemctl daemon-reexec

# 8. Docker CE
install -m 0755 -d /etc/apt/keyrings
if [ ! -f /etc/apt/keyrings/docker.gpg ]; then
  . /etc/os-release
  DOCKER_DIST="ubuntu"
  if [ "${ID:-}" = "debian" ]; then DOCKER_DIST="debian"; fi
  curl -fsSL "https://download.docker.com/linux/${DOCKER_DIST}/gpg" \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
fi
. /etc/os-release
DOCKER_DIST="ubuntu"
if [ "${ID:-}" = "debian" ]; then DOCKER_DIST="debian"; fi
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/${DOCKER_DIST} $(lsb_release -cs) stable" \
  > /etc/apt/sources.list.d/docker.list
apt-get update
apt-get -y install docker-ce docker-ce-cli containerd.io docker-compose-plugin
systemctl enable --now docker
if id -u "${TARGET_USER}" >/dev/null 2>&1; then
  usermod -aG docker "${TARGET_USER}" || true
fi

# 9. Caddy (HTTPS 反向代理)
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
  | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/deb.debian.txt' \
  | tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null
apt-get update
apt-get -y install caddy
systemctl enable --now caddy

# 10. 自动安全更新（unattended-upgrades）
dpkg-reconfigure -f noninteractive unattended-upgrades || true
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

# 11. 完成
echo "=== 初始化完成 ==="
if [ "${TARGET_USER}" != "root" ]; then
  echo "请退出并重新登录以使 docker 组变更生效（用户：${TARGET_USER}）"
fi
