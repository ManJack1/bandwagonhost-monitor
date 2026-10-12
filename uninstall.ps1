$startup = [Environment]::GetFolderPath('Startup')
$link = Join-Path $startup 'BandwagonHost Monitor.lnk'
if (Test-Path -LiteralPath $link) { Remove-Item -LiteralPath $link -Force }
Write-Host '已移除开机启动。配置仍保留在 %APPDATA%\BandwagonHostMonitor。' -ForegroundColor Yellow
