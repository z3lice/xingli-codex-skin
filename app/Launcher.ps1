# This file only defines launcher functions. Dot-sourcing it never starts an app.
# Initialize-XingliLauncher loads the bundled native helpers before the splash.
# All discovery and window probes then run off the UI thread.

function Initialize-XingliLauncher {
    if ('XingliLaunchNative' -as [type]) { return }
    $nativeLibrary = Join-Path $PSScriptRoot 'Launcher.Native.dll'
    if (Test-Path -LiteralPath $nativeLibrary -PathType Leaf) {
        Add-Type -Path $nativeLibrary -ErrorAction Stop
        return
    }
    # Source fallback keeps the launcher usable if someone copies only this file.
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

public sealed class XingliLaunchProbeResult {
    public bool HasAppProcess;
    public bool HasWindow;
    public bool Responding;
    public long WindowHandle;
    public int ProcessId;
    public int[] ProcessIds;
}

[ComImport, Guid("2e941141-7f97-4756-ba1d-9decde894a3d"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IXingliLaunchActivationManager {
    [PreserveSig] int ActivateApplication(
        [MarshalAs(UnmanagedType.LPWStr)] string appUserModelId,
        [MarshalAs(UnmanagedType.LPWStr)] string arguments,
        uint options, out uint processId);
}
[ComImport, Guid("45ba127d-10a8-46ea-8ab7-56ea9078943c")]
internal class XingliLaunchActivationManager { }

public static class XingliLaunchNative {
    private delegate bool EnumWindowsProc(IntPtr hwnd, IntPtr parameter);
    [StructLayout(LayoutKind.Sequential)] private struct Rect {
        public int Left, Top, Right, Bottom;
    }
    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr parameter);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll")] private static extern bool IsWindow(IntPtr hwnd);
    [DllImport("user32.dll")] private static extern bool IsIconic(IntPtr hwnd);
    [DllImport("user32.dll")] private static extern bool GetWindowRect(IntPtr hwnd, out Rect rect);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint processId);
    [DllImport("user32.dll", SetLastError = true)] private static extern IntPtr SendMessageTimeout(
        IntPtr hwnd, uint message, IntPtr wParam, IntPtr lParam, uint flags, uint timeout, out IntPtr result);
    [DllImport("user32.dll")] private static extern bool ShowWindowAsync(IntPtr hwnd, int command);
    [DllImport("user32.dll")] private static extern bool SetForegroundWindow(IntPtr hwnd);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern IntPtr OpenProcess(uint access, bool inherit, int processId);
    [DllImport("kernel32.dll")] private static extern bool CloseHandle(IntPtr handle);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern bool QueryFullProcessImageName(
        IntPtr process, uint flags, StringBuilder name, ref int size);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] private static extern int GetApplicationUserModelId(
        IntPtr process, ref uint length, StringBuilder appUserModelId);

    private static bool IsCodexProcess(int processId) {
        IntPtr handle = OpenProcess(0x1000, false, processId);
        if (handle == IntPtr.Zero) return false;
        try {
            uint length = 0;
            GetApplicationUserModelId(handle, ref length, null);
            if (length > 0 && length < 4096) {
                var aumid = new StringBuilder((int)length);
                if (GetApplicationUserModelId(handle, ref length, aumid) == 0 &&
                    aumid.ToString().StartsWith("OpenAI.Codex_", StringComparison.OrdinalIgnoreCase)) return true;
            }
            var image = new StringBuilder(4096);
            int size = image.Capacity;
            if (!QueryFullProcessImageName(handle, 0, image, ref size)) return false;
            string path = image.ToString();
            return path.IndexOf("\\WindowsApps\\OpenAI.Codex_", StringComparison.OrdinalIgnoreCase) >= 0 &&
                (path.EndsWith("\\ChatGPT.exe", StringComparison.OrdinalIgnoreCase) ||
                 path.EndsWith("\\Codex.exe", StringComparison.OrdinalIgnoreCase));
        } finally { CloseHandle(handle); }
    }

    // Call this on the launcher worker, not a WPF DispatcherTimer callback.
    public static XingliLaunchProbeResult Probe() {
        var result = new XingliLaunchProbeResult();
        var ids = new HashSet<int>();
        foreach (string name in new string[] { "ChatGPT", "Codex" }) {
            foreach (Process process in Process.GetProcessesByName(name)) {
                using (process) {
                    try { if (IsCodexProcess(process.Id)) ids.Add(process.Id); } catch { }
                }
            }
        }
        result.ProcessIds = new int[ids.Count];
        ids.CopyTo(result.ProcessIds);
        result.HasAppProcess = ids.Count != 0;
        if (!result.HasAppProcess) return result;
        EnumWindows((hwnd, parameter) => {
            if (!IsWindowVisible(hwnd)) return true;
            uint processId;
            GetWindowThreadProcessId(hwnd, out processId);
            if (!ids.Contains((int)processId)) return true;
            Rect rect;
            if (!GetWindowRect(hwnd, out rect)) return true;
            if (!IsIconic(hwnd) && (rect.Right - rect.Left < 180 || rect.Bottom - rect.Top < 100)) return true;
            IntPtr ignored;
            bool responding = SendMessageTimeout(hwnd, 0, IntPtr.Zero, IntPtr.Zero, 0x0002, 100, out ignored) != IntPtr.Zero;
            // Prefer a responding window if an app has more than one top-level window.
            if (!result.HasWindow || responding) {
                result.HasWindow = true;
                result.Responding = responding;
                result.WindowHandle = hwnd.ToInt64();
                result.ProcessId = (int)processId;
            }
            return !responding;
        }, IntPtr.Zero);
        return result;
    }

    public static uint Activate(string appUserModelId) {
        var manager = (IXingliLaunchActivationManager)new XingliLaunchActivationManager();
        try {
            uint processId;
            int status = manager.ActivateApplication(appUserModelId, String.Empty, 0, out processId);
            Marshal.ThrowExceptionForHR(status);
            return processId;
        } finally {
            if (Marshal.IsComObject(manager)) Marshal.FinalReleaseComObject(manager);
        }
    }

    // Focus is intentionally separate so Codex does not interrupt the splash.
    public static bool Focus(long windowHandle) {
        var hwnd = new IntPtr(windowHandle);
        if (!IsWindow(hwnd)) return false;
        ShowWindowAsync(hwnd, IsIconic(hwnd) ? 9 : 5);
        return SetForegroundWindow(hwnd);
    }
}
'@
}

