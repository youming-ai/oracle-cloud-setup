#!/usr/bin/env bash
set -euo pipefail

# ====== 配置和常量 ======
readonly SCRIPT_NAME="$(basename "$0")"
readonly LOG_FILE="/var/log/vps-optimization.log"
readonly CONFIG_FILE="/etc/vps-optimize.conf"
readonly BACKUP_DIR="/etc/vps-optimize-backups"

# 在线模式配置
readonly REPO_URL="https://raw.githubusercontent.com/youming-ai/oracle-cloud-setup/main"
readonly TEMP_SCRIPT="/tmp/oracle-cloud-setup-temp.sh"

# 默认配置
DEFAULT_SWAPINESS=10
DEFAULT_ZRAM_PERCENT=75
DEFAULT_BANTIME=3600
DEFAULT_FINDTIME=600
DEFAULT_MAXRETRY=5
DEFAULT_SSH_PORT=22
DEFAULT_DISABLE_PASSWORD_AUTH=false
DEFAULT_DISABLE_ROOT_LOGIN=false
DEFAULT_ENABLE_FAIL2BAN=true
DRY_RUN=false
AUTO_CONFIRM=false

# 颜色定义
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# ====== 基础函数 ======
timestamp() { date +"%Y%m%d-%H%M%S"; }

log() {
  local level="${1:-INFO}"
  local message="$2"
  if [[ "${DRY_RUN:-false}" == "true" ]]; then
    echo -e "${YELLOW}[DRY-RUN]${NC} [$(date '+%Y-%m-%d %H:%M:%S')] [$level] $message" | tee -a "$LOG_FILE"
  else
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $message" | tee -a "$LOG_FILE"
  fi
}

dry_run_log() {
  local operation="$1"
  local details="$2"
  echo -e "${YELLOW}[DRY-RUN] 预执行操作: $operation${NC}"
  if [[ -n "$details" ]]; then
    echo -e "${YELLOW}详细信息: $details${NC}"
  fi
}

