# 开机自启（HKCU Run，不需要管理员）。
#   desktop\autostart.ps1            开启
#   desktop\autostart.ps1 -Remove    关闭
#   desktop\autostart.ps1 -Status    查看
param(
  [switch] $Remove,
  [switch] $Status
)

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$start = Join-Path $here 'start.ps1'
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$name = 'DSH-Rainbow-Reminder'

$current = (Get-ItemProperty -Path $runKey -Name $name -ErrorAction SilentlyContinue).$name

if ($Status) {
  if ($current) { Write-Host ("已启用：{0}" -f $current) } else { Write-Host '未启用。' }
  exit 0
}

if ($Remove) {
  Remove-ItemProperty -Path $runKey -Name $name -ErrorAction SilentlyContinue
  Write-Host '已关闭开机自启。'
  exit 0
}

$cmd = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $start
Set-ItemProperty -Path $runKey -Name $name -Value $cmd
Write-Host ("已启用开机自启：{0}" -f $cmd)
