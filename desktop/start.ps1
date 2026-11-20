# 启动桌面提醒助手（无窗口，后台常驻）。
#   desktop\start.ps1
# 已运行则直接返回（助手自身有单实例互斥量）。
param(
  [string] $ConfigPath = '',
  [switch] $Foreground
)

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$script = Join-Path $here 'reminder.ps1'
if (-not (Test-Path -LiteralPath $script)) { throw "找不到 $script" }
if ([string]::IsNullOrWhiteSpace($ConfigPath)) { $ConfigPath = Join-Path $here 'config.json' }

$argList = @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', $script, '-ConfigPath', $ConfigPath)
if ($Foreground) {
  & powershell.exe @argList
  exit $LASTEXITCODE
}

$p = Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -WindowStyle Hidden -PassThru
Write-Host ("DSH 提醒助手已启动 (pid {0})" -f $p.Id)
Write-Host ("配置文件: {0}" -f $ConfigPath)
Write-Host ("日志:     {0}" -f (Join-Path $env:LOCALAPPDATA 'dsh-rainbow-reminder\assistant.log'))
Write-Host '颜色/透明度改 config.json 后约 1 秒自动生效；托盘图标可调透明度与退出。'