print_banner() {
    echo -e "${BLUE}"
    cat << 'EOF'
 ____                                  _____  _          _ _
/ ___|  ___ _ ____   _____ _ __ ___  |  ___|(_) __ _ __| (_)
\___ \ / _ \ '__\ \ / / _ \ '__/ __| | |_  | |/ _` |/ _` | |
 ___) |  __/ |   \ V /  __/ |  \__ \ |  _| | | (_| | (_| | |
|____/ \___|_|    \_/ \___|_|  |___/ |_|   |_|\__,_|\__,_|_|

                CLOUD VPS 优化工具 v1.0
EOF
    echo -e "${NC}"
}

backup_file() {
  local f="$1"
  if [[ -f "$f" ]]; then
    local backup_dir="${BACKUP_DIR}/$(dirname "$f")"
    mkdir -p "$backup_dir"
    cp -a "$f" "${backup_dir}/$(basename "$f").bak.$(timestamp)"
    log "INFO" "已备份文件: $f"
  fi
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

require_root() {
  if [[ $EUID -ne 0 ]]; then
    log "ERROR" "请以 root 身份运行：sudo $0"
    exit 1
  fi
}

# ====== 在线模式函数 ======
check_online_mode() {
  # 检测是否为在线执行（通过URL执行）
  if [[ "${SCRIPT_SOURCE:-}" == "curl" ]] || [[ "${BASH_SOURCE[0]}" == "/dev/stdin" ]]; then
    return 0
  fi
  return 1
}

check_curl() {
  if ! command -v curl >/dev/null 2>&1; then
    echo -e "${RED}错误: 需要安装 curl 才能使用在线模式${NC}"
    echo -e "${YELLOW}请安装 curl:${NC}"

    if command -v apt >/dev/null 2>&1; then
      echo "  sudo apt update && sudo apt install -y curl"
    elif command -v yum >/dev/null 2>&1; then
      echo "  sudo yum install -y curl"
    elif command -v dnf >/dev/null 2>&1; then
      echo "  sudo dnf install -y curl"
    else
      echo "  请手动安装 curl"
    fi
    exit 1
  fi
}

download_and_execute() {
  local mode="${1:-interactive}"

  echo -e "${BLUE}=== 在线安装模式 ===${NC}"
  log "INFO" "检测到在线执行模式，正在下载最新版本..."

  # 下载最新脚本
  if ! curl -fsSL "$REPO_URL/setup.sh" -o "$TEMP_SCRIPT"; then
    log "ERROR" "下载脚本失败，请检查网络连接"
    exit 1
  fi

  # 设置执行权限
  chmod +x "$TEMP_SCRIPT"

  # 执行脚本
  if [[ "$mode" == "auto" ]]; then
    log "INFO" "自动执行优化..."
    bash "$TEMP_SCRIPT" all
  else
    log "INFO" "交互式执行优化..."
    bash "$TEMP_SCRIPT" all
  fi

  # 清理临时文件
  rm -f "$TEMP_SCRIPT"
  log "INFO" "临时文件已清理"
}

# ====== 改进的包管理器支持 ======
pkg_install() {
  if [[ "${DRY_RUN:-false}" == "true" ]]; then
    dry_run_log "安装软件包" "$*"
    return 0
  fi

  if have_cmd apt-get; then
    export DEBIAN_FRONTEND=noninteractive
    if apt-get update -y; then
      apt-get install -y "$@"
    else
      log "ERROR" "APT 更新失败"
      return 1
    fi
  elif have_cmd apt; then
    export DEBIAN_FRONTEND=noninteractive
    if apt update -y; then
      apt install -y "$@"
    else
      log "ERROR" "APT 更新失败"
      return 1
    fi
  elif have_cmd yum; then
    if yum install -y "$@"; then
      log "INFO" "YUM 安装成功: $*"
    else
      log "ERROR" "YUM 安装失败: $*"
      return 1
    fi
  elif have_cmd dnf; then
    if dnf install -y "$@"; then
      log "INFO" "DNF 安装成功: $*"
    else
      log "ERROR" "DNF 安装失败: $*"
      return 1
    fi
  else
    log "ERROR" "未支持的包管理器，脚本主要面向 Debian/Ubuntu/RHEL/CentOS 系统"
    return 1
  fi
}

sysctl_set_kv() {
  local key="$1" val="$2" file="/etc/sysctl.d/99-tuning.conf" reload="${3:-false}"

  if [[ "${DRY_RUN:-false}" == "true" ]]; then
    dry_run_log "设置内核参数" "${key}=${val} (文件: $file, 重载: $reload)"
    return 0
  fi

  # 验证关键操作
  if ! confirm_operation "设置内核参数 ${key}=${val}" "${AUTO_CONFIRM:-false}"; then
    return 1
  fi

  mkdir -p /etc/sysctl.d
  touch "$file"
  backup_file "$file"
  sed -i "s/^${key}.*/# removed by optimize_vps.sh/" "$file" || true
  echo "${key}=${val}" >> "$file"
  log "INFO" "设置内核参数: ${key}=${val}"

  if [[ "$reload" == "true" ]]; then
    if sysctl --system >/dev/null 2>&1; then
      log "INFO" "内核参数已重新加载"
    else
      log "WARN" "内核参数重新加载失败"
    fi
  fi
}

systemd_disable_if_exists() {
  local svc="$1"
  if systemctl list-unit-files | grep -q "^${svc}\.service"; then
    if systemctl disable --now "${svc}.service"; then
      log "INFO" "已禁用服务: ${svc}"
    else
      log "WARN" "禁用服务失败: ${svc}"
    fi
  fi
}

# ====== 环境验证 ======
validate_environment() {
  log "INFO" "开始环境验证..."

  # 检查最小内存要求
  local total_mem=$(free -m | awk 'NR==2{print $2}')
  if [[ $total_mem -lt 512 ]]; then
    log "WARN" "系统内存少于512MB，某些优化可能不适用"
  fi

  # 检查磁盘空间
  local disk_usage=$(df / | awk 'NR==2{print $5}' | sed 's/%//')
  if [[ $disk_usage -gt 90 ]]; then
    log "ERROR" "磁盘使用率过高(${disk_usage}%)，请先清理空间"
    exit 1
  fi

  # 检查网络连接
  if ! ping -c 1 8.8.8.8 >/dev/null 2>&1; then
    log "WARN" "网络连接可能存在问题"
  fi

  log "INFO" "环境验证完成"
}

# ====== 关键操作验证 ======
validate_critical_operation() {
  local operation="$1"
  local config_file="$2"

  case "$operation" in
    "ssh_config")
      # 验证 SSH 配置文件语法
      if ! sshd -t "$config_file" 2>/dev/null; then
        log "ERROR" "SSH 配置文件语法错误，跳过应用"
        return 1
      fi
      log "INFO" "SSH 配置文件语法验证通过"
      ;;
    "sysctl")
      # 验证 sysctl 参数
      if ! sysctl --system --ignore 2>/dev/null; then
        log "WARN" "部分内核参数可能无效，但会继续执行"
      fi
      ;;
    "firewall")
      # 验证防火墙规则不会中断当前连接
      local ssh_port="${SSH_PORT:-22}"
      if ! ufw status verbose | grep -q "$ssh_port.*ALLOW IN"; then
        log "WARN" "防火墙规则可能阻止 SSH 连接，请确保端口 $ssh_port 已开放"
      fi
      ;;
    "package_install")
      # 验证包管理器可用性
      if ! pkg_install --dry-run "$config_file" >/dev/null 2>&1; then
        log "WARN" "包管理器可能不可用，某些安装可能失败"
      fi
      ;;
  esac
  return 0
}

