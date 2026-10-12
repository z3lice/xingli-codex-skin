$ErrorActionPreference = 'Stop'
$entry = Join-Path $PSScriptRoot 'app\Start-Xingli.vbs'
if (-not (Test-Path -LiteralPath $entry -PathType Leaf)) { throw 'Extract the complete package before running this script.' }
$desktop = [Environment]::GetFolderPath('Desktop')
$link = Join-Path $desktop '星璃 Codex（便携版）.lnk'
if (Test-Path -LiteralPath $link) { throw "Shortcut already exists: $link. Remove that shortcut first if you want to recreate it." }
$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($link)
$shortcut.TargetPath = Join-Path $env:WINDIR 'System32\wscript.exe'
$shortcut.Arguments = '"' + $entry + '"'
$shortcut.WorkingDirectory = Join-Path $PSScriptRoot 'app'
$shortcut.IconLocation = (Join-Path $PSScriptRoot 'app\xingli-icon.ico') + ',0'
$shortcut.Description = 'Xingli startup animation for Codex'
$shortcut.Save()
Write-Host "Created: $link"
