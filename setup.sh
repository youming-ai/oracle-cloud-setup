#!/usr/bin/env bash
set -euo pipefail

# ====== Configuration and Constants ======
readonly SCRIPT_NAME="$(basename "$0")"
readonly LOG_FILE="/var/log/vps-optimization.log"
readonly CONFIG_FILE="/etc/vps-optimize.conf"
readonly BACKUP_DIR="/etc/vps-optimize-backups"

# Online mode configuration
readonly REPO_URL="https://raw.githubusercontent.com/youming-ai/oracle-cloud-setup/main"
readonly TEMP_SCRIPT="/tmp/oracle-cloud-setup-temp.sh"

# Default configuration
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

# Color definitions
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# ====== Basic Functions ======
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
  echo -e "${YELLOW}[DRY-RUN] Pre-execution operation: $operation${NC}"
  if [[ -n "$details" ]]; then
    echo -e "${YELLOW}Details: $details${NC}"
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

                CLOUD VPS Optimization Tool v1.0
EOF
    echo -e "${NC}"
}

backup_file() {
  local f="$1"
  if [[ -f "$f" ]]; then
    local backup_dir="${BACKUP_DIR}/$(dirname "$f")"
    mkdir -p "$backup_dir"
    cp -a "$f" "${backup_dir}/$(basename "$f").bak.$(timestamp)"
    log "INFO" "File backed up: $f"
  fi
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

require_root() {
  if [[ $EUID -ne 0 ]]; then
    log "ERROR" "Please run as root: sudo $0"
    exit 1
  fi
}

# ====== Online Mode Functions ======
check_online_mode() {
  # Detect if running online (via URL execution)
  if [[ "${SCRIPT_SOURCE:-}" == "curl" ]] || [[ "${BASH_SOURCE[0]}" == "/dev/stdin" ]]; then
    return 0
  fi
  return 1
}

check_curl() {
  if ! command -v curl >/dev/null 2>&1; then
    echo -e "${RED}Error: curl needs to be installed for online mode${NC}"
    echo -e "${YELLOW}Please install curl:${NC}"

    if command -v apt >/dev/null 2>&1; then
      echo "  sudo apt update && sudo apt install -y curl"
    elif command -v yum >/dev/null 2>&1; then
      echo "  sudo yum install -y curl"
    elif command -v dnf >/dev/null 2>&1; then
      echo "  sudo dnf install -y curl"
    else
      echo "  Please install curl manually"
    fi
    exit 1
  fi
}

download_and_execute() {
  local mode="${1:-interactive}"

  echo -e "${BLUE}=== Online Installation Mode ===${NC}"
  log "INFO" "Detected online execution mode, downloading latest version..."

  # Download latest script
  if ! curl -fsSL "$REPO_URL/setup.sh" -o "$TEMP_SCRIPT"; then
    log "ERROR" "Failed to download script, please check network connection"
    exit 1
  fi

  # Set execution permissions
  chmod +x "$TEMP_SCRIPT"

  # Execute script
  if [[ "$mode" == "auto" ]]; then
    log "INFO" "Auto-executing optimization..."
    bash "$TEMP_SCRIPT" all
  else
    log "INFO" "Interactive execution optimization..."
    bash "$TEMP_SCRIPT" all
  fi

  # Clean up temporary files
  rm -f "$TEMP_SCRIPT"
  log "INFO" "Temporary files cleaned up"
}

# ====== Improved Package Manager Support ======
pkg_install() {
  if [[ "${DRY_RUN:-false}" == "true" ]]; then
    dry_run_log "Install packages" "$*"
    return 0
  fi

  if have_cmd apt-get; then
    export DEBIAN_FRONTEND=noninteractive
    if apt-get update -y; then
      apt-get install -y "$@"
    else
      log "ERROR" "APT update failed"
      return 1
    fi
  elif have_cmd apt; then
    export DEBIAN_FRONTEND=noninteractive
    if apt update -y; then
      apt install -y "$@"
    else
      log "ERROR" "APT update failed"
      return 1
    fi
  elif have_cmd yum; then
    if yum install -y "$@"; then
      log "INFO" "YUM installation successful: $*"
    else
      log "ERROR" "YUM installation failed: $*"
      return 1
    fi
  elif have_cmd dnf; then
    if dnf install -y "$@"; then
      log "INFO" "DNF installation successful: $*"
    else
      log "ERROR" "DNF installation failed: $*"
      return 1
    fi
  else
    log "ERROR" "Unsupported package manager, script mainly targets Debian/Ubuntu/RHEL/CentOS systems"
    return 1
  fi
}

sysctl_set_kv() {
  local key="$1" val="$2" file="/etc/sysctl.d/99-tuning.conf" reload="${3:-false}"

  if [[ "${DRY_RUN:-false}" == "true" ]]; then
    dry_run_log "Set kernel parameters" "${key}=${val} (file: $file, reload: $reload)"
    return 0
  fi

  # Validate critical operation
  if ! confirm_operation "Set kernel parameter ${key}=${val}" "${AUTO_CONFIRM:-false}"; then
    return 1
  fi

  mkdir -p /etc/sysctl.d
  touch "$file"
  backup_file "$file"
  sed -i "s/^${key}.*/# removed by optimize_vps.sh/" "$file" || true
  echo "${key}=${val}" >> "$file"
  log "INFO" "Set kernel parameter: ${key}=${val}"

  if [[ "$reload" == "true" ]]; then
    if sysctl --system >/dev/null 2>&1; then
      log "INFO" "Kernel parameters reloaded"
    else
      log "WARN" "Kernel parameter reload failed"
    fi
  fi
}

systemd_disable_if_exists() {
  local svc="$1"
  if systemctl list-unit-files | grep -q "^${svc}\.service"; then
    if systemctl disable --now "${svc}.service"; then
      log "INFO" "Service disabled: ${svc}"
    else
      log "WARN" "Failed to disable service: ${svc}"
    fi
  fi
}

# ====== Environment Validation ======
validate_environment() {
  log "INFO" "Starting environment validation..."

  # Check minimum memory requirements
  local total_mem=$(free -m | awk 'NR==2{print $2}')
  if [[ $total_mem -lt 512 ]]; then
    log "WARN" "System memory less than 512MB, some optimizations may not apply"
  fi

  # Check disk space
  local disk_usage=$(df / | awk 'NR==2{print $5}' | sed 's/%//')
  if [[ $disk_usage -gt 90 ]]; then
    log "ERROR" "Disk usage too high (${disk_usage}%), please free up space first"
    exit 1
  fi

  # Check network connectivity
  if ! ping -c 1 8.8.8.8 >/dev/null 2>&1; then
    log "WARN" "Network connection may have issues"
  fi

  log "INFO" "Environment validation completed"
}

# ====== Critical Operation Validation ======
validate_critical_operation() {
  local operation="$1"
  local config_file="$2"

  case "$operation" in
    "ssh_config")
      # Validate SSH configuration file syntax
      if ! sshd -t "$config_file" 2>/dev/null; then
        log "ERROR" "SSH configuration file syntax error, skipping application"
        return 1
      fi
      log "INFO" "SSH configuration file syntax validation passed"
      ;;
    "sysctl")
      # Validate sysctl parameters
      if ! sysctl --system --ignore 2>/dev/null; then
        log "WARN" "Some kernel parameters may be invalid, but will continue execution"
      fi
      ;;
    "firewall")
      # Validate firewall rules won't interrupt current connection
      local ssh_port="${SSH_PORT:-22}"
      if ! ufw status verbose | grep -q "$ssh_port.*ALLOW IN"; then
        log "WARN" "Firewall rules may block SSH connection, please ensure port $ssh_port is open"
      fi
      ;;
    "package_install")
      # Validate package manager availability
      if ! pkg_install --dry-run "$config_file" >/dev/null 2>&1; then
        log "WARN" "Package manager may not be available, some installations may fail"
      fi
      ;;
  esac
  return 0
}

