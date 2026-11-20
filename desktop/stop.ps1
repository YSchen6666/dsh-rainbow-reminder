# 停止桌面提醒助手。
#   desktop\stop.ps1
$found = @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
  Where-Object { $_.CommandLine -and $_.CommandLine -match 'reminder\.ps1' })

if ($found.Count -eq 0) { Write-Host '助手未在运行。'; exit 0 }

foreach ($p in $found) {
  try {
    Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop
    Write-Host ("已停止助手 pid {0}" -f $p.ProcessId)
  } catch {
    Write-Host ("停止 pid {0} 失败：{1}" -f $p.ProcessId, $_.Exception.Message)
  }
}