function Resolve-XingliApp {
    # This is used by Invoke-XingliLaunchWorker inside a separate STA runspace.
    $appId = $null
    $resolution = 'KnownPackageIdentity'
    try {
        $registered = Get-StartApps -ErrorAction Stop |
            Where-Object { $_.AppID -match '^OpenAI\.Codex_[^!]+!App$' } |
            Select-Object -First 1
        if ($registered) { $appId = $registered.AppID; $resolution = 'StartApps' }
    } catch { }
    if (-not $appId) {
        try {
            $package = Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction Stop |
                Sort-Object Version -Descending | Select-Object -First 1
            if ($package -and $package.PackageFamilyName) {
                $appId = $package.PackageFamilyName + '!App'
                $resolution = 'RegisteredPackage'
            }
        } catch { }
    }
    if (-not $appId) { $appId = 'OpenAI.Codex_2p2nqsd0c76g0!App' }
    $skinLauncher = Join-Path $env:USERPROFILE 'AppData\Local\CodexDreamSkin\engine\scripts\start-dream-skin.ps1'
    if (-not (Test-Path -LiteralPath $skinLauncher -PathType Leaf)) { $skinLauncher = $null }
    [pscustomobject]@{
        AppUserModelId = $appId
        Resolution = $resolution
        SkinLauncher = $skinLauncher
    }
}

function Set-XingliLaunchState {
    param([hashtable]$State, [hashtable]$Values)
    [Threading.Monitor]::Enter($State.SyncRoot)
    try { foreach ($key in $Values.Keys) { $State[$key] = $Values[$key] } }
    finally { [Threading.Monitor]::Exit($State.SyncRoot) }
}

function Invoke-XingliOfficialActivation {
    param([string]$AppUserModelId)
    try { return [int][XingliLaunchNative]::Activate($AppUserModelId) }
    catch {
        # AppsFolder is the Store app activation fallback, not a second profile.
        $start = [Diagnostics.ProcessStartInfo]::new()
        $start.FileName = Join-Path $env:WINDIR 'explorer.exe'
        $start.Arguments = 'shell:AppsFolder\' + $AppUserModelId
        $start.UseShellExecute = $true
        [void][Diagnostics.Process]::Start($start)
        return 0
    }
}