# ====== Confirmation Function ======
confirm_operation() {
  local operation="$1"
  local auto_confirm="${2:-false}"

  if [[ "$auto_confirm" == "true" ]]; then
    return 0
  fi

  echo -e "${YELLOW}About to execute critical operation: $operation${NC}"
  echo -e "${YELLOW}Continue? (y/N)${NC}"
  read -r response

  case "$response" in
    [yY]|[yY][eE][sS])
      return 0
      ;;
    *)
      log "INFO" "User cancelled operation: $operation"
      return 1
      ;;
  esac
}

# ====== Load Configuration ======
load_config() {
  # Create default configuration file (if it doesn't exist)
  if [[ ! -f "$CONFIG_FILE" ]]; then
    cat >"$CONFIG_FILE" <<EOF
# VPS Optimization Configuration File
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

# SSH Security Options Description:
# SSH_PORT: SSH port number (default: 22)
# DISABLE_PASSWORD_AUTH: Disable password authentication, only allow key login (default: false)
# DISABLE_ROOT_LOGIN: Disable root login (default: false, recommended for cloud servers)
# After modifying these options, you need to regenerate the configuration file or edit manually
EOF
    log "INFO" "Created default configuration file: $CONFIG_FILE"
  fi

  # Load user configuration
  source "$CONFIG_FILE"
  log "INFO" "Loaded configuration file: $CONFIG_FILE"
}

