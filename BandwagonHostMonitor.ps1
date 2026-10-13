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
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
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

function Show-ManageChoice($owner) {
    [xml]$choiceXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="设备管理" Width="360" Height="205" WindowStartupLocation="CenterOwner"
        ResizeMode="NoResize" WindowStyle="None" AllowsTransparency="True" Background="Transparent">
  <Border CornerRadius="20" Background="#FCFFFFFF" BorderBrush="#334CC6D4" BorderThickness="1" Padding="24">
    <Border.Effect><DropShadowEffect Color="#44000000" BlurRadius="22" ShadowDepth="5"/></Border.Effect>
    <Grid>
      <Grid.RowDefinitions><RowDefinition/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
      <TextBlock Text="管理监控设备" FontSize="19" FontWeight="Bold" Foreground="#17343A"/>
      <TextBlock Grid.Row="1" Text="编辑当前设备，或添加另一台搬瓦工 VPS。" Foreground="#65777B" Margin="0,8,0,20"/>
      <StackPanel Grid.Row="2" Orientation="Horizontal" HorizontalAlignment="Right">
        <Button x:Name="Cancel" Content="取消" Width="76" Height="34" Margin="0,0,8,0" Background="#EEF3F4" BorderThickness="0"/>
        <Button x:Name="Edit" Content="编辑当前" Width="90" Height="34" Margin="0,0,8,0" Background="#DDF4F6" Foreground="#23666D" BorderThickness="0"/>
        <Button x:Name="Add" Content="添加设备" Width="90" Height="34" Background="#4CC6D4" Foreground="White" BorderThickness="0"/>
      </StackPanel>
    </Grid>
  </Border>
</Window>
'@
    $reader = New-Object System.Xml.XmlNodeReader $choiceXaml
    $dialog = [Windows.Markup.XamlReader]::Load($reader); $dialog.Owner = $owner
    $result = $null
    $dialog.FindName('Cancel').Add_Click({ $dialog.DialogResult = $false })
    $dialog.FindName('Edit').Add_Click({ $script:manageChoice = 'edit'; $dialog.DialogResult = $true })
    $dialog.FindName('Add').Add_Click({ $script:manageChoice = 'add'; $dialog.DialogResult = $true })
    if ($dialog.ShowDialog()) { $result = $script:manageChoice; $script:manageChoice = $null }
    return $result
}

