param(
    [ValidateSet('Splash', 'Companion', 'Validate', 'Preview', 'CompanionPreview')]
    [string]$Mode = 'Splash'
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
. (Join-Path $PSScriptRoot 'Launcher.ps1')
Initialize-XingliLauncher
$sceneAssembly = Join-Path $PSScriptRoot 'Scene.Ultra.dll'
if (-not (Test-Path -LiteralPath $sceneAssembly)) { $sceneAssembly = Join-Path $PSScriptRoot 'Scene.Motion.Visible.dll' }
if (-not (Test-Path -LiteralPath $sceneAssembly)) { $sceneAssembly = Join-Path $PSScriptRoot 'Scene.Motion.dll' }
if (-not (Test-Path -LiteralPath $sceneAssembly)) { $sceneAssembly = Join-Path $PSScriptRoot 'Scene.QHD.dll' }
if (-not (Test-Path -LiteralPath $sceneAssembly)) { $sceneAssembly = Join-Path $PSScriptRoot 'Scene.dll' }
if (Test-Path -LiteralPath $sceneAssembly) { Add-Type -Path $sceneAssembly }
else {
    Add-Type -Path @((Join-Path $PSScriptRoot 'Scene.cs'),(Join-Path $PSScriptRoot 'CharacterMotion.cs')) -ReferencedAssemblies @(
        'System.dll','System.Core.dll','System.Xaml.dll',
        [Windows.Window].Assembly.Location,
        [Windows.Media.DrawingContext].Assembly.Location,
        [Windows.Point].Assembly.Location
    )
}
$portraitPath = Join-Path $PSScriptRoot 'xingli-portrait.png'
$portraitShyPath = Join-Path $PSScriptRoot 'xingli-portrait-shy.png'
$script:scriptFile = $MyInvocation.MyCommand.Path
$script:companionLaunch = $null
function Open-ChatGPT {
    if ($script:companionLaunch) {
        $snapshot = Get-XingliAppState $script:companionLaunch
        if ($snapshot.Phase -notin @('Ready','Failed','Cancelled')) { return }
        [void](Complete-XingliAppMonitor $script:companionLaunch)
    }
    $script:companionLaunch = Start-XingliApp
}
function Read-Xaml([string]$markup) {
    $xml = [xml]$markup
    $reader = [System.Xml.XmlNodeReader]::new($xml)
    return [Windows.Markup.XamlReader]::Load($reader)
}

function Set-ImageSource($control, [string]$path) {
    $bitmap = [Windows.Media.Imaging.BitmapImage]::new()
    $bitmap.BeginInit()
    $bitmap.CacheOption = [Windows.Media.Imaging.BitmapCacheOption]::OnLoad
    $bitmap.UriSource = [Uri]::new($path, [UriKind]::Absolute)
    $bitmap.EndInit()
    $control.Source = $bitmap
}

function Start-OpacityAnimation($control, [double]$from, [double]$to, [double]$begin, [double]$duration) {
    $animation = [Windows.Media.Animation.DoubleAnimation]::new($from, $to, [TimeSpan]::FromSeconds($duration))
    $animation.BeginTime = [TimeSpan]::FromSeconds($begin)
    $animation.FillBehavior = [Windows.Media.Animation.FillBehavior]::HoldEnd
    $control.BeginAnimation([Windows.UIElement]::OpacityProperty, $animation)
}


function New-Splash {
    $window = [Windows.Window]::new()
    $window.Title = 'Xingli · Codex startup'
    $window.Width = 1080; $window.Height = 608
    $window.WindowStyle = [Windows.WindowStyle]::None
    $window.ResizeMode = [Windows.ResizeMode]::NoResize
    $window.Background = [Windows.Media.Brushes]::Black
    $window.ShowInTaskbar = $false
    $window.WindowStartupLocation = [Windows.WindowStartupLocation]::CenterScreen
    $window.Topmost = $true
    # Opaque WPF window preserves normal GPU composition. No layered-window surface.
    $window.AllowsTransparency = $false
    $grid = [Windows.Controls.Grid]::new()
    $scene = [XingliScene]::new($PSScriptRoot)
    [void]$grid.Children.Add($scene)
    $video = $null
    $videoPath = Join-Path $PSScriptRoot 'preview-startup.mp4'
    if (Test-Path -LiteralPath $videoPath) {
        $video = [Windows.Controls.MediaElement]::new()
        $video.LoadedBehavior = [Windows.Controls.MediaState]::Manual
        $video.UnloadedBehavior = [Windows.Controls.MediaState]::Close
        $video.Stretch = [Windows.Media.Stretch]::Fill
        [Windows.Media.RenderOptions]::SetBitmapScalingMode($video,[Windows.Media.BitmapScalingMode]::HighQuality)
        $video.IsMuted = $true
        $video.IsHitTestVisible = $false
        $video.Source = [Uri]::new($videoPath,[UriKind]::Absolute)
        $scene.Visibility = [Windows.Visibility]::Collapsed
        [void]$grid.Children.Add($video)
    }
    $waitPanel = [Windows.Controls.Border]::new()
    $waitPanel.Background = [Windows.Media.BrushConverter]::new().ConvertFromString('#F2010408')
    $waitPanel.Width = 414; $waitPanel.Height = 108
    $waitPanel.HorizontalAlignment = [Windows.HorizontalAlignment]::Left
    $waitPanel.VerticalAlignment = [Windows.VerticalAlignment]::Top
    $waitPanel.Margin = [Windows.Thickness]::new(57,425,0,0)
    $waitPanel.Visibility = [Windows.Visibility]::Collapsed
    $waitText = [Windows.Controls.TextBlock]::new()
    $waitText.Foreground = [Windows.Media.Brushes]::White
    $waitText.FontSize = 12
    $waitText.Margin = [Windows.Thickness]::new(9,6,0,0)
    $waitPanel.Child = $waitText
    [void]$grid.Children.Add($waitPanel)
    $retry = [Windows.Controls.Button]::new()
    $retry.Content = '重新打开 Codex'
    $retry.Width = 170; $retry.Height = 34
    $retry.HorizontalAlignment = [Windows.HorizontalAlignment]::Left
    $retry.VerticalAlignment = [Windows.VerticalAlignment]::Top
    $retry.Margin = [Windows.Thickness]::new(66,480,0,0)
    $retry.Background = [Windows.Media.BrushConverter]::new().ConvertFromString('#DD101A25')
    $retry.Foreground = [Windows.Media.Brushes]::White
    $retry.BorderBrush = [Windows.Media.BrushConverter]::new().ConvertFromString('#AACFDFEA')
    $retry.Visibility = [Windows.Visibility]::Collapsed
    [void]$grid.Children.Add($retry)
    $window.Content = $grid
    $window.Tag = @{ Scene = $scene; Retry = $retry; Video = $video; WaitPanel = $waitPanel; WaitText = $waitText }
    return $window
}
function New-Companion {
    $markup = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="320" Height="365" WindowStyle="None" ResizeMode="NoResize"
        AllowsTransparency="True" Background="Transparent" ShowInTaskbar="False" Topmost="True">
  <Grid Background="Transparent">
    <Grid x:Name="PortraitLayer" Margin="0,0,0,24" RenderTransformOrigin="0.5,0.7">
      <Image x:Name="Portrait" Stretch="Uniform" />
      <Image x:Name="ShyPortrait" Stretch="Uniform" Opacity="0" IsHitTestVisible="False">
        <Image.OpacityMask>
          <RadialGradientBrush Center="0.5,0.26" GradientOrigin="0.5,0.26" RadiusX="0.23" RadiusY="0.20">
            <GradientStop Color="#FFFFFFFF" Offset="0" />
            <GradientStop Color="#FFFFFFFF" Offset="0.52" />
            <GradientStop Color="#00FFFFFF" Offset="1" />
          </RadialGradientBrush>
        </Image.OpacityMask>
      </Image>
      <Canvas x:Name="BlushLayer" Opacity="0" IsHitTestVisible="False">
        <Ellipse Canvas.Left="130" Canvas.Top="87" Width="25" Height="11" Fill="#A8FF87A9">
          <Ellipse.Effect><BlurEffect Radius="6" /></Ellipse.Effect>
        </Ellipse>
        <Ellipse Canvas.Left="172" Canvas.Top="85" Width="25" Height="11" Fill="#A8FF87A9">
          <Ellipse.Effect><BlurEffect Radius="6" /></Ellipse.Effect>
        </Ellipse>
      </Canvas>
    </Grid>
    <Border VerticalAlignment="Bottom" HorizontalAlignment="Center" CornerRadius="12"
            Background="#D9090A17" BorderBrush="#A9C7A9E5" BorderThickness="1"
            Padding="14,7" Margin="0,0,0,4">
      <TextBlock x:Name="Bubble" Text="XINGLI  /  READY" Foreground="#E8DEFA"
                 FontFamily="Consolas" FontSize="11" />
    </Border>
  </Grid>
</Window>
'@
    $window = Read-Xaml $markup
    Set-ImageSource ($window.FindName('Portrait')) $portraitPath
    Set-ImageSource ($window.FindName('ShyPortrait')) $portraitShyPath
    return $window
}

foreach ($name in @('xingli-closed.jpg','eye-atlas.png')) {
    $asset = Join-Path $PSScriptRoot $name
    if (-not (Test-Path -LiteralPath $asset)) { throw "Missing asset: $asset" }
}
if (-not (Test-Path -LiteralPath $portraitPath)) { throw "Missing asset: $portraitPath" }
if (-not (Test-Path -LiteralPath $portraitShyPath)) { throw "Missing asset: $portraitShyPath" }


if ($Mode -eq 'Validate') {
    $probe = New-Splash
    $pet = New-Companion
    $probe.Tag.Scene.SaveFrame(3.50,(Join-Path $PSScriptRoot 'preview-opening.png'),1080,608,$false)
    Write-Output 'Continuous scene, eye atlas, companion and launcher loaded successfully.'
    return
}

if ($Mode -eq 'Splash' -or $Mode -eq 'Preview') {
    $created = $false
    $splashMutexName = if ($Mode -eq 'Preview') { 'Local\XingliSplashPreview' } else { 'Local\XingliSplash' }
    $splashMutex = [Threading.Mutex]::new($true,$splashMutexName,[ref]$created)
    if (-not $created) { $splashMutex.Dispose(); return }
    $window = New-Splash
    $scene = $window.Tag.Scene
    $retry = $window.Tag.Retry
    $video = $window.Tag.Video
    $state = @{ Launch = $null; FadeStarted = $false; FadeAt = 0.0; Ready = $false; Skip = $false;
        VideoOpened = $false; VideoDuration = 0.0; VideoFailed = $false; AnimationDone = $false; MediaError = '' }
    $watch = [Diagnostics.Stopwatch]::new()
    $timer = [Windows.Threading.DispatcherTimer]::new()
    $timer.Interval = [TimeSpan]::FromMilliseconds(120)
    $retry.Add_Click({
        if ($state.Launch) { [void](Complete-XingliAppMonitor $state.Launch) }
        $state.Launch = Start-XingliApp -OfficialOnly
        $scene.LaunchStatus = 'OPENING CODEX...'
        $window.Tag.WaitText.Text = '正在打开 Codex，请稍候…'
        $retry.Visibility = [Windows.Visibility]::Collapsed
    })
    if ($video) {
        $video.Add_MediaOpened({
            if (-not $state.VideoOpened) {
                $state.VideoOpened = $true
                if ($video.NaturalDuration.HasTimeSpan) { $state.VideoDuration = $video.NaturalDuration.TimeSpan.TotalSeconds }
                $watch.Restart()
            }
        })
        $video.Add_MediaEnded({
            $state.AnimationDone = $true
            if ($Mode -eq 'Preview') { $window.Close(); return }
            if (-not $state.Ready) {
                # Keep the settled portrait alive during a slow app launch.
                $video.Position = [TimeSpan]::FromSeconds(4.2)
                $video.Play()
            }
        })
        $video.Add_MediaFailed({
            $state.VideoFailed = $true
            $state.MediaError = $_.ErrorException.Message
            $video.Visibility = [Windows.Visibility]::Collapsed
            $video.Close()
            $scene.Visibility = [Windows.Visibility]::Visible
            $scene.Start(); $watch.Restart()
        })
    }
    $timer.Add_Tick({
        $t = $watch.Elapsed.TotalSeconds
        if ($Mode -eq 'Preview') {
            if ((-not $video -or $state.VideoFailed) -and $t -ge [XingliScene]::BootDuration) { $window.Close() }
            return
        }
        if (-not $state.Launch) { return }
        $snapshot = Get-XingliAppState $state.Launch
        $state.Ready = $snapshot.Phase -eq 'Ready'
        $scene.AppReady = $state.Ready
        [void](Complete-XingliAppMonitor $state.Launch)
        if ($state.Ready -and $t -ge 6.90 -and -not $state.FadeStarted) {
            $state.FadeStarted = $true
            $state.FadeAt = $t
            $fade = [Windows.Media.Animation.DoubleAnimation]::new(1,0,[TimeSpan]::FromSeconds(.30))
            $window.BeginAnimation([Windows.UIElement]::OpacityProperty,$fade)
        }
        if ($state.Ready -and $state.FadeStarted -and ($t - $state.FadeAt) -ge .30) { $window.Close(); return }
        if ($t -gt [XingliScene]::BootDuration -and -not $state.Ready) {
            $scene.Waiting = $true
            $scene.LaunchStatus = if ($snapshot.Phase -eq 'Failed') { '点击下方按钮重新打开 Codex' } else { '正在打开 Codex，请稍候...'
            }
            $window.Tag.WaitPanel.Visibility = [Windows.Visibility]::Visible
            $window.Tag.WaitText.Text = $scene.LaunchStatus
            if ($snapshot.Phase -eq 'Failed') { $retry.Visibility = [Windows.Visibility]::Visible }
        }
    })
    $window.Add_Loaded({
        if ($video) { $video.Play() } else { $watch.Start(); $scene.Start() }
        if ($Mode -eq 'Splash') { $state.Launch = Start-XingliApp }
        $timer.Start()
    })
    $window.Add_KeyDown({ if ($_.Key -eq 'Escape') { $state.Skip = $true; $window.Close() } })
    $window.Add_MouseLeftButtonDown({ if ($_.OriginalSource -isnot [Windows.Controls.Button]) { $window.DragMove() } })
    $window.Add_Closed({ $timer.Stop(); $scene.Stop(); if ($video) { $video.Close() } })
    try {
        [void]$window.ShowDialog()
        # Skipping the visual must not cancel the already-authorized app activation.
        if ($Mode -eq 'Splash' -and $state.Launch -and $state.Skip) {
            $deadline = [DateTime]::UtcNow.AddSeconds(50)
            while (-not $state.Launch.Async.IsCompleted -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 150 }
        }
        if ($Mode -eq 'Splash' -and $state.Launch) {
            [void](Show-XingliAppWindow $state.Launch)
            [void](Complete-XingliAppMonitor $state.Launch)
            $companionArgs = '-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Mode Companion' -f $script:scriptFile
            Start-Process -FilePath 'powershell.exe' -ArgumentList $companionArgs -WindowStyle Hidden | Out-Null
        }
        $metrics = @{ Frames = $scene.FrameCount; LongFrames = $scene.LongFrameCount; Duration = $watch.Elapsed.TotalSeconds;
            AverageDrawMs = if ($scene.FrameCount) { $scene.RenderMilliseconds / $scene.FrameCount } else { 0 };
            RenderTier = [Windows.Media.RenderCapability]::Tier -shr 16; Mode = $Mode; Time = (Get-Date).ToString('o');
            PlaybackBackend = if ($video -and -not $state.VideoFailed) { '60fps MP4' } else { 'Procedural fallback' };
            ClipDuration = $state.VideoDuration; MediaError = $state.MediaError;
            AppSource = if ($state.Launch) { (Get-XingliAppState $state.Launch).Source } else { 'Preview' } }
        $metrics | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $PSScriptRoot 'startup-performance.json') -Encoding UTF8
    } finally { $timer.Stop(); $scene.Stop(); $splashMutex.ReleaseMutex(); $splashMutex.Dispose() }
    return
}
$createdNew = $false
$mutexName = if ($Mode -eq 'CompanionPreview') { 'Local\XingliCompanionPreview' } else { 'Local\XingliCompanion' }
$mutex = [Threading.Mutex]::new($true, $mutexName, [ref]$createdNew)
if (-not $createdNew) { $mutex.Dispose(); return }
$window = New-Companion
$bubble = $window.FindName('Bubble')
$portraitLayer = $window.FindName('PortraitLayer')
$shyPortrait = $window.FindName('ShyPortrait')
$blushLayer = $window.FindName('BlushLayer')
$window.Left = [Windows.SystemParameters]::WorkArea.Right - $window.Width - 22
$window.Top = [Windows.SystemParameters]::WorkArea.Bottom - $window.Height - 16