# ====== Rollback Function ======
rollback_changes() {
  log "INFO" "Starting rollback of changes..."

  if [[ -d "$BACKUP_DIR" ]]; then
    # Restore backup files
    find "$BACKUP_DIR" -name "*.bak.*" -type f | while read -r backup_file; do
      original_path="${backup_file#$BACKUP_DIR}"
      original_path="${original_path%.*.*}"
      if cp "$backup_file" "$original_path"; then
        log "INFO" "Restored: $original_path"
      else
        log "WARN" "Restore failed: $original_path"
      fi
    done
  else
    log "WARN" "Backup directory not found"
  fi

  # Restart related services
  systemctl restart zramswap.service 2>/dev/null || true
  systemctl restart fail2ban 2>/dev/null || true

  log "INFO" "Rollback completed, system restart recommended"
}

# ====== Modular Optimization Functions ======

optimize_memory() {
  log "INFO" "Starting memory optimization..."

  # Configure vm.swappiness and vfs_cache_pressure
  log "INFO" "Configuring vm.swappiness=${SWAPPINESS:-$DEFAULT_SWAPINESS} and vfs_cache_pressure=50"
  sysctl_set_kv "vm.swappiness" "${SWAPPINESS:-$DEFAULT_SWAPINESS}" true
  sysctl_set_kv "vm.vfs_cache_pressure" "50" true

  # Configure zram
  log "INFO" "Installing and configuring zram (recommended for low memory systems)"
  if pkg_install zram-tools; then
    # zram-tools default configuration file
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
      log "INFO" "zram service enabled"
    else
      log "WARN" "zram service enable failed"
    fi
  else
    log "WARN" "zram-tools installation failed, skipping zram configuration"
  fi

  log "INFO" "Memory optimization completed"
}

optimize_storage() {
  log "INFO" "Starting storage optimization..."

  # Remove unnecessary services
  log "INFO" "Disabling unnecessary desktop/local services (if present)"
  for svc in cups bluetooth avahi-daemon ModemManager whoopsie apport; do
    systemd_disable_if_exists "$svc"
  done

  # Enable SSD automatic TRIM
  if systemctl list-unit-files | grep -q '^fstrim.timer'; then
    log "INFO" "Enabling fstrim.timer"
    if systemctl enable --now fstrim.timer; then
      log "INFO" "fstrim.timer enabled"
    else
      log "WARN" "fstrim.timer enable failed"
    fi
  fi

  # Configure I/O scheduler
  log "INFO" "Setting I/O scheduler to mq-deadline (runtime & persistent)"
  for dev in /sys/block/*; do
    sch_file="${dev}/queue/scheduler"
    [[ -f "$sch_file" ]] || continue
    if grep -q 'mq-deadline' "$sch_file"; then
      echo mq-deadline > "$sch_file" || log "WARN" "Failed to set ${dev} scheduler"
    fi
  done

  # Persistence: udev rules
  UDEV_RULE=/etc/udev/rules.d/60-io-scheduler.rules
  backup_file "$UDEV_RULE"
  cat >"$UDEV_RULE" <<'EOF'
# Set mq-deadline for common block devices
ACTION=="add|change", KERNEL=="sd[a-z]|vd[a-z]|xvd[a-z]|nvme[0-9]n[0-9]", ATTR{queue/scheduler}="mq-deadline"
EOF
  udevadm control --reload || log "WARN" "udev rules reload failed"

  log "INFO" "Storage optimization completed"
}

secure_system() {
  log "INFO" "Starting system security configuration..."

  # Clean up logs
  log "INFO" "Cleaning systemd logs to 7 days or 100M"
  journalctl --vacuum-time=7d || log "WARN" "Log cleanup failed"
  journalctl --vacuum-size=100M || log "WARN" "Log cleanup failed"

  # UFW firewall configuration
  log "INFO" "Configuring UFW firewall"
  if pkg_install ufw; then
    SSH_PORT="$(ss -tnlp 2>/dev/null | awk '/sshd/ && /LISTEN/ {sub(/.*:/,"",$4); print $4; exit}')"
    [[ -z "${SSH_PORT:-}" ]] && SSH_PORT=22

    if ufw --force reset && \
       ufw default deny incoming && \
       ufw default allow outgoing && \
       ufw allow "${SSH_PORT}/tcp" && \
       yes | ufw enable; then
      log "INFO" "UFW firewall configuration completed, SSH port: ${SSH_PORT}"
    else
      log "WARN" "UFW firewall configuration failed"
    fi
  else
    log "WARN" "UFW installation failed, skipping firewall configuration"
  fi

  # Fail2ban configuration
  log "INFO" "Configuring Fail2ban"
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
      log "INFO" "Fail2ban enabled"
    else
      log "WARN" "Fail2ban enable failed"
    fi
  else
    log "WARN" "Fail2ban installation failed"
  fi

  # SSH security hardening (optional)
  if [[ "${ENABLE_SSH_HARDENING:-true}" == "true" ]]; then
    log "INFO" "SSH security hardening"

    if ! confirm_operation "SSH security hardening" "${AUTO_CONFIRM:-false}"; then
      log "INFO" "Skipping SSH security hardening"
    else
      local sshd_config="/etc/ssh/sshd_config"
      backup_file "$sshd_config"

      # Basic security configuration
      sed -i 's/^#\?PermitEmptyPasswords.*/PermitEmptyPasswords no/' "$sshd_config" || true
      sed -i 's/^#\?MaxAuthTries.*/MaxAuthTries 3/' "$sshd_config" || true
      sed -i 's/^#\?ClientAliveInterval.*/ClientAliveInterval 300/' "$sshd_config" || true
      sed -i 's/^#\?ClientAliveCountMax.*/ClientAliveCountMax 2/' "$sshd_config" || true

      # Disable password authentication (optional)
      if [[ "${DISABLE_PASSWORD_AUTH:-false}" == "true" ]]; then
        sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' "$sshd_config" || true
        log "INFO" "Password authentication disabled (only key login allowed)"
      else
        log "INFO" "Password authentication retained (strong password recommended)"
      fi

      # Disable root login (optional, use with caution)
      if [[ "${DISABLE_ROOT_LOGIN:-false}" == "true" ]]; then
        sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' "$sshd_config" || true
        log "WARN" "Root login disabled, please ensure other users have been created"
      else
        log "INFO" "Root login retained (recommended for cloud server environments)"
      fi

      # Validate SSH configuration
      if validate_critical_operation "ssh_config" "$sshd_config"; then
        log "INFO" "SSH configuration validation passed"
      else
        log "ERROR" "SSH configuration validation failed, restoring backup..."
        if [[ -f "${BACKUP_DIR}/etc/ssh/sshd_config.bak."* ]]; then
          cp "${BACKUP_DIR}/etc/ssh/sshd_config.bak."* "$sshd_config"
        fi
        return 1
      fi

      log "INFO" "SSH security configuration completed"
    fi
  fi

  log "INFO" "System security configuration completed"
}

