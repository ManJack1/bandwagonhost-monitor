$ErrorActionPreference = 'Stop'
$startup = [Environment]::GetFolderPath('Startup')
$link = Join-Path $startup 'BandwagonHost Monitor.lnk'
$launcher = Join-Path $PSScriptRoot 'launch.vbs'
$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($link)
$shortcut.TargetPath = "$env:WINDIR\System32\wscript.exe"
$shortcut.Arguments = '"' + $launcher + '"'
$shortcut.WorkingDirectory = $PSScriptRoot
$shortcut.Description = 'BandwagonHost KiwiVM bandwidth monitor'
$shortcut.Save()
Start-Process -FilePath $launcher
Write-Host '安装完成：已启动并添加到当前用户开机启动。' -ForegroundColor Green