$bob = [Windows.Media.TranslateTransform]::new(0, 0)
$tilt = [Windows.Media.RotateTransform]::new(0)
$portraitMotion = [Windows.Media.TransformGroup]::new()
[void]$portraitMotion.Children.Add($tilt)
[void]$portraitMotion.Children.Add($bob)
$portraitLayer.RenderTransform = $portraitMotion
$float = [Windows.Media.Animation.DoubleAnimation]::new(0, -7, [TimeSpan]::FromSeconds(2.6))
$float.AutoReverse = $true
$float.RepeatBehavior = [Windows.Media.Animation.RepeatBehavior]::Forever
$bob.BeginAnimation([Windows.Media.TranslateTransform]::YProperty, $float)

$reactionTimer = [Windows.Threading.DispatcherTimer]::new()
$reactionTimer.Interval = [TimeSpan]::FromSeconds(2.8)
$reactionTimer.Add_Tick({
    $reactionTimer.Stop()
    Start-OpacityAnimation $shyPortrait 1 0 0 0.35
    Start-OpacityAnimation $blushLayer 0.9 0 0 0.35
    $bubble.Text = 'XINGLI  /  READY'
})
$showShy = {
    $bubble.Text = 'XINGLI  /  唔…有点害羞'
    Start-OpacityAnimation $shyPortrait 0 1 0 0.24
    Start-OpacityAnimation $blushLayer 0 0.9 0 0.28
    $sway = [Windows.Media.Animation.DoubleAnimationUsingKeyFrames]::new()
    [void]$sway.KeyFrames.Add([Windows.Media.Animation.LinearDoubleKeyFrame]::new(-5, [Windows.Media.Animation.KeyTime]::FromTimeSpan([TimeSpan]::FromSeconds(0.14))))
    [void]$sway.KeyFrames.Add([Windows.Media.Animation.LinearDoubleKeyFrame]::new(3, [Windows.Media.Animation.KeyTime]::FromTimeSpan([TimeSpan]::FromSeconds(0.34))))
    [void]$sway.KeyFrames.Add([Windows.Media.Animation.LinearDoubleKeyFrame]::new(0, [Windows.Media.Animation.KeyTime]::FromTimeSpan([TimeSpan]::FromSeconds(0.58))))
    $tilt.BeginAnimation([Windows.Media.RotateTransform]::AngleProperty, $sway)
    $reactionTimer.Stop()
    $reactionTimer.Start()
}
$window.Add_MouseEnter({ if (-not $reactionTimer.IsEnabled) { $bubble.Text = 'XINGLI  /  你来啦' } })
$window.Add_MouseLeave({ if (-not $reactionTimer.IsEnabled) { $bubble.Text = 'XINGLI  /  READY' } })
$window.Add_MouseLeftButtonDown({
    if ($_.ClickCount -ge 2) {
        $reactionTimer.Stop()
        Start-OpacityAnimation $shyPortrait 1 0 0 0.2
        Start-OpacityAnimation $blushLayer 0.9 0 0 0.2
        try { Open-ChatGPT; $bubble.Text = 'XINGLI  /  OPENING CHAT' }
        catch { $bubble.Text = 'CHATGPT NOT FOUND' }
    } else {
        & $showShy
        $window.DragMove()
    }
})
$window.Add_MouseWheel({
    $next = [Math]::Max(230, [Math]::Min(560, $window.Height + ($_.Delta / 12)))
    $window.Width = 320 * ($next / 365)
    $window.Height = $next
})
$menu = [Windows.Controls.ContextMenu]::new()
$openItem = [Windows.Controls.MenuItem]::new()
$openItem.Header = '打开 Codex'
$openItem.Add_Click({ try { Open-ChatGPT } catch { $bubble.Text = 'CHATGPT NOT FOUND' } })
$greetItem = [Windows.Controls.MenuItem]::new()
$greetItem.Header = '和星璃打招呼'
$greetItem.Add_Click({ & $showShy })
$exitItem = [Windows.Controls.MenuItem]::new()
$exitItem.Header = '关闭挂件'
$exitItem.Add_Click({ $window.Close() })
[void]$menu.Items.Add($openItem)
[void]$menu.Items.Add($greetItem)
[void]$menu.Items.Add($exitItem)
$window.ContextMenu = $menu
$window.Add_KeyDown({ if ($_.Key -eq 'Escape') { $window.Close() } })
$appMonitor = [Windows.Threading.DispatcherTimer]::new()
$appMonitor.Interval = [TimeSpan]::FromMilliseconds(200)
$appMonitor.Add_Tick({
    if (-not $script:companionLaunch) { return }
    $snapshot = Get-XingliAppState $script:companionLaunch
    if ($snapshot.Phase -eq 'Ready') {
        [void](Show-XingliAppWindow $script:companionLaunch)
        [void](Complete-XingliAppMonitor $script:companionLaunch)
        $script:companionLaunch = $null
        $bubble.Text = 'XINGLI  /  READY'
    } elseif ($snapshot.Phase -eq 'Failed') {
        [void](Complete-XingliAppMonitor $script:companionLaunch)
        $script:companionLaunch = $null
        $bubble.Text = 'Codex 未能打开，请重试'
    }
})
$window.Add_Loaded({ $appMonitor.Start() })
if ($Mode -eq 'CompanionPreview') {
    $previewTimer = [Windows.Threading.DispatcherTimer]::new()
    $previewTimer.Interval = [TimeSpan]::FromSeconds(2.2)
    $previewTimer.Add_Tick({ $previewTimer.Stop(); $window.Close() })
    $window.Add_Loaded({ & $showShy; $previewTimer.Start() })
}
try { [void]$window.ShowDialog() }
finally {
    $reactionTimer.Stop(); $appMonitor.Stop()
    if ($script:companionLaunch) { Stop-XingliAppMonitor $script:companionLaunch; [void](Complete-XingliAppMonitor $script:companionLaunch) }
    $mutex.ReleaseMutex(); $mutex.Dispose()
}
