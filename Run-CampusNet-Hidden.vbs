Option Explicit
Dim shell, fs, folder, ps, scriptPath, command, result, runId, receiptPath, receipt, stream
Set shell = CreateObject("WScript.Shell")
Set fs = CreateObject("Scripting.FileSystemObject")
folder = fs.GetParentFolderName(WScript.ScriptFullName)
ps = shell.ExpandEnvironmentStrings("%SystemRoot%") & "\System32\WindowsPowerShell\v1.0\powershell.exe"
scriptPath = folder & "\CampusNet-AutoLogin.ps1"
receiptPath = folder & "\last-run.json"
runId = Replace(fs.GetTempName, ".", "-")
LogLine "START run=" & runId
If Not fs.FileExists(scriptPath) Then
    LogLine "ERROR script_missing"
    WScript.Quit 90
End If
command = Q(ps) & " -NoProfile -NonInteractive -ExecutionPolicy Bypass -File " & Q(scriptPath) & " -RunId " & Q(runId) & " -DataDirectory " & Q(folder) & " -CredentialPath " & Q(folder & "\credential.xml")
If WScript.Arguments.Count > 0 Then
    If LCase(WScript.Arguments(0)) = "force" Then command = command & " -ForceReauth"
End If
On Error Resume Next
result = shell.Run(command, 0, True)
If Err.Number <> 0 Then
    LogLine "ERROR launch_failed"
    WScript.Quit 91
End If
On Error GoTo 0
If result = 75 Then
    LogLine "END run=" & runId & " code=75 already_running"
    WScript.Quit 75
End If
If Not fs.FileExists(receiptPath) Then
    LogLine "ERROR run=" & runId & " receipt_missing child_code=" & CStr(result)
    WScript.Quit 92
End If
Set stream = fs.OpenTextFile(receiptPath, 1)
receipt = stream.ReadAll
stream.Close
If Not Matches(receipt, """runId""\s*:\s*""" & runId & """") Or Not Matches(receipt, """completed""\s*:\s*true") Then
    LogLine "ERROR run=" & runId & " receipt_invalid child_code=" & CStr(result)
    WScript.Quit 93
End If
LogLine "END run=" & runId & " code=" & CStr(result)
WScript.Quit result
Function Q(ByVal value)
    Q = Chr(34) & value & Chr(34)
End Function
Function Matches(ByVal text, ByVal pattern)
    Dim re
    Set re = New RegExp
    re.Pattern = pattern
    re.IgnoreCase = True
    Matches = re.Test(text)
End Function
Sub LogLine(ByVal value)
    Dim logPath, logFile
    logPath = folder & "\launcher.log"
    If fs.FileExists(logPath) Then
        If fs.GetFile(logPath).Size > 2097152 Then
            If fs.FileExists(logPath & ".previous") Then fs.DeleteFile logPath & ".previous"
            fs.MoveFile logPath, logPath & ".previous"
        End If
    End If
    Set logFile = fs.OpenTextFile(logPath, 8, True)
    logFile.WriteLine CStr(Now) & " " & value
    logFile.Close
End Sub