optimize_network() {
  log "INFO" "Starting network optimization..."

  # BBR configuration
  log "INFO" "Configuring BBR and FQ queue"
  if modinfo tcp_bbr >/dev/null 2>&1; then
    sysctl_set_kv "net.core.default_qdisc" "fq" true
    sysctl_set_kv "net.ipv4.tcp_congestion_control" "bbr" true

    # Verify configuration takes effect
    if [[ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" == "bbr" ]]; then
      log "INFO" "BBR configuration successful"
    else
      log "WARN" "BBR configuration may not have taken effect"
    fi
  else
    log "WARN" "Kernel does not support BBR, skipping network optimization"
  fi

  log "INFO" "Network optimization completed"
}

cleanup_system() {
  log "INFO" "Starting system cleanup..."

  # Clean package cache
  if have_cmd apt-get || have_cmd apt; then
    log "INFO" "Cleaning APT cache and orphan packages"
    apt-get autoremove -y || log "WARN" "APT autoremove failed"
    apt-get clean || log "WARN" "APT clean failed"
  elif have_cmd yum; then
    log "INFO" "Cleaning YUM cache"
    yum clean all || log "WARN" "YUM clean failed"
  elif have_cmd dnf; then
    log "INFO" "Cleaning DNF cache"
    dnf clean all || log "WARN" "DNF clean failed"
  fi

  log "INFO" "System cleanup completed"
}

benchmark_performance() {
  if [[ "${ENABLE_PERFORMANCE_TEST:-true}" != "true" ]]; then
    return 0
  fi

  log "INFO" "Starting performance testing..."

  # Memory information
  log "INFO" "=== Memory Information ==="
  free -h | tee -a "$LOG_FILE"

  # Disk I/O test
  log "INFO" "=== Disk I/O Test ==="
  if dd if=/dev/zero of=/tmp/test bs=1M count=100 oflag=direct 2>&1 | tail -1 | tee -a "$LOG_FILE"; then
    rm -f /tmp/test
  else
    log "WARN" "Disk I/O test failed"
  fi

  # Network stack configuration
  log "INFO" "=== Network Stack Configuration ==="
  sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc 2>/dev/null | tee -a "$LOG_FILE" || log "WARN" "Unable to get network configuration"

  # Service status
  log "INFO" "=== Key Service Status ==="
  for service in zramswap fail2ban ufw; do
    if systemctl is-active --quiet "$service" 2>/dev/null; then
      log "INFO" "$service: Running"
    else
      log "WARN" "$service: Not running"
    fi
  done

  log "INFO" "Performance testing completed"
}

# ====== Main Function ======
main() {
  log "INFO" "=== Starting VPS Optimization ==="

  # Environment check
  require_root
  validate_environment
  load_config

  # Display basic information
  log "INFO" "=== System Information ==="
  uname -a | tee -a "$LOG_FILE" || true
  lsb_release -a 2>/dev/null | tee -a "$LOG_FILE" || cat /etc/os-release | tee -a "$LOG_FILE" || true

  # Create backup directory
  mkdir -p "$BACKUP_DIR"

  # Execute optimization modules
  optimize_memory
  optimize_storage
  secure_system
  optimize_network
  cleanup_system

  # Performance testing
  benchmark_performance

  log "INFO" "=== Optimization Completed! ==="
  echo ">>> Optimization Summary:"
  echo " - swappiness=${SWAPPINESS:-$DEFAULT_SWAPINESS}, vfs_cache_pressure=50"
  echo " - zram: zstd, ${ZRAM_PERCENT:-$DEFAULT_ZRAM_PERCENT}% memory"
  echo " - Removed desktop/local services (if present)"
  echo " - Logs cleaned to 7 days/100M; package cache cleaned"
  echo " - fstrim.timer enabled (if system supports)"
  echo " - I/O scheduler mq-deadline"
  echo " - UFW firewall enabled"
  echo " - Fail2ban enabled (sshd protection)"
  echo " - BBR enabled (if kernel supports)"
  echo
  echo "Configuration file: $CONFIG_FILE"
  echo "Log file: $LOG_FILE"
  echo "Backup directory: $BACKUP_DIR"
  echo
  echo "Recommendations:"
  echo " - Restart system to apply all changes"
  echo " - If providing web services, remember to open ports: ufw allow 80/tcp && ufw allow 443/tcp"
  echo " - To rollback changes, run: $0 rollback"

  # Restart confirmation (if not dry-run mode)
  if [[ "${DRY_RUN:-false}" != "true" ]]; then
    echo
    if confirm_operation "Restart system immediately to apply all changes" "${AUTO_CONFIRM:-false}"; then
      log "INFO" "User confirmed restart, system will restart in 10 seconds..."
      echo -e "${GREEN}System will restart in 10 seconds, press Ctrl+C to cancel${NC}"
      sleep 10
      reboot
    else
      log "INFO" "User chose to manually restart later"
      echo -e "${YELLOW}Please remember to manually restart system later: sudo reboot${NC}"
    fi
  else
    echo -e "${YELLOW}[DRY-RUN] Will ask about system restart during actual execution${NC}"
  fi
}

show_help() {
  cat << EOF
Oracle Cloud VPS Optimization Tool v1.0

Usage: $0 [options] [module]

Options:
  --help, -h          Show this help information
  --dry-run           Preview mode, only show operations to be executed without actually executing
  --auto-confirm      Auto-confirm all operations without asking user

Modules:
  memory              Execute memory optimization only
  storage             Execute storage optimization only
  security            Execute security configuration only
  network             Execute network optimization only
  benchmark           Execute performance testing only
  rollback            Rollback all changes
  all (default)       Execute complete optimization

Examples:
  # One-click install and optimize (recommended)
  sudo bash -c "\$(curl -fsSL https://raw.githubusercontent.com/youming-ai/oracle-cloud-setup/main/setup.sh)"

  # Local execution of complete optimization
  sudo $0

  # Optimize memory only
  sudo $0 memory

  # Preview operations to be executed
  sudo $0 --dry-run all

  # Auto-confirm all operations
  sudo $0 --auto-confirm all

  # Preview and auto-confirm memory optimization
  sudo $0 --dry-run --auto-confirm memory

  # Rollback changes
  sudo $0 rollback

EOF
}

# ====== Script Entry Point ======

# Check online mode
if check_online_mode; then
  # Online mode: check curl, then download and execute
  check_curl

  # Parse command line arguments
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
  # Local mode: parse command line arguments
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

  # Local mode: directly execute optimization
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
      echo "Usage: $0 [memory|storage|security|network|benchmark|rollback|all]"
      echo "Use --help to view detailed help"
      exit 1
      ;;
  esac
fi