# ====== 确认函数 ======
confirm_operation() {
  local operation="$1"
  local auto_confirm="${2:-false}"

  if [[ "$auto_confirm" == "true" ]]; then
    return 0
  fi

  echo -e "${YELLOW}即将执行关键操作: $operation${NC}"
  echo -e "${YELLOW}是否继续？(y/N)${NC}"
  read -r response

  case "$response" in
    [yY]|[yY][eE][sS])
      return 0
      ;;
    *)
      log "INFO" "用户取消操作: $operation"
      return 1
      ;;
  esac
}

# ====== 加载配置 ======
load_config() {
  # 创建默认配置文件（如果不存在）
  if [[ ! -f "$CONFIG_FILE" ]]; then
    cat >"$CONFIG_FILE" <<EOF
# VPS 优化配置文件
SWAPPINESS=$DEFAULT_SWAPINESS
ZRAM_PERCENT=$DEFAULT_ZRAM_PERCENT
BANTIME=$DEFAULT_BANTIME
FINDTIME=$DEFAULT_FINDTIME
MAXRETRY=$DEFAULT_MAXRETRY
ENABLE_SSH_HARDENING=true
ENABLE_PERFORMANCE_TEST=true
SSH_PORT=$DEFAULT_SSH_PORT
DISABLE_PASSWORD_AUTH=$DEFAULT_DISABLE_PASSWORD_AUTH
DISABLE_ROOT_LOGIN=$DEFAULT_DISABLE_ROOT_LOGIN
ENABLE_FAIL2BAN=$DEFAULT_ENABLE_FAIL2BAN

# SSH 安全选项说明:
# SSH_PORT: SSH 端口号 (默认: 22)
# DISABLE_PASSWORD_AUTH: 禁用密码认证，仅允许密钥登录 (默认: false)
# DISABLE_ROOT_LOGIN: 禁用 root 登录 (默认: false，云服务器推荐)
# 修改这些选项后需要重新生成配置文件或手动编辑
EOF
    log "INFO" "已创建默认配置文件: $CONFIG_FILE"
  fi

  # 加载用户配置
  source "$CONFIG_FILE"
  log "INFO" "已加载配置文件: $CONFIG_FILE"
}