function New-XingliLaunchLogPaths {
    $launchId = [Guid]::NewGuid().ToString('N')
    $projectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $roots = @(
        (Join-Path ([IO.Path]::GetTempPath()) 'XingliLauncher'),
        (Join-Path $projectRoot 'work\launcher-logs')
    )
    foreach ($logRoot in $roots) {
        try {
            $directory = Join-Path $logRoot $launchId
            [void][IO.Directory]::CreateDirectory($directory)
            $outputLog = Join-Path $directory 'dreamskin-out.log'
            $errorLog = Join-Path $directory 'dreamskin-error.log'
            # Confirm both redirection targets can be created. A restricted TEMP
            # can allow directory enumeration yet deny creation of log files.
            [IO.File]::WriteAllText($outputLog, '')
            [IO.File]::WriteAllText($errorLog, '')
            return [pscustomobject]@{ OutputLog = $outputLog; ErrorLog = $errorLog }
        } catch { }
    }
    # Logging must not prevent the app from opening if both directories are denied.
    return $null
}

function Invoke-XingliLaunchWorker {
    param([hashtable]$State)
    try {
        $probe = [XingliLaunchNative]::Probe()
        Set-XingliLaunchState $State @{
            ExistingSession = $probe.HasAppProcess
            WindowHandle = $probe.WindowHandle
            ProcessId = $probe.ProcessId
            HasResponsiveWindow = ($probe.HasWindow -and $probe.Responding)
        }
        if ($probe.HasWindow -and $probe.Responding -and -not $State.InspectOnly) {
            Set-XingliLaunchState $State @{ Phase = 'Ready'; Source = 'Existing'; FinishedUtc = [DateTime]::UtcNow }
            return
        }
        $app = Resolve-XingliApp
        Set-XingliLaunchState $State @{
            AppUserModelId = $app.AppUserModelId
            Resolution = $app.Resolution
            SkinLauncher = $app.SkinLauncher
        }
        if ($State.InspectOnly) {
            Set-XingliLaunchState $State @{ Phase = 'Resolved'; Source = 'Inspection'; FinishedUtc = [DateTime]::UtcNow }
            return
        }
        if ($State.CancelRequested) { Set-XingliLaunchState $State @{ Phase = 'Cancelled' }; return }

        # Recheck after discovery. If the user opened Codex meanwhile, preserve it.
        $probe = [XingliLaunchNative]::Probe()
        $skinProcess = $null
        $officialStarted = $false
        $watch = [Diagnostics.Stopwatch]::StartNew()
        if (-not $State.OfficialOnly -and -not $probe.HasAppProcess -and $app.SkinLauncher) {
            $logs = New-XingliLaunchLogPaths
            # Do not use -RestartExisting. The installed script refuses to restart
            # an existing non-CDP session unless that switch is explicitly passed.
            $arguments = '-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $app.SkinLauncher
            try {
                $startParameters = @{
                    FilePath = (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe')
                    ArgumentList = $arguments; WindowStyle = 'Hidden'; PassThru = $true
                }
                if ($logs) {
                    $startParameters.RedirectStandardOutput = $logs.OutputLog
                    $startParameters.RedirectStandardError = $logs.ErrorLog
                }
                $skinProcess = Start-Process @startParameters
                Set-XingliLaunchState $State @{
                    Phase = 'WaitingForWindow'; Source = 'DreamSkin'; SkinProcessId = $skinProcess.Id
                    OutputLog = $(if ($logs) { $logs.OutputLog } else { $null })
                    ErrorLog = $(if ($logs) { $logs.ErrorLog } else { $null })
                }
            } catch {
                Set-XingliLaunchState $State @{ Phase = 'Starting'; Source = 'OfficialFallback'; SkinLaunchError = $_.Exception.Message }
                $activatedId = Invoke-XingliOfficialActivation $app.AppUserModelId
                $officialStarted = $true
                Set-XingliLaunchState $State @{ Phase = 'WaitingForWindow'; ActivationProcessId = $activatedId }
            }
        } else {
            Set-XingliLaunchState $State @{ Phase = 'Starting'; Source = 'Official'; ExistingSession = $probe.HasAppProcess }
            $activatedId = Invoke-XingliOfficialActivation $app.AppUserModelId
            $officialStarted = $true
            Set-XingliLaunchState $State @{ Phase = 'WaitingForWindow'; ActivationProcessId = $activatedId }
        }

        while (-not $State.CancelRequested) {
            $probe = [XingliLaunchNative]::Probe()
            Set-XingliLaunchState $State @{
                WindowHandle = $probe.WindowHandle; ProcessId = $probe.ProcessId
                HasResponsiveWindow = ($probe.HasWindow -and $probe.Responding)
                ElapsedSeconds = $watch.Elapsed.TotalSeconds
            }
            if ($probe.HasWindow -and $probe.Responding) {
                Set-XingliLaunchState $State @{ Phase = 'Ready'; FinishedUtc = [DateTime]::UtcNow }
                return
            }
            if ($skinProcess -and $skinProcess.HasExited -and -not $officialStarted) {
                # Wait for the skin starter to exit before a fallback activation.
                # Its failure recovery must not race a second independent launch.
                Set-XingliLaunchState $State @{ Phase = 'Starting'; Source = 'OfficialFallback'; SkinExitCode = $skinProcess.ExitCode }
                $activatedId = Invoke-XingliOfficialActivation $app.AppUserModelId
                $officialStarted = $true
                $watch.Restart()
                Set-XingliLaunchState $State @{ Phase = 'WaitingForWindow'; ActivationProcessId = $activatedId }
            }
            $deadline = if ($officialStarted) { 30 } else { 150 }
            if ($watch.Elapsed.TotalSeconds -ge $deadline) {
                $message = if ($probe.HasWindow) { 'Codex has a window but is not responding.' } else { 'Codex did not create a usable window before the launch timeout.' }
                Set-XingliLaunchState $State @{ Phase = 'Failed'; ErrorMessage = $message; FinishedUtc = [DateTime]::UtcNow }
                return
            }
            Start-Sleep -Milliseconds 250
        }
        Set-XingliLaunchState $State @{ Phase = 'Cancelled'; FinishedUtc = [DateTime]::UtcNow }
    } catch {
        Set-XingliLaunchState $State @{ Phase = 'Failed'; ErrorMessage = $_.Exception.Message; FinishedUtc = [DateTime]::UtcNow }
    }
}

function Start-XingliApp {
    [CmdletBinding()]
    param([switch]$OfficialOnly, [switch]$InspectOnly)
    Initialize-XingliLauncher
    $state = [hashtable]::Synchronized(@{
        Phase = 'Resolving'; Source = ''; StartedUtc = [DateTime]::UtcNow
        FinishedUtc = $null; ExistingSession = $false; HasResponsiveWindow = $false
        WindowHandle = [long]0; ProcessId = 0; ActivationProcessId = 0
        AppUserModelId = ''; Resolution = ''; SkinLauncher = $null
        SkinProcessId = 0; SkinExitCode = $null; ErrorMessage = ''
        OutputLog = $null; ErrorLog = $null; ElapsedSeconds = 0.0
        CancelRequested = $false; OfficialOnly = [bool]$OfficialOnly; InspectOnly = [bool]$InspectOnly
    })
    $runspace = [RunspaceFactory]::CreateRunspace()
    $runspace.ApartmentState = [Threading.ApartmentState]::STA
    $runspace.ThreadOptions = [Management.Automation.Runspaces.PSThreadOptions]::ReuseThread
    $runspace.Open()
    $pipeline = [PowerShell]::Create()
    $pipeline.Runspace = $runspace
    [void]$pipeline.AddScript({
        param($launcherFile, $launchState)
        . $launcherFile
        Invoke-XingliLaunchWorker -State $launchState
    }.ToString()).AddArgument($PSScriptRoot + '\Launcher.ps1').AddArgument($state)
    try {
        $async = $pipeline.BeginInvoke()
        [pscustomobject]@{ State = $state; Runspace = $runspace; Pipeline = $pipeline; Async = $async; Completed = $false }
    } catch {
        $pipeline.Dispose(); $runspace.Dispose()
        throw
    }
}

function Get-XingliAppState {
    param([Parameter(Mandatory = $true)]$Handle)
    [Threading.Monitor]::Enter($Handle.State.SyncRoot)
    try { $copy = $Handle.State.Clone() }
    finally { [Threading.Monitor]::Exit($Handle.State.SyncRoot) }
    [pscustomobject]$copy
}

function Show-XingliAppWindow {
    param([Parameter(Mandatory = $true)]$Handle)
    $snapshot = Get-XingliAppState $Handle
    if ($snapshot.WindowHandle -ne 0) { return [XingliLaunchNative]::Focus([long]$snapshot.WindowHandle) }
    return $false
}

function Stop-XingliAppMonitor {
    param([Parameter(Mandatory = $true)]$Handle)
    # Cancel only monitoring. Never terminate Codex or the skin starter.
    $Handle.State.CancelRequested = $true
}

function Complete-XingliAppMonitor {
    param([Parameter(Mandatory = $true)]$Handle)
    # Safe to call from a timer: do not block while a worker is still running.
    if ($Handle.Completed) { return $true }
    if (-not $Handle.Async.IsCompleted) { return $false }
    try { [void]$Handle.Pipeline.EndInvoke($Handle.Async) }
    finally { $Handle.Pipeline.Dispose(); $Handle.Runspace.Dispose(); $Handle.Completed = $true }
    return $true
}
