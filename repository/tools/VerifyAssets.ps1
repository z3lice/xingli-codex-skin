# Loads source and image assets without opening windows or starting Codex.
$ErrorActionPreference = 'Stop'
$app = Join-Path (Split-Path -Parent $PSScriptRoot) 'app'
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
Add-Type -Path @((Join-Path $app 'Scene.cs'),(Join-Path $app 'CharacterMotion.cs')) -ReferencedAssemblies @('System.dll','System.Core.dll','System.Xaml.dll',[Windows.Window].Assembly.Location,[Windows.Media.DrawingContext].Assembly.Location,[Windows.Point].Assembly.Location)
. (Join-Path $app 'Launcher.ps1')
Initialize-XingliLauncher
$scene = [XingliScene]::new($app)
Write-Output 'Source compilation and scene asset loading passed.'
Get-ChildItem -LiteralPath (Split-Path -Parent $PSScriptRoot) -Recurse -Filter *.ps1 | ForEach-Object {
    $tokens = $null; $parseErrors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($_.FullName,[ref]$tokens,[ref]$parseErrors)
    if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
}
Write-Output 'PowerShell syntax passed.'