# ====== 回滚功能 ======
rollback_changes() {
  log "INFO" "开始回滚更改..."

  if [[ -d "$BACKUP_DIR" ]]; then
    # 恢复备份文件
    find "$BACKUP_DIR" -name "*.bak.*" -type f | while read -r backup_file; do
      original_path="${backup_file#$BACKUP_DIR}"
      original_path="${original_path%.*.*}"
      if cp "$backup_file" "$original_path"; then
        log "INFO" "已恢复: $original_path"
      else
        log "WARN" "恢复失败: $original_path"
      fi
    done
  else
    log "WARN" "未找到备份目录"
  fi

  # 重启相关服务
  systemctl restart zramswap.service 2>/dev/null || true
  systemctl restart fail2ban 2>/dev/null || true

  log "INFO" "回滚完成，建议重启系统"
}

# ====== 模块化优化函数 ======

optimize_memory() {
  log "INFO" "开始内存优化..."

  # 配置 vm.swappiness 和 vfs_cache_pressure
  log "INFO" "配置 vm.swappiness=${SWAPPINESS:-$DEFAULT_SWAPINESS} 与 vfs_cache_pressure=50"
  sysctl_set_kv "vm.swappiness" "${SWAPPINESS:-$DEFAULT_SWAPINESS}" true
  sysctl_set_kv "vm.vfs_cache_pressure" "50" true

  # 配置 zram
  log "INFO" "安装并配置 zram（小内存推荐）"
  if pkg_install zram-tools; then
    # zram-tools 默认配置文件
    if [[ -f /etc/default/zramswap ]]; then
      backup_file /etc/default/zramswap
      sed -i 's/^#\?ALGO=.*/ALGO=zstd/' /etc/default/zramswap || true
      sed -i "s/^#\?PERCENT=.*/PERCENT=${ZRAM_PERCENT:-$DEFAULT_ZRAM_PERCENT}/" /etc/default/zramswap || true
    else
      cat >/etc/default/zramswap <<EOF
ALGO=zstd
PERCENT=${ZRAM_PERCENT:-$DEFAULT_ZRAM_PERCENT}
PRIORITY=100
EOF
    fi

    if systemctl enable --now zramswap.service; then
      log "INFO" "zram 服务已启用"
    else
      log "WARN" "zram 服务启用失败"
    fi
  else
    log "WARN" "zram-tools 安装失败，跳过 zram 配置"
  fi

  log "INFO" "内存优化完成"
}

