Option Explicit
Dim shell, fso, base, command, result
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
base = fso.GetParentFolderName(WScript.ScriptFullName)
command = "powershell.exe -NoProfile -Sta -ExecutionPolicy Bypass -WindowStyle Hidden -File " & Chr(34) & base & "\Xingli.ps1" & Chr(34) & " -Mode Splash"
result = shell.Run(command, 0, True)
If result <> 0 Then
    shell.Run "explorer.exe shell:AppsFolder\OpenAI.Codex_2p2nqsd0c76g0!App", 0, False
    MsgBox "The startup animation could not load. Codex has been opened directly. Keep all files in the xingli-skin folder together.", 48, "Xingli"
End If
