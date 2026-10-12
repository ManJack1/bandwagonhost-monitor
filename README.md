# BandwagonHost Monitor

一个轻量的 Windows 桌面悬浮监控工具，使用 BandwagonHost / KiwiVM 官方 API 显示 VPS 月流量使用率、剩余流量和重置日期。

## 功能

- 首次启动时直接输入设备名称、VEID 和 API Key
- 支持保存多台搬瓦工 VPS，并从主窗口下拉切换
- 可随时编辑当前设备或添加新设备
- API Key 使用 Windows DPAPI 加密，仅能由当前 Windows 用户解密
- 每 30 分钟自动刷新，也可手动刷新
- 根据流量使用率改变状态颜色
- 可拖动、置顶显示、记忆窗口位置
- 一键添加到当前用户的 Windows 开机启动

## 系统要求

- Windows 10 或 Windows 11
- Windows PowerShell 5.1
- 能访问 `https://api.64clouds.com`

## 安装

1. 下载并解压项目。
2. 右键 `install.ps1`，选择“使用 PowerShell 运行”。
3. 首次打开时填写：
   - 显示名称：例如 `洛杉矶 VPS`
   - VEID：KiwiVM API 页面显示的数字 ID
   - API Key：通常以 `private_` 开头

如果执行策略阻止脚本，可在项目目录运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
```

## 切换或更换设备

- 使用主窗口顶部下拉框切换已保存设备。
- 点击“设备”：
  - 选择“是”编辑当前设备。
  - 选择“否”添加另一台设备。

## 数据与隐私

配置保存在：

```text
%APPDATA%\BandwagonHostMonitor\config.json
```

API Key 使用 Windows 当前用户的 DPAPI 加密。项目仓库不包含任何真实 VEID、API Key、缓存或日志。请勿把自己的配置文件提交到 GitHub。

KiwiVM API Key 可能具有服务器控制权限，请像密码一样保护。如果误发到公开位置，请立即在 KiwiVM 中重新生成。

## 卸载

运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1
```

卸载脚本只移除开机启动项，不会自动删除配置。若要彻底清除，可手动删除 `%APPDATA%\BandwagonHostMonitor`。

## License

MIT
