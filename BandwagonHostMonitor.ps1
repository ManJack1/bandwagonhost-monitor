$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSHOME 'Modules\Microsoft.PowerShell.Security\Microsoft.PowerShell.Security.psd1') -Force
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$appName = 'BandwagonHostMonitor'
$dataDir = Join-Path $env:APPDATA $appName
$configPath = Join-Path $dataDir 'config.json'
$positionPath = Join-Path $dataDir 'window-position.json'
$logPath = Join-Path $dataDir 'error.log'
New-Item -ItemType Directory -Force -Path $dataDir | Out-Null

$createdNew = $false
$mutex = New-Object System.Threading.Mutex($true, 'BandwagonHostMonitor_MainWindow', [ref]$createdNew)
if (-not $createdNew) { return }

function Read-Config {
    if (-not (Test-Path -LiteralPath $configPath)) {
        return [pscustomobject]@{ activeId = $null; devices = @() }
    }
    try {
        $config = Get-Content -Raw -LiteralPath $configPath | ConvertFrom-Json
        if ($null -eq $config.devices) { $config | Add-Member devices @() -Force }
        return $config
    }
    catch {
        return [pscustomobject]@{ activeId = $null; devices = @() }
    }
}

function Save-Config($config) {
    $config | ConvertTo-Json -Depth 8 | Set-Content -Encoding UTF8 -LiteralPath $configPath
}

function Protect-ApiKey([string]$plainText) {
    $secure = ConvertTo-SecureString -String $plainText -AsPlainText -Force
    return ($secure | ConvertFrom-SecureString)
}

function Unprotect-ApiKey([string]$cipherText) {
    $secure = $cipherText | ConvertTo-SecureString
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
    finally { if ($ptr -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) } }
}

function Show-DeviceEditor($owner, $existing) {
    [xml]$editorXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        Title="搬瓦工监控配置" Width="430" Height="330" WindowStartupLocation="CenterOwner"
        ResizeMode="NoResize" Background="#F7FAFB">
  <Grid Margin="22">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>
    <TextBlock Grid.Row="0" Text="添加或编辑 VPS" FontSize="20" FontWeight="Bold" Foreground="#17343A" Margin="0,0,0,16"/>
    <TextBlock Grid.Row="1" Text="显示名称" Foreground="#4B6267"/>
    <TextBox x:Name="NameBox" Grid.Row="2" Height="34" Margin="0,5,0,12" Padding="8,5"/>
    <Grid Grid.Row="3">
      <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="14"/><ColumnDefinition/></Grid.ColumnDefinitions>
      <StackPanel Grid.Column="0"><TextBlock Text="VEID" Foreground="#4B6267"/><TextBox x:Name="VeidBox" Height="34" Margin="0,5,0,0" Padding="8,5"/></StackPanel>
      <StackPanel Grid.Column="2"><TextBlock Text="API Key" Foreground="#4B6267"/><PasswordBox x:Name="ApiBox" Height="34" Margin="0,5,0,0" Padding="8,5"/></StackPanel>
    </Grid>
    <TextBlock Grid.Row="4" Text="API Key 使用 Windows 当前账户加密，仅保存在本机。编辑时留空可保留原 Key。"
               TextWrapping="Wrap" FontSize="11" Foreground="#6B7D81" Margin="0,12,0,0"/>
    <TextBlock x:Name="ErrorText" Grid.Row="5" Foreground="#D34F5A" Margin="0,10,0,0" TextWrapping="Wrap"/>
    <StackPanel Grid.Row="6" Orientation="Horizontal" HorizontalAlignment="Right">
      <Button x:Name="CancelButton" Content="取消" Width="82" Height="34" Margin="0,0,10,0"/>
      <Button x:Name="SaveButton" Content="保存" Width="82" Height="34" Background="#4CC6D4" Foreground="White" BorderThickness="0"/>
    </StackPanel>
  </Grid>
</Window>
'@
    $reader = New-Object System.Xml.XmlNodeReader $editorXaml
    $dialog = [Windows.Markup.XamlReader]::Load($reader)
    $dialog.Owner = $owner
    $nameBox = $dialog.FindName('NameBox'); $veidBox = $dialog.FindName('VeidBox'); $apiBox = $dialog.FindName('ApiBox')
    $errorText = $dialog.FindName('ErrorText'); $saveButton = $dialog.FindName('SaveButton'); $cancelButton = $dialog.FindName('CancelButton')
    if ($existing) { $nameBox.Text = $existing.name; $veidBox.Text = $existing.veid }
    $result = $null
    $cancelButton.Add_Click({ $dialog.DialogResult = $false })
    $saveButton.Add_Click({
        $name = $nameBox.Text.Trim(); $veid = $veidBox.Text.Trim(); $api = $apiBox.Password.Trim()
        if ([string]::IsNullOrWhiteSpace($name)) { $errorText.Text = '请输入显示名称。'; return }
        if ($veid -notmatch '^\d+$') { $errorText.Text = 'VEID 应为数字。'; return }
        if (-not $existing -and [string]::IsNullOrWhiteSpace($api)) { $errorText.Text = '请输入 API Key。'; return }
        if ($api -and $api -notmatch '^private_') { $errorText.Text = 'API Key 通常以 private_ 开头，请检查。'; return }
        $cipher = if ($api) { Protect-ApiKey $api } else { $existing.apiKey }
        $id = if ($existing) { $existing.id } else { [guid]::NewGuid().ToString('N') }
        $script:editorResult = [pscustomobject]@{ id = $id; name = $name; veid = $veid; apiKey = $cipher }
        $dialog.DialogResult = $true
    })
    if ($dialog.ShowDialog()) { $result = $script:editorResult; $script:editorResult = $null }
    return $result
}

