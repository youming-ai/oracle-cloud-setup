#!/usr/bin/env bash
set -euo pipefail

# ====== 基础函数 ======
timestamp() { date +"%Y%m%d-%H%M%S"; }
backup_file() { local f="$1"; [[ -f "$f" ]] && cp -a "$f" "${f}.bak.$(timestamp)" || true; }
have_cmd() { command -v "$1" >/dev/null 2>&1; }

require_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "请以 root 身份运行：sudo $0"
    exit 1
  fi
}

pkg_install() {
  # 以 APT 为主，兼容部分 RHEL 系（尽量不动）
  if have_cmd apt-get; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y "$@"
  elif have_cmd apt; then
    export DEBIAN_FRONTEND=noninteractive
    apt update -y
    apt install -y "$@"
  else
    echo "未检测到 apt 系包管理器，脚本主要面向 Debian/Ubuntu。"
  fi
}

sysctl_set_kv() {
  local key="$1" val="$2" file="/etc/sysctl.d/99-tuning.conf"
  mkdir -p /etc/sysctl.d
  touch "$file"
  backup_file "$file"
  # 删除旧行，追加新行
  sed -i "s/^${key}.*/# removed by optimize_vps.sh/" "$file" || true
  echo "${key}=${val}" >> "$file"
}

systemd_disable_if_exists() {
  local svc="$1"
  if systemctl list-unit-files | grep -q "^${svc}\.service"; then
    systemctl disable --now "${svc}.service" || true
  fi
}

# ====== 0. 环境检查 ======
require_root

echo ">>> 基础信息"
uname -a || true
lsb_release -a 2>/dev/null || cat /etc/os-release || true

# ====== 1. 内存与 Swap 优化 ======
echo ">>> 配置 vm.swappiness=10 与 vfs_cache_pressure=50"
sysctl_set_kv "vm.swappiness" "10"
sysctl_set_kv "vm.vfs_cache_pressure" "50"

echo ">>> 安装并配置 zram（小内存推荐）"
if have_cmd apt-get || have_cmd apt; then
  pkg_install zram-tools || true
  # zram-tools 默认配置文件
  if [[ -f /etc/default/zramswap ]]; then
    backup_file /etc/default/zramswap
    # 设置压缩算法与容量比例（按物理内存的 75%）
    sed -i 's/^#\?ALGO=.*/ALGO=zstd/' /etc/default/zramswap || true
    sed -i 's/^#\?PERCENT=.*/PERCENT=75/' /etc/default/zramswap || true
  else
    cat >/etc/default/zramswap <<'EOF'
ALGO=zstd
PERCENT=75
PRIORITY=100
EOF
  fi
  systemctl enable --now zramswap.service || true
fi

# ====== 2. 精简无用服务（存在才处理） ======
echo ">>> 停用不必要的桌面/本地服务（如存在）"
for svc in cups bluetooth avahi-daemon ModemManager whoopsie apport; do
  systemd_disable_if_exists "$svc"
done

# ====== 3. 日志与包缓存清理 ======
echo ">>> 清理 systemd 日志到 7 天或 100M"
journalctl --vacuum-time=7d || true
journalctl --vacuum-size=100M || true

if have_cmd apt-get || have_cmd apt; then
  echo ">>> 清理 apt 缓存与孤儿包"
  apt-get autoremove -y || true
  apt-get clean || true
fi

# ====== 4. 启用 SSD 自动 TRIM（如支持） ======
if systemctl list-unit-files | grep -q '^fstrim.timer'; then
  echo ">>> 启用 fstrim.timer"
  systemctl enable --now fstrim.timer || true
fi

# ====== 5. I/O 调度器（mq-deadline）并持久化 ======
echo ">>> 设置 I/O 调度器为 mq-deadline（运行时 & 持久化）"
# 运行时：尽量对所有块设备设置
for dev in /sys/block/*; do
  sch_file="${dev}/queue/scheduler"
  [[ -f "$sch_file" ]] || continue
  if grep -q 'mq-deadline' "$sch_file"; then
    echo mq-deadline > "$sch_file" || true
  fi
done

# 持久化：udev 规则
UDEV_RULE=/etc/udev/rules.d/60-io-scheduler.rules
backup_file "$UDEV_RULE"
cat >"$UDEV_RULE" <<'EOF'
# Set mq-deadline for common block devices
ACTION=="add|change", KERNEL=="sd[a-z]|vd[a-z]|xvd[a-z]|nvme[0-9]n[0-9]", ATTR{queue/scheduler}="mq-deadline"
EOF
udevadm control --reload || true

# ====== 6. UFW 防火墙（放行当前 SSH 端口） ======
if have_cmd apt-get || have_cmd apt; then
  echo ">>> 安装并配置 UFW"
  pkg_install ufw || true
  # 检测当前 sshd 监听端口
  SSH_PORT="$(ss -tnlp 2>/dev/null | awk '/sshd/ && /LISTEN/ {sub(/.*:/,"",$4); print $4; exit}')"
  [[ -z "${SSH_PORT:-}" ]] && SSH_PORT=22
  ufw --force reset || true
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow "${SSH_PORT}/tcp"
  # 如需放行 Web，再执行：ufw allow 80/tcp && ufw allow 443/tcp
  yes | ufw enable
fi

# ====== 7. Fail2ban（SSH 保护） ======
if have_cmd apt-get || have_cmd apt; then
  echo ">>> 安装并启用 Fail2ban"
  pkg_install fail2ban || true
  mkdir -p /etc/fail2ban
  JAIL_LOCAL=/etc/fail2ban/jail.local
  backup_file "$JAIL_LOCAL"
  cat >"$JAIL_LOCAL" <<'EOF'
[DEFAULT]
bantime = 1h
findtime = 10m
maxretry = 5
backend = systemd

[sshd]
enabled = true
port = ssh
logpath = %(sshd_log)s
EOF
  systemctl enable --now fail2ban || true
fi

# ====== 8. 网络栈：BBR ======
echo ">>> 启用 BBR 与 FQ 队列"
sysctl_set_kv "net.core.default_qdisc" "fq"
sysctl_set_kv "net.ipv4.tcp_congestion_control" "bbr"
sysctl --system >/dev/null

# ====== 9. 收尾与提示 ======
echo ">>> 优化完成！概要："
echo " - swappiness=10, vfs_cache_pressure=50 （/etc/sysctl.d/99-tuning.conf）"
echo " - zram: zstd, 75% 内存，已启用（zramswap.service）"
echo " - 精简桌面/本地服务（如存在）"
echo " - 日志清理至 7 天/100M；APT 缓存清理"
echo " - fstrim.timer 已启用（如系统支持）"
echo " - I/O 调度器 mq-deadline（含持久化 udev 规则）"
echo " - UFW 已启用：默认拒入、放行 SSH(${SSH_PORT:-22})"
echo " - Fail2ban 已启用（sshd 保护）"
echo " - BBR 已启用"

echo
echo "建议："
echo " - 如修改了内核网络参数或 I/O 调度器规则，重启后更稳定：reboot"
echo " - 若你提供 Web 服务，记得放行端口：ufw allow 80/tcp && ufw allow 443/tcp"