optimize_storage() {
  log "INFO" "开始存储优化..."

  # 精简无用服务
  log "INFO" "停用不必要的桌面/本地服务（如存在）"
  for svc in cups bluetooth avahi-daemon ModemManager whoopsie apport; do
    systemd_disable_if_exists "$svc"
  done

  # 启用 SSD 自动 TRIM
  if systemctl list-unit-files | grep -q '^fstrim.timer'; then
    log "INFO" "启用 fstrim.timer"
    if systemctl enable --now fstrim.timer; then
      log "INFO" "fstrim.timer 已启用"
    else
      log "WARN" "fstrim.timer 启用失败"
    fi
  fi

  # 配置 I/O 调度器
  log "INFO" "设置 I/O 调度器为 mq-deadline（运行时 & 持久化）"
  for dev in /sys/block/*; do
    sch_file="${dev}/queue/scheduler"
    [[ -f "$sch_file" ]] || continue
    if grep -q 'mq-deadline' "$sch_file"; then
      echo mq-deadline > "$sch_file" || log "WARN" "设置 ${dev} 调度器失败"
    fi
  done

  # 持久化：udev 规则
  UDEV_RULE=/etc/udev/rules.d/60-io-scheduler.rules
  backup_file "$UDEV_RULE"
  cat >"$UDEV_RULE" <<'EOF'
# Set mq-deadline for common block devices
ACTION=="add|change", KERNEL=="sd[a-z]|vd[a-z]|xvd[a-z]|nvme[0-9]n[0-9]", ATTR{queue/scheduler}="mq-deadline"
EOF
  udevadm control --reload || log "WARN" "udev 规则重载失败"

  log "INFO" "存储优化完成"
}

secure_system() {
  log "INFO" "开始系统安全配置..."

  # 清理日志
  log "INFO" "清理 systemd 日志到 7 天或 100M"
  journalctl --vacuum-time=7d || log "WARN" "日志清理失败"
  journalctl --vacuum-size=100M || log "WARN" "日志清理失败"

  # UFW 防火墙配置
  log "INFO" "配置 UFW 防火墙"
  if pkg_install ufw; then
    SSH_PORT="$(ss -tnlp 2>/dev/null | awk '/sshd/ && /LISTEN/ {sub(/.*:/,"",$4); print $4; exit}')"
    [[ -z "${SSH_PORT:-}" ]] && SSH_PORT=22

    if ufw --force reset && \
       ufw default deny incoming && \
       ufw default allow outgoing && \
       ufw allow "${SSH_PORT}/tcp" && \
       yes | ufw enable; then
      log "INFO" "UFW 防火墙已配置完成，SSH端口: ${SSH_PORT}"
    else
      log "WARN" "UFW 防火墙配置失败"
    fi
  else
    log "WARN" "UFW 安装失败，跳过防火墙配置"
  fi

  # Fail2ban 配置
  log "INFO" "配置 Fail2ban"
  if pkg_install fail2ban; then
    mkdir -p /etc/fail2ban
    JAIL_LOCAL=/etc/fail2ban/jail.local
    backup_file "$JAIL_LOCAL"
    cat >"$JAIL_LOCAL" <<EOF
[DEFAULT]
bantime = ${BANTIME:-$DEFAULT_BANTIME}
findtime = ${FINDTIME:-$DEFAULT_FINDTIME}
maxretry = ${MAXRETRY:-$DEFAULT_MAXRETRY}
backend = systemd

[sshd]
enabled = true
port = ssh
logpath = %(sshd_log)s
EOF

    if systemctl enable --now fail2ban; then
      log "INFO" "Fail2ban 已启用"
    else
      log "WARN" "Fail2ban 启用失败"
    fi
  else
    log "WARN" "Fail2ban 安装失败"
  fi

  # SSH 安全加固（可选）
  if [[ "${ENABLE_SSH_HARDENING:-true}" == "true" ]]; then
    log "INFO" "SSH 安全加固"

    if ! confirm_operation "SSH 安全加固" "${AUTO_CONFIRM:-false}"; then
      log "INFO" "跳过 SSH 安全加固"
    else
      local sshd_config="/etc/ssh/sshd_config"
      backup_file "$sshd_config"

      # 基础安全配置
      sed -i 's/^#\?PermitEmptyPasswords.*/PermitEmptyPasswords no/' "$sshd_config" || true
      sed -i 's/^#\?MaxAuthTries.*/MaxAuthTries 3/' "$sshd_config" || true
      sed -i 's/^#\?ClientAliveInterval.*/ClientAliveInterval 300/' "$sshd_config" || true
      sed -i 's/^#\?ClientAliveCountMax.*/ClientAliveCountMax 2/' "$sshd_config" || true

      # 禁用密码认证（可选）
      if [[ "${DISABLE_PASSWORD_AUTH:-false}" == "true" ]]; then
        sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' "$sshd_config" || true
        log "INFO" "已禁用密码认证（仅允许密钥登录）"
      else
        log "INFO" "保留密码认证（建议配置强密码）"
      fi

      # 禁用 root 登录（可选，谨慎使用）
      if [[ "${DISABLE_ROOT_LOGIN:-false}" == "true" ]]; then
        sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' "$sshd_config" || true
        log "WARN" "已禁用 root 登录，请确保已创建其他用户"
      else
        log "INFO" "保留 root 登录（云服务器环境推荐）"
      fi

      # 验证 SSH 配置
      if validate_critical_operation "ssh_config" "$sshd_config"; then
        log "INFO" "SSH 配置验证通过"
      else
        log "ERROR" "SSH 配置验证失败，正在恢复备份..."
        if [[ -f "${BACKUP_DIR}/etc/ssh/sshd_config.bak."* ]]; then
          cp "${BACKUP_DIR}/etc/ssh/sshd_config.bak."* "$sshd_config"
        fi
        return 1
      fi

      log "INFO" "SSH 安全配置完成"
    fi
  fi

  log "INFO" "系统安全配置完成"
}

