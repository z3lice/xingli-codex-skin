Option Explicit
Dim shell, fso, base, command
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
base = fso.GetParentFolderName(WScript.ScriptFullName)
command = "powershell.exe -NoProfile -Sta -ExecutionPolicy Bypass -WindowStyle Hidden -File " & Chr(34) & base & "\Xingli.ps1" & Chr(34) & " -Mode Companion"
shell.Run command, 0, False
