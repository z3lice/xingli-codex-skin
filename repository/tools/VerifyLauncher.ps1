# Run in a fresh Windows PowerShell process. Native/app launch operations are
# replaced with controlled probes so this test never starts or closes Codex.
$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @'
public sealed class XingliLaunchProbeResult {
    public bool HasAppProcess, HasWindow, Responding;
    public long WindowHandle;
    public int ProcessId;
}
public static class XingliLaunchNative {
    public static string Mode;
    public static int CallCount;
    public static XingliLaunchProbeResult Probe() {
        CallCount++;
        bool existing = Mode.StartsWith("existing");
        bool ready = Mode == "existing-ready" || CallCount >= 3;
        return new XingliLaunchProbeResult {
            HasAppProcess = existing || ready, HasWindow = ready,
            Responding = ready, WindowHandle = ready ? 123 : 0, ProcessId = ready ? 456 : 0
        };
    }
}
'@
. (Join-Path $PSScriptRoot '..\app\Launcher.ps1')
function Resolve-XingliApp {
    $script:resolveCalls++
    [pscustomobject]@{ AppUserModelId = 'OpenAI.Codex_test!App'; Resolution = 'Test'; SkinLauncher = 'C:\Test\start-dream-skin.ps1' }
}
function Invoke-XingliOfficialActivation {
    param([string]$AppUserModelId)
    $script:activationCalls++
    return 789
}
function Start-Process {
    param($FilePath, $ArgumentList, $WindowStyle, [switch]$PassThru, $RedirectStandardOutput, $RedirectStandardError)
    $script:skinCalls++
    $script:skinArguments = $ArgumentList
    if ($script:failSkinStart) { throw 'Controlled skin process creation failure' }
    [pscustomobject]@{ Id = 321; HasExited = $false; ExitCode = 0 }
}
foreach ($scenario in @('existing-ready', 'existing-waiting', 'cold', 'cold-fallback')) {
    [XingliLaunchNative]::Mode = $scenario
    [XingliLaunchNative]::CallCount = 0
    $script:resolveCalls = 0; $script:activationCalls = 0; $script:skinCalls = 0
    $script:skinArguments = ''; $script:failSkinStart = $scenario -eq 'cold-fallback'
    $state = [hashtable]::Synchronized(@{ InspectOnly = $false; OfficialOnly = $false; CancelRequested = $false })
    Invoke-XingliLaunchWorker -State $state
    if ($state.Phase -ne 'Ready') { throw "$scenario failed to reach Ready: $($state.ErrorMessage)" }
    if ($scenario -eq 'existing-ready' -and ($script:resolveCalls -ne 0 -or $script:activationCalls -ne 0 -or $script:skinCalls -ne 0)) {
        throw 'Existing responsive session was touched.'
    }
    if ($scenario -eq 'existing-waiting' -and ($script:skinCalls -ne 0 -or $script:activationCalls -ne 1)) {
        throw 'Existing session did not use safe official activation.'
    }
    if ($scenario.StartsWith('cold') -and $script:skinCalls -ne 1) { throw 'Cold launch did not start the skin once.' }
    if ($script:skinArguments -match '-RestartExisting|-PromptRestart') { throw 'A restart flag was passed.' }
    if ($scenario -eq 'cold-fallback' -and ($script:activationCalls -ne 1 -or $state.Source -ne 'OfficialFallback')) {
        throw 'Official fallback was not called after skin startup failed.'
    }
    [pscustomobject]@{
        Scenario = $scenario; Phase = $state.Phase; Source = $state.Source
        SkinStarts = $script:skinCalls; Activations = $script:activationCalls
        DiscoveryCalls = $script:resolveCalls; RestartFlag = ($script:skinArguments -match '-RestartExisting|-PromptRestart')
    }
}
