# Oracle Cloud VPS 优化脚本

这是一个用于 Oracle Cloud VPS 服务器的自动化优化脚本，主要针对 Debian/Ubuntu 系统进行性能和安全优化。

## 功能特性

### 🚀 性能优化
- **内存管理**: 配置 `vm.swappiness=10` 和 `vm.vfs_cache_pressure=50`
- **ZRAM 压缩**: 使用 zstd 算法，配置为物理内存的 75%
- **I/O 调度器**: 设置为 mq-deadline 并持久化配置
- **网络优化**: 启用 BBR 拥塞控制和 FQ 队列
- **SSD TRIM**: 自动启用 fstrim.timer（如支持）

### 🔒 安全加固
- **防火墙**: 配置 UFW，默认拒绝所有入站连接，放行当前 SSH 端口
- **防暴力破解**: 安装并配置 Fail2ban 保护 SSH 服务
- **服务精简**: 停用不必要的桌面和本地服务

### 🧹 系统清理
- **日志清理**: systemd 日志保留 7 天或 100MB
- **包缓存清理**: 自动清理 apt 缓存和孤儿包

## 快速开始

### 前提条件
- Oracle Cloud VPS 实例
- Debian/Ubuntu 系统
- Root 权限

### 安装使用

```bash
# 克隆项目
cd /tmp
wget https://raw.githubusercontent.com/yourusername/oracle-cloud-setup/main/setup.sh

# 授予执行权限
chmod +x setup.sh

# 运行脚本（需要 root 权限）
sudo ./setup.sh
```

或者直接运行：

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/yourusername/oracle-cloud-setup/main/setup.sh)"
```

## 详细配置

### 内存优化
- `vm.swappiness=10`: 减少交换频率
- `vm.vfs_cache_pressure=50`: 优化文件系统缓存
- ZRAM 使用 zstd 压缩算法，占用 75% 物理内存

### 安全配置
- UFW 防火墙默认配置：
  - 拒绝所有入站连接
  - 允许所有出站连接
  - 自动检测并放行当前 SSH 端口
- Fail2ban 配置：
  - 封禁时间：1 小时
  - 检测窗口：10 分钟
  - 最大重试次数：5 次

### 服务管理
脚本会自动检测并停用以下不必要的服务：
- `cups` - 打印服务
- `bluetooth` - 蓝牙服务
- `avahi-daemon` - 零配置网络
- `ModemManager` - 调制解调器管理
- `whoopsie` - 错误报告
- `apport` - 崩溃报告

## 优化效果

运行脚本后，系统将获得以下改进：

1. **内存使用效率提升**：ZRAM 压缩减少内存压力
2. **磁盘 I/O 性能优化**：mq-deadline 调度器提升 SSD 性能
3. **网络性能提升**：BBR 拥塞控制优化 TCP 连接
4. **安全性增强**：防火墙和 Fail2ban 保护 SSH 服务
5. **系统资源释放**：清理不必要的服务和日志

## 注意事项

1. **重启建议**: 修改内核参数后建议重启系统：`sudo reboot`
2. **Web 服务**: 如需提供 Web 服务，请手动放行端口：
   ```bash
   sudo ufw allow 80/tcp
   sudo ufw allow 443/tcp
   ```
3. **系统兼容性**: 脚本主要针对 Debian/Ubuntu 系统，其他 Linux 发行版可能需要调整
4. **备份机制**: 脚本会自动备份修改的配置文件，添加 `.bak.时间戳` 后缀

## 文件结构

```
oracle-cloud-setup/
├── setup.sh          # 主优化脚本
└── README.md         # 项目说明文档
```

## 📄 开源许可证

本项目采用 **MIT License** 开源协议，这是一个宽松的开源许可证，允许自由使用、修改、分发和商业化。

### 开源声明
本项目已正式开源，欢迎社区贡献和协作开发。

### 推荐协议说明
选择 MIT License 的原因：
- **宽松自由**: 允许商业使用、修改和分发
- **简单明确**: 条款简洁易懂，法律风险低  
- **社区友好**: 广泛接受，兼容性强
- **鼓励贡献**: 降低贡献者门槛

完整的许可证文本请查看 [LICENSE](LICENSE) 文件。

## 贡献

欢迎提交 Issue 和 Pull Request 来改进这个项目。

## 免责声明

请在测试环境中验证脚本后再在生产环境使用。作者不对使用本脚本造成的任何问题负责。