[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="BandwagonHost Monitor" Width="270" Height="330" WindowStyle="None"
        AllowsTransparency="True" Background="Transparent" ResizeMode="NoResize"
        ShowInTaskbar="True" Topmost="True">
  <Window.Resources>
    <Style x:Key="DeviceItem" TargetType="ComboBoxItem">
      <Setter Property="Padding" Value="12,8"/>
      <Setter Property="Foreground" Value="#E5ECEE"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBoxItem">
            <Border x:Name="ItemBorder" Margin="4,2" Padding="{TemplateBinding Padding}" CornerRadius="9" Background="{TemplateBinding Background}">
              <ContentPresenter/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsHighlighted" Value="True"><Setter TargetName="ItemBorder" Property="Background" Value="#39444A"/></Trigger>
              <Trigger Property="IsSelected" Value="True"><Setter TargetName="ItemBorder" Property="Background" Value="#28545B"/><Setter Property="FontWeight" Value="SemiBold"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="DevicePicker" TargetType="ComboBox">
      <Setter Property="Foreground" Value="#E5ECEE"/>
      <Setter Property="Background" Value="#292F34"/>
      <Setter Property="BorderBrush" Value="#536268"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="12,0"/>
      <Setter Property="ItemContainerStyle" Value="{StaticResource DeviceItem}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBox">
            <Grid>
              <ToggleButton x:Name="PickerButton" Focusable="False" ClickMode="Press"
                            IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}">
                <ToggleButton.Template>
                  <ControlTemplate TargetType="ToggleButton">
                    <Border x:Name="PickerBorder" CornerRadius="12"
                            Background="{Binding Background, RelativeSource={RelativeSource AncestorType=ComboBox}}"
                            BorderBrush="{Binding BorderBrush, RelativeSource={RelativeSource AncestorType=ComboBox}}"
                            BorderThickness="{Binding BorderThickness, RelativeSource={RelativeSource AncestorType=ComboBox}}">
                      <Grid Margin="12,0,10,0">
                        <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="24"/></Grid.ColumnDefinitions>
                        <TextBlock Grid.Column="0" VerticalAlignment="Center" TextTrimming="CharacterEllipsis"
                                   Foreground="{Binding Foreground, RelativeSource={RelativeSource AncestorType=ComboBox}}"
                                   Text="{Binding SelectedItem.name, RelativeSource={RelativeSource AncestorType=ComboBox}}"/>
                        <Path Grid.Column="1" Width="9" Height="5" HorizontalAlignment="Right" VerticalAlignment="Center"
                              Fill="#80CBD2" Data="M 0 0 L 4.5 5 L 9 0 Z"/>
                      </Grid>
                    </Border>
                    <ControlTemplate.Triggers>
                      <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="PickerBorder" Property="Background" Value="#343D42"/></Trigger>
                      <Trigger Property="IsChecked" Value="True"><Setter TargetName="PickerBorder" Property="BorderBrush" Value="#4CC6D4"/><Setter TargetName="PickerBorder" Property="Background" Value="#303A3F"/></Trigger>
                    </ControlTemplate.Triggers>
                  </ControlTemplate>
                </ToggleButton.Template>
              </ToggleButton>
              <Popup x:Name="PART_Popup" IsOpen="{TemplateBinding IsDropDownOpen}" Placement="Bottom" AllowsTransparency="True" PopupAnimation="Fade" Focusable="False">
                <Border Width="220" Margin="0,6,0,0" Padding="4" CornerRadius="13" Background="#F52A3035" BorderBrush="#664CC6D4" BorderThickness="1">
                  <Border.Effect><DropShadowEffect Color="#33000000" BlurRadius="16" ShadowDepth="3"/></Border.Effect>
                  <ScrollViewer MaxHeight="220" VerticalScrollBarVisibility="Auto"><ItemsPresenter/></ScrollViewer>
                </Border>
              </Popup>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="RoundAction" TargetType="Button">
      <Setter Property="Width" Value="38"/><Setter Property="Height" Value="38"/>
      <Setter Property="Margin" Value="5,0"/><Setter Property="FontSize" Value="18"/>
      <Setter Property="Foreground" Value="#BFDDE0"/><Setter Property="Background" Value="#293238"/>
      <Setter Property="BorderBrush" Value="#3D5960"/><Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Chrome" CornerRadius="19" Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" Margin="0,-2,0,0"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Chrome" Property="Background" Value="#35525A"/><Setter Property="Foreground" Value="#75E0E9"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="Chrome" Property="Background" Value="#28464D"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.45"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="CloseAction" TargetType="Button" BasedOn="{StaticResource RoundAction}">
      <Setter Property="Foreground" Value="#F19AA2"/><Setter Property="Background" Value="#3A292D"/><Setter Property="BorderBrush" Value="#665E3C43"/>
    </Style>
  </Window.Resources>
  <Border x:Name="Card" Margin="9" CornerRadius="24" Background="#F21B1F24" BorderBrush="#66536168" BorderThickness="1">
    <Border.Effect><DropShadowEffect Color="#55000000" BlurRadius="18" ShadowDepth="4" Opacity="0.5"/></Border.Effect>
    <Grid Margin="16,13,16,15">
      <Grid.RowDefinitions>
        <RowDefinition Height="34"/><RowDefinition Height="68"/><RowDefinition Height="32"/>
        <RowDefinition Height="22"/><RowDefinition Height="24"/><RowDefinition Height="22"/>
        <RowDefinition Height="22"/><RowDefinition Height="*"/>
      </Grid.RowDefinitions>
      <ComboBox x:Name="DeviceBox" Grid.Row="0" Height="32" VerticalAlignment="Top" DisplayMemberPath="name" SelectedValuePath="id"
                Style="{StaticResource DevicePicker}"/>
      <Image x:Name="BrandLogo" Grid.Row="1" Width="180" Height="48" Stretch="Uniform"/>
      <TextBlock x:Name="StatusText" Grid.Row="2" Text="等待配置" TextAlignment="Center" FontWeight="SemiBold" Foreground="#4CC6D4"/>
      <TextBlock x:Name="PercentText" Grid.Row="3" Text="--%" FontSize="20" FontWeight="Bold" TextAlignment="Center" Foreground="#F1F5F6"/>
      <ProgressBar x:Name="UsageBar" Grid.Row="4" Height="9" Minimum="0" Maximum="100" Foreground="#4CC6D4" Background="#344047" BorderThickness="0"/>
      <TextBlock x:Name="RemainingText" Grid.Row="5" Text="剩余 -- GB" TextAlignment="Center" FontSize="12" Foreground="#C2CDD0"/>
      <TextBlock x:Name="ResetText" Grid.Row="6" Text="下次重置：---- -- --" TextAlignment="Center" FontSize="11" Foreground="#8F9FA3"/>
      <StackPanel Grid.Row="7" Orientation="Horizontal" HorizontalAlignment="Center" Margin="0,9,0,0">
        <Button x:Name="RefreshButton" Content="↻" Style="{StaticResource RoundAction}" ToolTip="立即刷新"/>
        <Button x:Name="ManageButton" Content="⚙" Style="{StaticResource RoundAction}" ToolTip="管理设备"/>
        <Button x:Name="CloseButton" Content="×" Style="{StaticResource CloseAction}" ToolTip="关闭"/>
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
        $remaining=[Math]::Max([double]0,[double]($limit-$used)); $percent=if($limit -gt 0){$used/$limit*100}else{0}
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
    $choice = Show-ManageChoice $window
    if (-not $choice) { return }
    $existing = if ($choice -eq 'edit') { Get-ActiveDevice } else { $null }
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