[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        Title="BandwagonHost Monitor" Width="270" Height="330" WindowStyle="None"
        AllowsTransparency="True" Background="Transparent" ResizeMode="NoResize"
        ShowInTaskbar="True" Topmost="True">
  <Border x:Name="Card" Margin="9" CornerRadius="24" Background="#F7FFFFFF" BorderBrush="#33087E8B" BorderThickness="1">
    <Border.Effect><DropShadowEffect Color="#55000000" BlurRadius="18" ShadowDepth="4" Opacity="0.5"/></Border.Effect>
    <Grid Margin="16,13,16,15">
      <Grid.RowDefinitions>
        <RowDefinition Height="34"/><RowDefinition Height="68"/><RowDefinition Height="32"/>
        <RowDefinition Height="22"/><RowDefinition Height="24"/><RowDefinition Height="22"/>
        <RowDefinition Height="22"/><RowDefinition Height="*"/>
      </Grid.RowDefinitions>
      <ComboBox x:Name="DeviceBox" Grid.Row="0" Height="28" VerticalAlignment="Top" DisplayMemberPath="name" SelectedValuePath="id"/>
      <Image x:Name="BrandLogo" Grid.Row="1" Width="180" Height="48" Stretch="Uniform"/>
      <TextBlock x:Name="StatusText" Grid.Row="2" Text="等待配置" TextAlignment="Center" FontWeight="SemiBold" Foreground="#4CC6D4"/>
      <TextBlock x:Name="PercentText" Grid.Row="3" Text="--%" FontSize="20" FontWeight="Bold" TextAlignment="Center" Foreground="#17343A"/>
      <ProgressBar x:Name="UsageBar" Grid.Row="4" Height="9" Minimum="0" Maximum="100" Foreground="#4CC6D4" Background="#1A17343A" BorderThickness="0"/>
      <TextBlock x:Name="RemainingText" Grid.Row="5" Text="剩余 -- GB" TextAlignment="Center" FontSize="12" Foreground="#4B6267"/>
      <TextBlock x:Name="ResetText" Grid.Row="6" Text="下次重置：---- -- --" TextAlignment="Center" FontSize="11" Foreground="#6B7D81"/>
      <StackPanel Grid.Row="7" Orientation="Horizontal" HorizontalAlignment="Center" Margin="0,9,0,0">
        <Button x:Name="RefreshButton" Content="刷新" Width="64" Height="28" Margin="0,0,8,0"/>
        <Button x:Name="ManageButton" Content="设备" Width="64" Height="28" Margin="0,0,8,0"/>
        <Button x:Name="CloseButton" Content="关闭" Width="64" Height="28"/>
      </StackPanel>
    </Grid>
  </Border>
</Window>
'@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)
$card = $window.FindName('Card'); $deviceBox = $window.FindName('DeviceBox'); $brandLogo = $window.FindName('BrandLogo')
$statusText = $window.FindName('StatusText'); $percentText = $window.FindName('PercentText'); $usageBar = $window.FindName('UsageBar')
$remainingText = $window.FindName('RemainingText'); $resetText = $window.FindName('ResetText')
$refreshButton = $window.FindName('RefreshButton'); $manageButton = $window.FindName('ManageButton'); $closeButton = $window.FindName('CloseButton')

$logoPath = Join-Path $PSScriptRoot 'assets\bandwagonhost-logo.png'
if (Test-Path -LiteralPath $logoPath) {
    $bitmap = New-Object Windows.Media.Imaging.BitmapImage
    $bitmap.BeginInit(); $bitmap.CacheOption = [Windows.Media.Imaging.BitmapCacheOption]::OnLoad; $bitmap.UriSource = [Uri]::new($logoPath); $bitmap.EndInit(); $bitmap.Freeze()
    $brandLogo.Source = $bitmap
}

$workArea = [System.Windows.SystemParameters]::WorkArea
$window.Left = $workArea.Right - $window.Width - 24; $window.Top = $workArea.Bottom - $window.Height - 24
if (Test-Path -LiteralPath $positionPath) {
    try { $pos = Get-Content -Raw $positionPath | ConvertFrom-Json; $window.Left = [double]$pos.left; $window.Top = [double]$pos.top } catch { }
}

$script:config = Read-Config
$script:suppressSelection = $false

function Refresh-DeviceList {
    $script:suppressSelection = $true
    $deviceBox.ItemsSource = $null
    $deviceBox.ItemsSource = @($script:config.devices)
    if ($script:config.activeId) { $deviceBox.SelectedValue = $script:config.activeId }
    if ($deviceBox.SelectedIndex -lt 0 -and $deviceBox.Items.Count -gt 0) { $deviceBox.SelectedIndex = 0 }
    $script:suppressSelection = $false
}

function Get-ActiveDevice {
    if ($deviceBox.SelectedItem) { return $deviceBox.SelectedItem }
    return $null
}

function Set-Mood([double]$percent) {
    if ($percent -ge 98) { $color='#F05A67'; $label='流量危险！' }
    elseif ($percent -ge 95) { $color='#F28C45'; $label='快没流量啦' }
    elseif ($percent -ge 90) { $color='#F2B84B'; $label='需要注意' }
    elseif ($percent -ge 85) { $color='#8BCB68'; $label='开始节省' }
    else { $color='#4CC6D4'; $label='状态良好' }
    $converter = New-Object Windows.Media.BrushConverter
    $usageBar.Foreground = $converter.ConvertFromString($color); $statusText.Foreground = $converter.ConvertFromString($color); $statusText.Text = $label
}

function Update-Monitor {
    $device = Get-ActiveDevice
    if (-not $device) { $statusText.Text='请添加设备'; $percentText.Text='--%'; $usageBar.Value=0; return }
    $refreshButton.IsEnabled = $false; $statusText.Text = '正在刷新…'
    try {
        $apiKey = Unprotect-ApiKey $device.apiKey
        try {
            $response = Invoke-RestMethod -Method Post -TimeoutSec 15 -Uri 'https://api.64clouds.com/v1/getServiceInfo' -Body @{ veid=$device.veid; api_key=$apiKey }
        }
        finally { $apiKey = $null }
        if ([int]$response.error -ne 0) { throw "KiwiVM API：$($response.message)" }
        $multiplier=[double]$response.monthly_data_multiplier; if ($multiplier -le 0) { $multiplier=1 }
        $used=[double]$response.data_counter*$multiplier; $limit=[double]$response.plan_monthly_data*$multiplier
        $remaining=[Math]::Max(0,$limit-$used); $percent=if($limit -gt 0){$used/$limit*100}else{0}
        $reset=[DateTimeOffset]::FromUnixTimeSeconds([long]$response.data_next_reset).ToLocalTime()
        $percentText.Text=('{0:N2}%' -f $percent); $usageBar.Value=[Math]::Min(100,$percent)
        $remainingText.Text=('剩余 {0:N2} GB' -f ($remaining/1GB)); $resetText.Text=('下次重置：{0:yyyy-MM-dd}' -f $reset)
        $card.ToolTip=('设备：{0}`n已用 {1:N2} / {2:N2} GB`n更新：{3:HH:mm:ss}' -f $device.name,($used/1GB),($limit/1GB),(Get-Date))
        Set-Mood $percent
    }
    catch {
        $statusText.Text='连接失败'; $card.ToolTip=$_.Exception.Message
        ('{0:o} {1}' -f [DateTimeOffset]::Now,$_.Exception.Message) | Set-Content -Encoding UTF8 -LiteralPath $logPath
    }
    finally { $refreshButton.IsEnabled = $true }
}

function Manage-Devices {
    $choice = [System.Windows.MessageBox]::Show("选择“是”编辑当前设备，选择“否”添加新设备。",'设备管理','YesNoCancel','Question')
    if ($choice -eq 'Cancel') { return }
    $existing = if ($choice -eq 'Yes') { Get-ActiveDevice } else { $null }
    $edited = Show-DeviceEditor $window $existing
    if (-not $edited) { return }
    $devices = [System.Collections.ArrayList]@($script:config.devices)
    if ($existing) {
        for ($i=0; $i -lt $devices.Count; $i++) { if ($devices[$i].id -eq $edited.id) { $devices[$i]=$edited; break } }
    } else { [void]$devices.Add($edited) }
    $script:config = [pscustomobject]@{ activeId=$edited.id; devices=@($devices) }
    Save-Config $script:config; Refresh-DeviceList; Update-Monitor
}

$card.Add_MouseLeftButtonDown({ if ($_.ClickCount -eq 1) { try { $window.DragMove() } catch { } } })
$refreshButton.Add_Click({ Update-Monitor })
$manageButton.Add_Click({ Manage-Devices })
$closeButton.Add_Click({ $window.Close() })
$deviceBox.Add_SelectionChanged({
    if (-not $script:suppressSelection -and $deviceBox.SelectedItem) {
        $script:config.activeId = $deviceBox.SelectedItem.id; Save-Config $script:config; Update-Monitor
    }
})
$window.Add_Closing({ [pscustomobject]@{left=$window.Left;top=$window.Top}|ConvertTo-Json|Set-Content -Encoding UTF8 -LiteralPath $positionPath })

$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMinutes(30); $timer.Add_Tick({ Update-Monitor }); $timer.Start()
$window.Add_ContentRendered({
    Refresh-DeviceList
    if ($deviceBox.Items.Count -eq 0) { Manage-Devices } else { Update-Monitor }
})
[void]$window.ShowDialog()
$timer.Stop(); if ($createdNew) { $mutex.ReleaseMutex() }; $mutex.Dispose()