optimize_network() {
  log "INFO" "开始网络优化..."

  # BBR 配置
  log "INFO" "配置 BBR 与 FQ 队列"
  if modinfo tcp_bbr >/dev/null 2>&1; then
    sysctl_set_kv "net.core.default_qdisc" "fq" true
    sysctl_set_kv "net.ipv4.tcp_congestion_control" "bbr" true

    # 验证配置生效
    if [[ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" == "bbr" ]]; then
      log "INFO" "BBR 配置成功"
    else
      log "WARN" "BBR 配置可能未生效"
    fi
  else
    log "WARN" "内核不支持 BBR，跳过网络优化"
  fi

  log "INFO" "网络优化完成"
}

cleanup_system() {
  log "INFO" "开始系统清理..."

  # 清理包缓存
  if have_cmd apt-get || have_cmd apt; then
    log "INFO" "清理 APT 缓存与孤儿包"
    apt-get autoremove -y || log "WARN" "APT autoremove 失败"
    apt-get clean || log "WARN" "APT clean 失败"
  elif have_cmd yum; then
    log "INFO" "清理 YUM 缓存"
    yum clean all || log "WARN" "YUM clean 失败"
  elif have_cmd dnf; then
    log "INFO" "清理 DNF 缓存"
    dnf clean all || log "WARN" "DNF clean 失败"
  fi

  log "INFO" "系统清理完成"
}

benchmark_performance() {
  if [[ "${ENABLE_PERFORMANCE_TEST:-true}" != "true" ]]; then
    return 0
  fi

  log "INFO" "开始性能测试..."

  # 内存信息
  log "INFO" "=== 内存信息 ==="
  free -h | tee -a "$LOG_FILE"

  # 磁盘 I/O 测试
  log "INFO" "=== 磁盘 I/O 测试 ==="
  if dd if=/dev/zero of=/tmp/test bs=1M count=100 oflag=direct 2>&1 | tail -1 | tee -a "$LOG_FILE"; then
    rm -f /tmp/test
  else
    log "WARN" "磁盘 I/O 测试失败"
  fi

  # 网络栈配置
  log "INFO" "=== 网络栈配置 ==="
  sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc 2>/dev/null | tee -a "$LOG_FILE" || log "WARN" "无法获取网络配置"

  # 服务状态
  log "INFO" "=== 关键服务状态 ==="
  for service in zramswap fail2ban ufw; do
    if systemctl is-active --quiet "$service" 2>/dev/null; then
      log "INFO" "$service: 运行中"
    else
      log "WARN" "$service: 未运行"
    fi
  done

  log "INFO" "性能测试完成"
}

# ====== 主函数 ======
main() {
  log "INFO" "=== 开始 VPS 优化 ==="

  # 环境检查
  require_root
  validate_environment
  load_config

  # 显示基础信息
  log "INFO" "=== 系统信息 ==="
  uname -a | tee -a "$LOG_FILE" || true
  lsb_release -a 2>/dev/null | tee -a "$LOG_FILE" || cat /etc/os-release | tee -a "$LOG_FILE" || true

  # 创建备份目录
  mkdir -p "$BACKUP_DIR"

  # 执行优化模块
  optimize_memory
  optimize_storage
  secure_system
  optimize_network
  cleanup_system

  # 性能测试
  benchmark_performance

  log "INFO" "=== 优化完成！==="
  echo ">>> 优化概要："
  echo " - swappiness=${SWAPPINESS:-$DEFAULT_SWAPINESS}, vfs_cache_pressure=50"
  echo " - zram: zstd, ${ZRAM_PERCENT:-$DEFAULT_ZRAM_PERCENT}% 内存"
  echo " - 精简桌面/本地服务（如存在）"
  echo " - 日志清理至 7 天/100M；包缓存清理"
  echo " - fstrim.timer 已启用（如系统支持）"
  echo " - I/O 调度器 mq-deadline"
  echo " - UFW 防火墙已启用"
  echo " - Fail2ban 已启用（sshd 保护）"
  echo " - BBR 已启用（如内核支持）"
  echo
  echo "配置文件: $CONFIG_FILE"
  echo "日志文件: $LOG_FILE"
  echo "备份目录: $BACKUP_DIR"
  echo
  echo "建议："
  echo " - 重启系统以使所有更改生效"
  echo " - 如需提供 Web 服务，记得放行端口：ufw allow 80/tcp && ufw allow 443/tcp"
  echo " - 如需回滚更改，运行：$0 rollback"

  # 重启确认（如果不是 dry-run 模式）
  if [[ "${DRY_RUN:-false}" != "true" ]]; then
    echo
    if confirm_operation "立即重启系统以应用所有更改" "${AUTO_CONFIRM:-false}"; then
      log "INFO" "用户确认重启，系统将在10秒后重启..."
      echo -e "${GREEN}系统将在10秒后重启，按 Ctrl+C 取消${NC}"
      sleep 10
      reboot
    else
      log "INFO" "用户选择稍后手动重启"
      echo -e "${YELLOW}请记得稍后手动重启系统：sudo reboot${NC}"
    fi
  else
    echo -e "${YELLOW}[DRY-RUN] 实际执行时将询问是否重启系统${NC}"
  fi
}

show_help() {
  cat << EOF
Oracle Cloud VPS 优化工具 v1.0

用法: $0 [选项] [模块]

选项:
  --help, -h          显示此帮助信息
  --dry-run           预览模式，仅显示将要执行的操作，不实际执行
  --auto-confirm      自动确认所有操作，不询问用户

模块:
  memory              仅执行内存优化
  storage             仅执行存储优化
  security            仅执行安全配置
  network             仅执行网络优化
  benchmark           仅执行性能测试
  rollback            回滚所有更改
  all (默认)          执行完整优化

示例:
  # 一键安装和优化 (推荐)
  sudo bash -c "\$(curl -fsSL https://raw.githubusercontent.com/youming-ai/oracle-cloud-setup/main/setup.sh)"

  # 本地执行完整优化
  sudo $0

  # 仅优化内存
  sudo $0 memory

  # 预览将要执行的操作
  sudo $0 --dry-run all

  # 自动确认所有操作
  sudo $0 --auto-confirm all

  # 预览并自动确认内存优化
  sudo $0 --dry-run --auto-confirm memory

  # 回滚更改
  sudo $0 rollback

EOF
}

# ====== 脚本入口 ======

# 检查在线模式
if check_online_mode; then
  # 在线模式：检查 curl，然后下载执行
  check_curl

  # 解析命令行参数
  local mode="interactive"
  for arg in "$@"; do
    case "$arg" in
      --auto)
        mode="auto"
        ;;
      --dry-run)
        export DRY_RUN=true
        ;;
      --auto-confirm)
        export AUTO_CONFIRM=true
        ;;
      --help|-h)
        show_help
        exit 0
        ;;
    esac
  done

  print_banner
  download_and_execute "$mode"
else
  # 本地模式：解析命令行参数
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)
        export DRY_RUN=true
        shift
        ;;
      --auto-confirm)
        export AUTO_CONFIRM=true
        shift
        ;;
      --help|-h)
        show_help
        exit 0
        ;;
      *)
        shift
        ;;
    esac
  done

  # 本地模式：直接执行优化
  case "${1:-all}" in
    memory)
      require_root
      validate_environment
      load_config
      optimize_memory
      ;;
    storage)
      require_root
      validate_environment
      load_config
      optimize_storage
      ;;
    security)
      require_root
      validate_environment
      load_config
      secure_system
      ;;
    network)
      require_root
      validate_environment
      load_config
      optimize_network
      ;;
    benchmark)
      require_root
      validate_environment
      load_config
      benchmark_performance
      ;;
    rollback)
      require_root
      rollback_changes
      ;;
    all|"")
      print_banner
      main
      ;;
    --help|-h)
      show_help
      ;;
    *)
      echo "用法: $0 [memory|storage|security|network|benchmark|rollback|all]"
      echo "使用 --help 查看详细帮助"
      exit 1
      ;;
  esac
fi
