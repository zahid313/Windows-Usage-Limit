Set objShell = CreateObject("WScript.Shell")
strPath = CreateObject("Scripting.FileSystemObject").GetParentFolderName(WScript.ScriptFullName)
objShell.Run "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File """ & strPath & "\SessionProbe.ps1""", 0, False
