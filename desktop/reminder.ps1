# ============================================================================
#  DSH Desktop Reminder — 科技简约风顶部色带提醒助手 (Win10)
#  运行时: Windows PowerShell 5.1 + WPF (.NET 4.8)，无外部依赖。
#  编码: 本文件必须保存为 UTF-8 with BOM，否则 PS5.1 会把中文读成乱码。
#
#  用法:
#     powershell -STA -File desktop\reminder.ps1 [-ConfigPath p] [-SignalPath p]
#                                                 [-NoTray] [-SelfTest]
#
#  数据源: 插件 Host 半区追加写入的 signal.jsonl（本机文件通道）。
#          走文件而不是 HTTP，是因为 DSH 的本地 Web 服务对所有请求返回 401，
#          外部进程不该去绕过它的鉴权。
# ============================================================================
[CmdletBinding()]
param(
  [string] $ConfigPath = '',
  [string] $SignalPath = '',
  [switch] $NoTray,
  [switch] $SelfTest,
  [switch] $ShowSettings,
  [int]    $SelfTestMs = 12000,
  [string] $CaptureDir = ''
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# 0. 路径 / Win32 互操作
# ---------------------------------------------------------------------------
$StateDir = Join-Path $env:LOCALAPPDATA 'dsh-rainbow-reminder'
try { New-Item -ItemType Directory -Force -Path $StateDir | Out-Null } catch { }

$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
if ([string]::IsNullOrWhiteSpace($ConfigPath)) { $ConfigPath = Join-Path $ScriptRoot 'config.json' }
$LogPath = Join-Path $StateDir 'assistant.log'

# 单实例互斥量：第二次启动直接退出，避免出现两条色带
$Script:Mutex = New-Object System.Threading.Mutex($false, 'Local\dsh-rainbow-reminder-assistant')
if (-not $Script:Mutex.WaitOne(0)) {
  Write-Host 'DSH 提醒助手已在运行（互斥量被占用），本次退出。'
  exit 0
}

# pidfile 心跳：供插件 Host 半区守护进程判断本助手是否存活。
# 每 5 秒由主循环刷新 at 字段；Host 侧读 pid + at，两者都有效才算活着。
$PidFile = Join-Path $StateDir 'assistant.pid'

function Write-PidHeartbeat {
  try {
    @{ pid = $PID; at = (Get-Date).ToUniversalTime().ToString('o') } |
      ConvertTo-Json -Compress |
      Set-Content -LiteralPath $PidFile -Encoding UTF8
  } catch { }
}

Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName WindowsBase

if (-not ('DshRem.Native' -as [type])) {
  Add-Type -Namespace 'DshRem' -Name 'Native' -MemberDefinition @'
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h, int n);
    [DllImport("user32.dll")] public static extern int SetWindowLong(IntPtr h, int n, int v);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint f);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool MessageBeep(uint type);
    [DllImport("user32.dll")] public static extern IntPtr GetDC(IntPtr h);
    [DllImport("user32.dll")] public static extern void ReleaseDC(IntPtr h, IntPtr dc);
    [DllImport("gdi32.dll")]  public static extern int GetDeviceCaps(IntPtr dc, int index);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextLength(IntPtr h);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, System.Text.StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern int GetWindowThreadProcessId(IntPtr h, out int pid);

    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }

    public static int DpiX() {
      IntPtr dc = GetDC(IntPtr.Zero);
      try { int d = GetDeviceCaps(dc, 88); return d > 0 ? d : 96; }
      finally { ReleaseDC(IntPtr.Zero, dc); }
    }

    public static bool IsForegroundFullscreenOnPrimary(int screenL, int screenT, int screenR, int screenB) {
      IntPtr h = GetForegroundWindow();
      if (h == IntPtr.Zero) return false;
      RECT r;
      if (!GetWindowRect(h, out r)) return false;
      return r.Left <= screenL && r.Top <= screenT && r.Right >= screenR && r.Bottom >= screenB;
    }
'@
}

$GWL_EXSTYLE       = -20
$WS_EX_LAYERED     = 0x00080000
$WS_EX_TRANSPARENT = 0x00000020
$WS_EX_TOOLWINDOW  = 0x00000080
$WS_EX_NOACTIVATE  = 0x08000000
$SWP_NOSIZE        = 0x0001
$SWP_NOMOVE        = 0x0002
$SWP_NOACTIVATE    = 0x0010
$Script:ExStyleMask = $WS_EX_LAYERED -bor $WS_EX_TRANSPARENT -bor $WS_EX_TOOLWINDOW -bor $WS_EX_NOACTIVATE

# ---------------------------------------------------------------------------
# 0.5 彩云贴图（参考图 1:1 复刻：金色祥云 + 电路纹 + 闪粒）
# ---------------------------------------------------------------------------
# 贴图来自 desktop\assets\cloud-keyed.png（1872x1248，透明背景），
# 渲染时按屏宽 1/10 等比缩放，顶部居中常驻显示。
# 显示规则：仅 approval（等待授权）、question（等待回答）、waiting（等待处理）
# 三类触发，常驻屏幕顶部正中直至被 resolve 解除；其余类型不显示。

# 贴图宽高比；读入成功后会覆盖为实际值
$Script:CloudTexRatio = 1.5

# 只显示这些类型（其余一律忽略）
#   等待类：approval（等待授权）/ question（等待回答）/ waiting（等待处理）→ 金色，顶部居中
#   故障类：error（任务出错）/ blocked（任务无法继续）                    → 红色，右上角
$Script:CloudKinds = @('done', 'approval', 'question', 'waiting', 'error', 'blocked')
$Script:ErrorKinds = @('error', 'blocked')

function Test-CloudKind([string] $kind) {
  return $Script:CloudKinds -contains [string] $kind
}

# ---------------------------------------------------------------------------
# 1. 配置
# ---------------------------------------------------------------------------
$Script:Defaults = [ordered]@{
  profile          = 'banner'
  screen           = 'primary'
  backdrop         = @{ enabled = $true; color = '#0A0E14'; opacity = 0.35; height = 26 }
  hairline         = @{ enabled = $true; thickness = 2; opacity = 0.85 }
  dot              = @{ enabled = $true; size = 6; opacity = 0.95 }
  label            = @{ enabled = $true; font = 'Consolas'; size = 11.5; opacity = 0.92; color = '#C9D4E2'
                        showTime = $true; showSession = $true; paddingLeft = 10 }
  motion           = @{ fadeInMs = 180; fadeOutMs = 260; colorTweenMs = 220; pulseMs = 2600; pulseDepth = 0.9 }
  typeAlphaScale   = 1.0
  quietMs          = 1200
  globalThrottleMs = 500
  pollMs           = 120
  sound            = @{ enabled = $true; volume = 0.6 }
  fallback         = @{ signalFile = ''; pollMs = 300 }
  dimWhenFullscreen = $true
  # 屏幕边框「极光能量场」（惊艳版：三层 bloom / 双向对冲 / 极光色相）
  edgeGlow         = @{
                          enabled      = $true
                          borderPx     = 3        # 常亮底线宽度
                          glowPx       = 30       # 宽光晕（bloom 外层）
                          sweepPx      = 8        # 主色带（bloom 中层）
                          corePx       = 2        # 白热过曝核（bloom 内层）
                          cycleMs      = 3000     # 呼吸/色相漂移周期 ms
                          flowSpeed    = 0.42     # 主彗星 圈/秒
                          cometTail    = 0.20     # 彗尾占周长比例
                          hueDrift     = 6.0      # 色相每秒漂移角度（极光感）
                          opacity      = 1.0      # 整体强度
                          kindColors   = @{}      # 各信号类型基准色
                        }
  # 等待类金云：顶部居中（贴图默认关闭——提醒只靠边框极光表达）
  cloud            = @{ enabled = $false; widthFraction = 0.10; opacity = 0.92
                        centerX = 0.5; labelInside = $true }
  # 故障红云：任务无法继续 / 报错时，右上角显示红色祥云（贴图默认关闭）
  errorCloud       = @{ enabled = $false; widthFraction = 0.18; opacity = 0.92
                        marginRight = 0.02; marginTop = 0.03
                        glowColor = '#FF3030'; glowOpacity = 0.22 }
  # 完成任务绿云：左上角显示绿色祥云（贴图默认关闭）
  doneCloud        = @{ enabled = $false; widthFraction = 0.10; opacity = 0.92
                        marginLeft = 0.03; marginTop = 0.03; fadeInMs = 700; fadeOutMs = 900
                        glowColor = '#35D07F'; glowOpacity = 0.14 }
  minimal          = @{ backdrop = @{ opacity = 0.0 }; label = @{ enabled = $false }
                        hairline = @{ thickness = 3 }; dot = @{ enabled = $false }; height = 10 }
  # 打开 DSH 窗口看过之后自动收提醒：前台窗口命中 processMatch/titleMatch 并停留 dwellMs
  # 后，把"进入前台那一刻就已经存在"的提醒条目自动解除（之后新到的照常提醒）。
  autoDismiss      = @{ enabled = $true; dwellMs = 800
                        processMatch = @('DeepSeek Harness')
                        titleMatch   = @('DeepSeek Harness') }
}

$Script:KindDefaults = [ordered]@{
  approval = @{ color = '#FFB454'; labelEn = 'APPROVAL'; label = '等待授权'; holdMs = 0;     maxHoldMs = 600000; priority = 90; pulse = $true;  sound = 'question' }
  question = @{ color = '#FFB454'; labelEn = 'QUESTION'; label = '等待回答'; holdMs = 0;     maxHoldMs = 600000; priority = 80; pulse = $true;  sound = 'question' }
  error    = @{ color = '#FF6B6B'; labelEn = 'ERROR';    label = '任务出错'; holdMs = 0;     maxHoldMs = 7200000; priority = 70; pulse = $true;  sound = 'hand' }
  blocked  = @{ color = '#FF3030'; labelEn = 'BLOCKED';  label = '任务无法继续'; holdMs = 0; maxHoldMs = 7200000; priority = 85; pulse = $true;  sound = 'hand' }
  waiting  = @{ color = '#FFB454'; labelEn = 'WAITING';  label = '等待处理'; holdMs = 0;     maxHoldMs = 600000; priority = 60; pulse = $true;  sound = 'none' }
  team     = @{ color = '#9D8CFF'; labelEn = 'TEAM';     label = '队友消息'; holdMs = 6000;  maxHoldMs = 8000;   priority = 45; pulse = $false; sound = 'none' }
  done     = @{ color = '#35D07F'; labelEn = 'DONE';     label = '任务完成'; holdMs = 0;     maxHoldMs = 7200000; priority = 40; pulse = $true;  sound = 'ok' }
  jobs     = @{ color = '#8E9BA8'; labelEn = 'JOBS';     label = '后台任务结束'; holdMs = 6000; maxHoldMs = 8000; priority = 30; pulse = $false; sound = 'none' }
  schedule = @{ color = '#C792EA'; labelEn = 'SCHEDULE'; label = '定时任务触发'; holdMs = 6000; maxHoldMs = 8000; priority = 30; pulse = $false; sound = 'none' }
  default  = @{ color = '#56D4E0'; labelEn = 'DSH';      label = 'DSH 提示'; holdMs = 6000;  maxHoldMs = 8000;   priority = 20; pulse = $false; sound = 'none' }
}

function Write-AssistLog([string] $msg) {
  try {
    Add-Content -LiteralPath $LogPath -Value ('[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss.fff'), $msg) -Encoding UTF8
  } catch { }
}

function ConvertTo-Plain($v) {
  # PSCustomObject -> 普通 hashtable，数组递归转换；让深合并与迭代行为完全可控
  if ($null -eq $v) { return $null }
  if ($v -is [System.Management.Automation.PSCustomObject]) {
    $h = @{}
    foreach ($p in $v.PSObject.Properties) { $h[[string] $p.Name] = ConvertTo-Plain $p.Value }
    return $h
  }
  if ($v -is [System.Collections.IEnumerable] -and $v -isnot [string]) {
    return @($v | ForEach-Object { ConvertTo-Plain $_ })
  }
  return $v
}

function Get-Nested($base, $over) {
  # 以 base 为骨架，用 over 覆盖；同时保留 over 独有的键。
  # 修根因：旧实现只遍历 base.Keys，导致「默认为空对象、实际配置里填充」的
  # 嵌套项（如 edgeGlow.kindColors）在合并时被整个丢弃，永远读不到用户配色。
  $out = @{}
  if ($null -eq $over) { $over = @{} }
  $overIsMap = ($over -is [System.Collections.IDictionary])
  foreach ($k in @($base.Keys)) {
    $bv = $base[[string] $k]
    $hasOver = $overIsMap -and $over.Contains([string] $k)
    $ov = if ($hasOver) { $over[[string] $k] } else { $null }
    if ($bv -is [System.Collections.IDictionary] -and $ov -is [System.Collections.IDictionary]) {
      $out[[string] $k] = Get-Nested $bv $ov
    } elseif ($null -ne $ov) {
      $out[[string] $k] = $ov
    } else {
      $out[[string] $k] = $bv
    }
  }
  # 补齐 over 独有的键（base 里不存在的）
  if ($overIsMap) {
    foreach ($ok in @($over.Keys)) {
      if (-not $out.Contains([string] $ok)) { $out[[string] $ok] = $over[[string] $ok] }
    }
  }
  return $out
}

function Clamp($v, [double] $lo, [double] $hi) {
  $d = [double] $lo
  if (-not [double]::TryParse([string] $v, [ref] $d)) { return $lo }
  if ($d -lt $lo) { return $lo }
  if ($d -gt $hi) { return $hi }
  return $d
}

function Test-HexColor([string] $s) { return $s -match '^#[0-9a-fA-F]{6}$' -or $s -match '^#[0-9a-fA-F]{8}$' }

function ConvertFrom-HexColor([string] $hex) {
  if (Test-HexColor $hex) {
    $h = $hex.Substring(1)
    if ($h.Length -eq 8) { $h = $h.Substring(0, 6) }
    return @([int] ([Convert]::ToByte($h.Substring(0, 2), 16)),
            [int] ([Convert]::ToByte($h.Substring(2, 2), 16)),
            [int] ([Convert]::ToByte($h.Substring(4, 2), 16)))
  }
  return @(200, 210, 220)
}

$Script:Cfg = $null
$Script:Kinds = $null
$Script:CfgStamp = [datetime]::MinValue

function Read-Config {
  if (-not (Test-Path -LiteralPath $ConfigPath)) { return $false }
  $raw = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8
  if ([string]::IsNullOrWhiteSpace($raw)) { return $false }
  $obj = $null
  try { $obj = ConvertTo-Plain ($raw | ConvertFrom-Json) } catch {
    Write-AssistLog ("config parse error: {0}" -f $_.Exception.Message)
    return $false
  }
  $cfg = Get-Nested $Script:Defaults $obj

  $cfg.backdrop.enabled   = [bool] $cfg.backdrop.enabled
  $cfg.backdrop.opacity   = Clamp $cfg.backdrop.opacity 0 1
  $cfg.backdrop.height    = Clamp $cfg.backdrop.height 4 80
  if (-not (Test-HexColor ([string] $cfg.backdrop.color))) { $cfg.backdrop.color = '#0A0E14' }
  $cfg.hairline.enabled   = [bool] $cfg.hairline.enabled
  $cfg.hairline.thickness = Clamp $cfg.hairline.thickness 1 8
  $cfg.hairline.opacity   = Clamp $cfg.hairline.opacity 0.05 1
  $cfg.dot.enabled        = [bool] $cfg.dot.enabled
  $cfg.dot.size           = Clamp $cfg.dot.size 0 20
  $cfg.dot.opacity        = Clamp $cfg.dot.opacity 0 1
  $cfg.label.enabled      = [bool] $cfg.label.enabled
  $cfg.label.opacity      = Clamp $cfg.label.opacity 0 1
  $cfg.label.size         = Clamp $cfg.label.size 7 30
  if (-not (Test-HexColor ([string] $cfg.label.color))) { $cfg.label.color = '#C9D4E2' }
  $cfg.motion.fadeInMs     = Clamp $cfg.motion.fadeInMs 0 2000
  $cfg.motion.fadeOutMs    = Clamp $cfg.motion.fadeOutMs 0 2000
  $cfg.motion.colorTweenMs = Clamp $cfg.motion.colorTweenMs 0 2000
  $cfg.motion.pulseMs      = Clamp $cfg.motion.pulseMs 400 20000
  $cfg.motion.pulseDepth   = Clamp $cfg.motion.pulseDepth 0 0.9
  if (-not $cfg.Contains('typeAlphaScale')) { $cfg['typeAlphaScale'] = 1.0 }
  $cfg.typeAlphaScale      = Clamp $cfg.typeAlphaScale 0 1
  $cfg.quietMs             = Clamp $cfg.quietMs 0 10000
  $cfg.globalThrottleMs    = Clamp $cfg.globalThrottleMs 0 5000
  $cfg.pollMs              = Clamp $cfg.pollMs 40 2000
  $cfg.fallback.pollMs     = Clamp $cfg.fallback.pollMs 100 5000
  $cfg.sound.enabled       = [bool] $cfg.sound.enabled
  $cfg.sound.volume        = Clamp $cfg.sound.volume 0 1
  $cfg.dimWhenFullscreen   = [bool] $cfg.dimWhenFullscreen
  if (@('banner', 'minimal') -notcontains [string] $cfg.profile) { $cfg.profile = 'banner' }

  # 目标显示器归一化：primary / all / 数字序号（1,2,3...）
  $disp = ([string] $cfg.screen).Trim().ToLowerInvariant()
  if ($disp -ne 'primary' -and $disp -ne 'all' -and $disp -ne 'a' -and $disp -ne '*' -and -not ($disp -match '^\d+$')) {
    $cfg.screen = 'primary'
  }

  # 云朵造型参数：宽 = 屏幕宽的 1/10，云体完整显示（云窗比例 3:1）
  if (-not $cfg.Contains('cloud')) { $cfg['cloud'] = @{} }
  $cl = $cfg['cloud']
  if (-not ($cl -is [System.Collections.IDictionary])) { $cl = @{}; $cfg['cloud'] = $cl }
  if (-not $cl.Contains('widthFraction')) { $cl['widthFraction'] = 0.1 }
  $cl['widthFraction'] = Clamp $cl['widthFraction'] 0.05 0.5
  if (-not $cl.Contains('heightFraction')) { $cl['heightFraction'] = 0.056 }
  $cl['heightFraction'] = Clamp $cl['heightFraction'] 0.02 0.2
  if (-not $cl.Contains('opacity')) { $cl['opacity'] = 0.92 }
  $cl['opacity'] = Clamp $cl['opacity'] 0.05 1
  if (-not $cl.Contains('centerX')) { $cl['centerX'] = 0.5 }
  $cl['centerX'] = Clamp $cl['centerX'] 0 1
  if (-not $cl.Contains('labelInside')) { $cl['labelInside'] = $true }
  $cl['labelInside'] = [bool] $cl['labelInside']
  # 云贴图显示开关（关闭后不再显示任何祥云插图，提醒改由边框极光表达）
  if (-not $cl.Contains('enabled')) { $cl['enabled'] = $false }
  $cl['enabled'] = [bool] $cl['enabled']

  # 屏幕边框「极光能量场」参数
  if (-not $cfg.Contains('edgeGlow')) { $cfg['edgeGlow'] = @{} }
  $eg = $cfg['edgeGlow']
  if (-not ($eg -is [System.Collections.IDictionary])) { $eg = @{}; $cfg['edgeGlow'] = $eg }
  if (-not $eg.Contains('enabled')) { $eg['enabled'] = $true }
  $eg['enabled']     = [bool] $eg['enabled']
  if (-not $eg.Contains('borderPx')) { $eg['borderPx'] = 3 }
  $eg['borderPx']    = Clamp $eg['borderPx'] 1 12
  if (-not $eg.Contains('glowPx')) { $eg['glowPx'] = 30 }
  $eg['glowPx']      = Clamp $eg['glowPx'] 6 90
  if (-not $eg.Contains('sweepPx')) { $eg['sweepPx'] = 8 }
  $eg['sweepPx']     = Clamp $eg['sweepPx'] 2 30
  if (-not $eg.Contains('corePx')) { $eg['corePx'] = 2 }
  $eg['corePx']      = Clamp $eg['corePx'] 1 8
  if (-not $eg.Contains('cycleMs')) { $eg['cycleMs'] = 3000 }
  $eg['cycleMs']     = Clamp $eg['cycleMs'] 400 10000
  if (-not $eg.Contains('flowSpeed')) { $eg['flowSpeed'] = 0.42 }
  $eg['flowSpeed']   = Clamp $eg['flowSpeed'] 0.05 3.0
  if (-not $eg.Contains('cometTail')) { $eg['cometTail'] = 0.20 }
  $eg['cometTail']   = Clamp $eg['cometTail'] 0.04 0.5
  if (-not $eg.Contains('hueDrift')) { $eg['hueDrift'] = 6.0 }
  $eg['hueDrift']    = Clamp $eg['hueDrift'] -60 60
  if (-not $eg.Contains('opacity')) { $eg['opacity'] = 1.0 }
  $eg['opacity']     = Clamp $eg['opacity'] 0 1
  if (-not $eg.Contains('kindColors')) { $eg['kindColors'] = @{} }
  $eg['kindColors']  = $eg['kindColors']
  # 关键：目标屏默认主屏，绝不画到可能黑屏的副屏（除非用户显式指定）
  # （screen 的归一化在别处，这里不覆盖用户显式选择）

  # 故障红云参数：右上角尺寸、边距、透明度、泛红色
  if (-not $cfg.Contains('errorCloud')) { $cfg['errorCloud'] = @{} }
  $er = $cfg['errorCloud']
  if (-not ($er -is [System.Collections.IDictionary])) { $er = @{}; $cfg['errorCloud'] = $er }
  if (-not $er.Contains('enabled')) { $er['enabled'] = $true }
  $er['enabled'] = [bool] $er['enabled']
  if (-not $er.Contains('widthFraction')) { $er['widthFraction'] = 0.18 }
  $er['widthFraction'] = Clamp $er['widthFraction'] 0.05 0.5
  if (-not $er.Contains('opacity')) { $er['opacity'] = 0.92 }
  $er['opacity'] = Clamp $er['opacity'] 0.05 1
  if (-not $er.Contains('marginRight')) { $er['marginRight'] = 0.02 }
  $er['marginRight'] = Clamp $er['marginRight'] 0 0.3
  if (-not $er.Contains('marginTop')) { $er['marginTop'] = 0.03 }
  $er['marginTop'] = Clamp $er['marginTop'] 0 0.3
  if (-not (Test-HexColor ([string] $er['glowColor']))) { $er['glowColor'] = '#FF3030' }
  if (-not $er.Contains('glowOpacity')) { $er['glowOpacity'] = 0.22 }
  $er['glowOpacity'] = Clamp $er['glowOpacity'] 0 0.5

  # 完成任务绿云参数：屏幕左上角尺寸、边距、透明度
  if (-not $cfg.Contains('doneCloud')) { $cfg['doneCloud'] = @{} }
  $dc = $cfg['doneCloud']
  if (-not ($dc -is [System.Collections.IDictionary])) { $dc = @{}; $cfg['doneCloud'] = $dc }
  if (-not $dc.Contains('enabled')) { $dc['enabled'] = $true }
  $dc['enabled'] = [bool] $dc['enabled']
  if (-not $dc.Contains('widthFraction')) { $dc['widthFraction'] = 0.30 }
  $dc['widthFraction'] = Clamp $dc['widthFraction'] 0.05 0.6
  if (-not $dc.Contains('opacity')) { $dc['opacity'] = 0.92 }
  $dc['opacity'] = Clamp $dc['opacity'] 0.05 1
  if (-not $dc.Contains('marginLeft')) { $dc['marginLeft'] = 0.03 }
  $dc['marginLeft'] = Clamp $dc['marginLeft'] 0 0.4
  if (-not $dc.Contains('marginTop')) { $dc['marginTop'] = 0.03 }
  $dc['marginTop'] = Clamp $dc['marginTop'] 0 0.4
  # 完成任务绿云专属淡入/淡出时长（毫秒），比全局 motion 更长、更明显的淡入淡出过渡
  if (-not $dc.Contains('fadeInMs')) { $dc['fadeInMs'] = 700 }
  $dc['fadeInMs'] = Clamp $dc['fadeInMs'] 0 3000
  if (-not $dc.Contains('fadeOutMs')) { $dc['fadeOutMs'] = 900 }
  $dc['fadeOutMs'] = Clamp $dc['fadeOutMs'] 0 3000
  # 完成任务绿云泛光：质感与红云一致（glowColor / glowOpacity）
  if (-not (Test-HexColor ([string] $dc['glowColor']))) { $dc['glowColor'] = '#35D07F' }
  if (-not $dc.Contains('glowOpacity')) { $dc['glowOpacity'] = 0.14 }
  $dc['glowOpacity'] = Clamp $dc['glowOpacity'] 0 0.5

  # 「打开窗口自动收提醒」参数：开关 / 前台停留判定 / 匹配规则
  if (-not $cfg.Contains('autoDismiss')) { $cfg['autoDismiss'] = @{} }
  $ad = $cfg['autoDismiss']
  if (-not ($ad -is [System.Collections.IDictionary])) { $ad = @{}; $cfg['autoDismiss'] = $ad }
  if (-not $ad.Contains('enabled')) { $ad['enabled'] = $true }
  $ad['enabled'] = [bool] $ad['enabled']
  if (-not $ad.Contains('dwellMs')) { $ad['dwellMs'] = 800 }
  $ad['dwellMs'] = Clamp $ad['dwellMs'] 0 10000
  if (-not $ad.Contains('processMatch')) { $ad['processMatch'] = @('DeepSeek Harness') }
  if (-not $ad.Contains('titleMatch'))   { $ad['titleMatch']   = @('DeepSeek Harness') }

  $kindsOver = if ($obj.ContainsKey('kinds')) { $obj['kinds'] } else { @{} }
  if ($null -eq $kindsOver) { $kindsOver = @{} }
  $merged = [ordered] @{}
  foreach ($name in $Script:KindDefaults.Keys) {
    $base = $Script:KindDefaults[[string] $name]
    $o = if ($kindsOver.ContainsKey([string] $name)) { $kindsOver[[string] $name] } else { @{} }
    if ($null -eq $o -or $o -isnot [System.Collections.IDictionary]) { $o = @{} }
    $k = Get-Nested $base $o
    if (-not (Test-HexColor ([string] $k.color))) { $k.color = $base.color }
    $k.priority  = Clamp $k.priority 0 200
    $k.holdMs    = Clamp $k.holdMs 0 3600000
    $k.maxHoldMs = Clamp $k.maxHoldMs 1000 7200000
    $k.pulse     = [bool] $k.pulse
    $k.label     = [string] $k.label
    $k.labelEn   = [string] $k.labelEn
    $k.sound     = [string] $k.sound
    $merged[[string] $name] = $k
  }

  $Script:Cfg = $cfg
  $Script:Kinds = $merged
  $Script:CfgStamp = (Get-Item -LiteralPath $ConfigPath).LastWriteTimeUtc
  return $true
}

if (-not (Read-Config)) {
  Write-AssistLog "no usable config at $ConfigPath; using built-in defaults"
  $Script:Cfg = Get-Nested $Script:Defaults @{}
  $Script:Kinds = [ordered] @{}
  foreach ($n in $Script:KindDefaults.Keys) { $Script:Kinds[[string] $n] = [hashtable] $Script:KindDefaults[[string] $n] }
}

if ([string]::IsNullOrWhiteSpace($SignalPath)) {
  $SignalPath = if (-not [string]::IsNullOrWhiteSpace([string] $Script:Cfg.fallback.signalFile)) {
    [string] $Script:Cfg.fallback.signalFile
  } else { Join-Path $StateDir 'signal.jsonl' }
}
$SnapshotPath = Join-Path $StateDir 'snapshot.json'

function Get-ViewCfg {
  $c = $Script:Cfg
  if ([string] $c.profile -ne 'minimal') {
    return @{ backdrop = $c.backdrop; hairline = $c.hairline; dot = $c.dot; label = $c.label; motion = $c.motion
             typeAlphaScale = $c.typeAlphaScale }
  }
  $m = $c.minimal
  return @{
    backdrop = @{ enabled = $c.backdrop.enabled; color = $c.backdrop.color; opacity = [double] $m.backdrop.opacity; height = [double] $m.height }
    hairline = @{ enabled = $true; thickness = [double] $m.hairline.thickness; opacity = $c.hairline.opacity }
    dot      = @{ enabled = [bool] $m.dot.enabled; size = $c.dot.size; opacity = $c.dot.opacity }
    label    = @{ enabled = [bool] $m.label.enabled; font = $c.label.font; size = $c.label.size; opacity = $c.label.opacity
                  color = $c.label.color; showTime = $c.label.showTime; showSession = $c.label.showSession; paddingLeft = $c.label.paddingLeft }
    motion   = $c.motion
    typeAlphaScale = $c.typeAlphaScale
  }
}

# ---------------------------------------------------------------------------
# 2. DPI 与几何
#    SystemParameters.*ScreenWidth 已经是 WPF 设备无关像素，直接用最稳；
#    P/Invoke 只用于日志，失败也不影响任何功能。
# ---------------------------------------------------------------------------
# 多显示器定位：返回目标显示器的物理边界 { L, T, R, B, W, H }
#   screen 取值:
#     primary      → 主显示器
#     all / a / *  → 整个虚拟桌面（跨所有显示器铺满）
#     1,2,3,...    → 按物理排列序号（从左到右、同列从上到下）
#   其余(空/非法)  → 主显示器
function Get-DisplayRect {
  $screens = @( [System.Windows.Forms.Screen]::AllScreens )
  $sorted  = @( $screens | Sort-Object @{ Expression = { $_.Bounds.X } }, @{ Expression = { $_.Bounds.Y } } )
  $primary = @( $sorted | Where-Object { $_.Primary } )
  if ($primary.Count -eq 0) { $primary = $sorted }
  if ($screens.Count -eq 0) {
    return @{ L = 0; T = 0; R = 1920; B = 1080; W = 1920; H = 1080; Device = 'DEFAULT' }
  }

  $t = ''
  if ($null -ne $Script:Cfg) { $t = ([string] $Script:Cfg.screen).Trim().ToLowerInvariant() }
  if ([string]::IsNullOrWhiteSpace($t)) { $t = 'primary' }

  if ($t -eq 'all' -or $t -eq 'a' -or $t -eq '*') {
    $vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
    if ($null -eq $vs) { $vs = $sorted[0].Bounds }
    return @{ L = $vs.X; T = $vs.Y; R = $vs.Right; B = $vs.Bottom; W = $vs.Width; H = $vs.Height; Device = 'ALL' }
  }
  if ($t -match '^\d+$') {
    $idx = [int] $t
    if ($idx -ge 1 -and $idx -le $sorted.Count) {
      $s = $sorted[$idx - 1]
      return @{ L = $s.Bounds.X; T = $s.Bounds.Y; R = $s.Bounds.Right; B = $s.Bounds.Bottom; W = $s.Bounds.Width; H = $s.Bounds.Height; Device = $s.DeviceName }
    }
    $s = $primary[0]
    return @{ L = $s.Bounds.X; T = $s.Bounds.Y; R = $s.Bounds.Right; B = $s.Bounds.Bottom; W = $s.Bounds.Width; H = $s.Bounds.Height; Device = $s.DeviceName }
  }
  # primary（默认）
  $s = $primary[0]
  return @{ L = $s.Bounds.X; T = $s.Bounds.Y; R = $s.Bounds.Right; B = $s.Bounds.Bottom; W = $s.Bounds.Width; H = $s.Bounds.Height; Device = $s.DeviceName }
}

try { $dpi = [DshRem.Native]::DpiX() } catch { $dpi = 96 }
$toDip = 96.0 / [double] $dpi
foreach ($s in [System.Windows.Forms.Screen]::AllScreens) { Write-AssistLog ("screen: {0} {1}" -f $s.DeviceName, $s.Bounds) }
$Script:PhysRect = Get-DisplayRect
try {
  $Script:BandWidthDip = [double] ([System.Windows.Forms.SystemInformation]::VirtualScreen.Width)
  if ($Script:BandWidthDip -le 0 -or $Script:BandWidthDip -gt 40000) { throw 'bad width' }
} catch {
  $Script:BandWidthDip = [double] $Script:PhysRect.W * $toDip
}
Write-AssistLog ("display target={0} rect=({1},{2})-({3},{4}) dpi={5} toDip={6:N3} widthDip={7:N1}" -f $Script:PhysRect.Device, $Script:PhysRect.L, $Script:PhysRect.T, $Script:PhysRect.R, $Script:PhysRect.B, $dpi, $toDip, $Script:BandWidthDip)

# ---------------------------------------------------------------------------
# 3. WPF 元素 —— 每条“通道”一个独立窗口，可同时显示、互不覆盖
#    done    → 绿色祥云，屏幕左上角
#    waiting → 金色祥云（approval / question / waiting），屏幕顶部居中
#    error   → 红色祥云（error / blocked），屏幕右上角
# ---------------------------------------------------------------------------
function New-LaneWindow([string] $title, [string] $position, [string[]] $kinds) {
  $w = New-Object System.Windows.Window
  $w.WindowStyle = 'None'
  $w.ResizeMode = 'NoResize'
  $w.AllowsTransparency = $true
  $w.ShowActivated = $false
  $w.ShowInTaskbar = $false
  $w.Topmost = $true
  $w.Title = $title
  $w.WindowStartupLocation = 'Manual'
  $w.Background = [System.Windows.Media.Brushes]::Transparent
  $w.UseLayoutRounding = $true
  $w.SnapsToDevicePixels = $true
  $c = New-Object System.Windows.Controls.Canvas
  $c.IsHitTestVisible = $false
  $w.Content = $c
  $img = New-Object System.Windows.Controls.Image
  $img.Stretch = [System.Windows.Media.Stretch]::Uniform
  $img.SnapsToDevicePixels = $true
  $img.Visibility = [System.Windows.Visibility]::Collapsed
  $c.Children.Add($img) | Out-Null
  return @{ key = $position; position = $position; kinds = $kinds
            window = $w; canvas = $c; image = $img
            shown = $null; lastSwitch = 0; prevRgb = $null; alphaType = 0.0 }
}

$doneLane    = New-LaneWindow 'dsh-rainbow-done'    'done'    @('done')
$waitingLane = New-LaneWindow 'dsh-rainbow-waiting' 'waiting' @('approval', 'question', 'waiting')
$errorLane   = New-LaneWindow 'dsh-rainbow-error'   'error'   @('error', 'blocked')
$Script:Lanes = @($doneLane, $waitingLane, $errorLane)

# 向后兼容别名：自检截图沿用主通道（等待通道）窗口
$Window = $waitingLane.window
$Canvas = $waitingLane.canvas

# =============================================================================
# 屏幕边框「极光能量场」—— 惊艳版（第一性原理重构）
# -----------------------------------------------------------------------------
# 惊艳不来自「更多动画」，而来自物理真实感：
#   1) 色温对比   白热核心 + 冷色拖尾（能量感源于色温差，非单色渐变）
#   2) 多层 bloom  同一彗星笔刷由三种尺寸/透明度叠加：宽光晕 + 主色带 + 2px 过曝核
#   3) 事件感      双向彗星（顺/逆时针）对冲，相遇瞬间爆发闪光，打破匀速的腻感
#   4) 极光色相   色相随时间缓慢漂移 + 沿彗尾加深（HSV 生成，非固定 RGB）
#   5) 流畅度      动画与信号轮询解耦，独立 30fps 定时器（旧版 8fps 是最大短板）
#   6) 角点共鸣   四角节点感应彗星临近而放大/增亮
# 历史教训（不得再犯）：
#   · 单窗口；每个 Rectangle 显式 Width/Height（杜绝 Canvas 子元素 0×0）
#   · 减法先算成变量，绝不写进 @(...)/@{...} 字面量（会被解析成数组减法而崩）
#   · 每帧只改 GradientStop.Color；LinearGradientBrush 没有 Viewport/Tag；不 Freeze
#   · 一个彗星笔刷被 3 个矩形共享（RelativeToBoundingBox），开销极低
# =============================================================================

# HSV -> RGB（h:0..360, s/v:0..1）；用于极光色相生成
function Convert-HsvToRgb([double] $h, [double] $s, [double] $v) {
  $hh = $h % 360.0
  if ($hh -lt 0) { $hh = $hh + 360.0 }
  $c = $v * $s
  $x = $c * (1.0 - [Math]::Abs((($hh / 60.0) % 2.0) - 1.0))
  $m = $v - $c
  $seg = [int][Math]::Floor($hh / 60.0)
  $rr = 0.0; $gg = 0.0; $bb = 0.0
  switch ($seg) {
    0 { $rr = $c; $gg = $x; $bb = 0.0 }
    1 { $rr = $x; $gg = $c; $bb = 0.0 }
    2 { $rr = 0.0; $gg = $c; $bb = $x }
    3 { $rr = 0.0; $gg = $x; $bb = $c }
    4 { $rr = $x; $gg = 0.0; $bb = $c }
    default { $rr = $c; $gg = 0.0; $bb = $x }
  }
  $r = [int][Math]::Round(($rr + $m) * 255)
  $g = [int][Math]::Round(($gg + $m) * 255)
  $b = [int][Math]::Round(($bb + $m) * 255)
  if ($r -gt 255) { $r = 255 }; if ($g -gt 255) { $g = 255 }; if ($b -gt 255) { $b = 255 }
  return @($r, $g, $b)
}

# RGB -> 色相（把用户配置的主色换算成极光基准色相）
function Convert-RgbToHue([int[]] $rgb) {
  $r = [double] $rgb[0] / 255.0
  $g = [double] $rgb[1] / 255.0
  $b = [double] $rgb[2] / 255.0
  $mx = [Math]::Max($r, [Math]::Max($g, $b))
  $mn = [Math]::Min($r, [Math]::Min($g, $b))
  $d = $mx - $mn
  if ($d -le 0.0001) { return 0.0 }
  $h = 0.0
  if ($mx -eq $r) { $h = 60.0 * ((($g - $b) / $d) % 6.0) }
  elseif ($mx -eq $g) { $h = 60.0 * ((($b - $r) / $d) + 2.0) }
  else { $h = 60.0 * ((($r - $g) / $d) + 4.0) }
  if ($h -lt 0) { $h = $h + 360.0 }
  return $h
}

function New-BorderFlashWindow {
  $w = New-Object System.Windows.Window
  $w.WindowStyle = 'None'
  $w.ResizeMode = 'NoResize'
  $w.AllowsTransparency = $true
  $w.ShowActivated = $false
  $w.ShowInTaskbar = $false
  $w.Topmost = $true
  $w.Title = 'dsh-rainbow-borderflash'
  $w.WindowStartupLocation = 'Manual'
  $w.Background = [System.Windows.Media.Brushes]::Transparent
  $w.IsHitTestVisible = $false
  $w.Opacity = 0

  $canvas = New-Object System.Windows.Controls.Canvas
  $canvas.IsHitTestVisible = $false
  $canvas.ClipToBounds = $false
  $w.Content = $canvas

  $edges = @(
    @{ key='Top';    horiz=$true  },
    @{ key='Right';  horiz=$false },
    @{ key='Bottom'; horiz=$true  },
    @{ key='Left';   horiz=$false }
  )
  $NSTOP = 32
  # 绘制顺序（后加的在上）：常亮底线 -> 宽光晕 -> 主色带 -> 过曝核
  foreach ($e in $edges) {
    # 1) 常亮底线（极淡，始终在场）
    $base = New-Object System.Windows.Shapes.Rectangle
    $base.IsHitTestVisible = $false
    $base.Fill = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(0,0,0,0))
    $canvas.Children.Add($base) | Out-Null
    $e.baseRect = $base

    # 彗星笔刷（被下面 3 个矩形共享）
    $brush = New-Object System.Windows.Media.LinearGradientBrush
    if ($e.horiz) {
      $brush.StartPoint = New-Object System.Windows.Point -ArgumentList 0,0
      $brush.EndPoint   = New-Object System.Windows.Point -ArgumentList 1,0
    } else {
      $brush.StartPoint = New-Object System.Windows.Point -ArgumentList 0,0
      $brush.EndPoint   = New-Object System.Windows.Point -ArgumentList 0,1
    }
    $brush.MappingMode = [System.Windows.Media.BrushMappingMode]::RelativeToBoundingBox
    $brush.SpreadMethod = [System.Windows.Media.GradientSpreadMethod]::Pad
    for ($i = 0; $i -lt $NSTOP; $i++) {
      $off = $i / ($NSTOP - 1)
      $brush.GradientStops.Add((New-Object System.Windows.Media.GradientStop([System.Windows.Media.Color]::FromArgb(0,0,0,0), $off)))
    }

    # 2) 宽光晕（30px，低透明）
    $halo = New-Object System.Windows.Shapes.Rectangle
    $halo.IsHitTestVisible = $false
    $halo.Fill = $brush
    $halo.Opacity = 0.28
    $canvas.Children.Add($halo) | Out-Null
    $e.haloRect = $halo

    # 3) 主色带（8px）
    $sweep = New-Object System.Windows.Shapes.Rectangle
    $sweep.IsHitTestVisible = $false
    $sweep.Fill = $brush
    $sweep.Opacity = 1.0
    $canvas.Children.Add($sweep) | Out-Null
    $e.sweepRect = $sweep

    # 4) 过曝核（2px，白热细线）
    $core = New-Object System.Windows.Shapes.Rectangle
    $core.IsHitTestVisible = $false
    $core.Fill = $brush
    $core.Opacity = 0.95
    $canvas.Children.Add($core) | Out-Null
    $e.coreRect = $core

    $e.brush = $brush
    $e.nstop = $NSTOP
  }

  # 四角 HUD 节点（各自独立笔刷，便于单独调色/脉冲）
  $corners = @()
  for ($i = 0; $i -lt 4; $i++) {
    $c = New-Object System.Windows.Shapes.Rectangle
    $c.IsHitTestVisible = $false
    $c.Width = 9; $c.Height = 9
    $c.Fill = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(0,0,0,0))
    $canvas.Children.Add($c) | Out-Null
    $corners += $c
  }

  return @{
    window  = $w
    canvas  = $canvas
    edges   = $edges
    corners = $corners
    shown   = $false
    colorKey = ''
    widthKey = -1
    baseHue = 190.0
    rgb     = @(56,232,255)
  }
}

# 单窗口
$Script:BorderFlash = New-BorderFlashWindow
$Script:GlowShown = $false

# 几何布局：四条边 × 4 层，全部显式尺寸（减法先算成变量，避免数组减法崩溃）
function Layout-BorderFlash($bf, [double] $sw, [double] $sh, [double] $basePx, [double] $haloPx, [double] $sweepPx, [double] $corePx) {
  $rX = $sw - $basePx;  $bY = $sh - $basePx
  $hRX = $sw - $haloPx; $hBY = $sh - $haloPx
  $sRX = $sw - $sweepPx; $sBY = $sh - $sweepPx
  $cRX = $sw - $corePx;  $cBY = $sh - $corePx
  $cornerR = $sw - 9; $cornerB = $sh - 9

  foreach ($e in $bf.edges) {
    $k = $e.key
    if ($k -eq 'Top') {
      $e.baseRect.Width=$sw;  $e.baseRect.Height=$basePx;  [System.Windows.Controls.Canvas]::SetLeft($e.baseRect,0);    [System.Windows.Controls.Canvas]::SetTop($e.baseRect,0)
      $e.haloRect.Width=$sw;  $e.haloRect.Height=$haloPx;  [System.Windows.Controls.Canvas]::SetLeft($e.haloRect,0);    [System.Windows.Controls.Canvas]::SetTop($e.haloRect,0)
      $e.sweepRect.Width=$sw; $e.sweepRect.Height=$sweepPx; [System.Windows.Controls.Canvas]::SetLeft($e.sweepRect,0);   [System.Windows.Controls.Canvas]::SetTop($e.sweepRect,0)
      $e.coreRect.Width=$sw;  $e.coreRect.Height=$corePx;  [System.Windows.Controls.Canvas]::SetLeft($e.coreRect,0);    [System.Windows.Controls.Canvas]::SetTop($e.coreRect,0)
    } elseif ($k -eq 'Bottom') {
      $e.baseRect.Width=$sw;  $e.baseRect.Height=$basePx;  [System.Windows.Controls.Canvas]::SetLeft($e.baseRect,0); [System.Windows.Controls.Canvas]::SetTop($e.baseRect,$bY)
      $e.haloRect.Width=$sw;  $e.haloRect.Height=$haloPx;  [System.Windows.Controls.Canvas]::SetLeft($e.haloRect,0); [System.Windows.Controls.Canvas]::SetTop($e.haloRect,$hBY)
      $e.sweepRect.Width=$sw; $e.sweepRect.Height=$sweepPx;[System.Windows.Controls.Canvas]::SetLeft($e.sweepRect,0);[System.Windows.Controls.Canvas]::SetTop($e.sweepRect,$sBY)
      $e.coreRect.Width=$sw;  $e.coreRect.Height=$corePx;  [System.Windows.Controls.Canvas]::SetLeft($e.coreRect,0); [System.Windows.Controls.Canvas]::SetTop($e.coreRect,$cBY)
    } elseif ($k -eq 'Left') {
      $e.baseRect.Width=$basePx;  $e.baseRect.Height=$sh;  [System.Windows.Controls.Canvas]::SetLeft($e.baseRect,0); [System.Windows.Controls.Canvas]::SetTop($e.baseRect,0)
      $e.haloRect.Width=$haloPx;  $e.haloRect.Height=$sh;  [System.Windows.Controls.Canvas]::SetLeft($e.haloRect,0); [System.Windows.Controls.Canvas]::SetTop($e.haloRect,0)
      $e.sweepRect.Width=$sweepPx; $e.sweepRect.Height=$sh; [System.Windows.Controls.Canvas]::SetLeft($e.sweepRect,0);[System.Windows.Controls.Canvas]::SetTop($e.sweepRect,0)
      $e.coreRect.Width=$corePx;  $e.coreRect.Height=$sh;  [System.Windows.Controls.Canvas]::SetLeft($e.coreRect,0); [System.Windows.Controls.Canvas]::SetTop($e.coreRect,0)
    } else {
      $e.baseRect.Width=$basePx;  $e.baseRect.Height=$sh;  [System.Windows.Controls.Canvas]::SetLeft($e.baseRect,$rX); [System.Windows.Controls.Canvas]::SetTop($e.baseRect,0)
      $e.haloRect.Width=$haloPx;  $e.haloRect.Height=$sh;  [System.Windows.Controls.Canvas]::SetLeft($e.haloRect,$hRX); [System.Windows.Controls.Canvas]::SetTop($e.haloRect,0)
      $e.sweepRect.Width=$sweepPx; $e.sweepRect.Height=$sh; [System.Windows.Controls.Canvas]::SetLeft($e.sweepRect,$sRX);[System.Windows.Controls.Canvas]::SetTop($e.sweepRect,0)
      $e.coreRect.Width=$corePx;  $e.coreRect.Height=$sh;  [System.Windows.Controls.Canvas]::SetLeft($e.coreRect,$cRX); [System.Windows.Controls.Canvas]::SetTop($e.coreRect,0)
    }
  }
  $cpos = @( @(0,0), @($cornerR,0), @($cornerR,$cornerB), @(0,$cornerB) )
  for ($i = 0; $i -lt 4; $i++) {
    [System.Windows.Controls.Canvas]::SetLeft($bf.corners[$i], $cpos[$i][0])
    [System.Windows.Controls.Canvas]::SetTop($bf.corners[$i], $cpos[$i][1])
  }
}

# 颜色变化时重建常亮底线/角点笔刷并缓存基准色相
function Apply-BorderFlashStyle($bf, [int[]] $rgb) {
  $key = ($rgb -join ',')
  if ($bf.colorKey -ne $key) {
    $r = [byte] $rgb[0]; $g = [byte] $rgb[1]; $b = [byte] $rgb[2]
    $baseBrush = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(34,$r,$g,$b))
    foreach ($e in $bf.edges) { $e.baseRect.Fill = $baseBrush }
    foreach ($c in $bf.corners) {
      $c.Fill = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(200,$r,$g,$b))
    }
    $bf.colorKey = $key
    $bf.rgb = $rgb
    $bf.baseHue = Convert-RgbToHue $rgb
  }
}

# 统一彗星绘制：dir=+1 顺时针 / -1 逆时针；blend=true 时按 alpha 取更亮叠加
function Paint-Comet($e, [double] $cometT, [double] $tailLen, [double] $hue, [double] $intensity, [double] $edgeStartT, [double] $edgeSpanT, [int] $dir, [bool] $blend, [double] $whiteBoost) {
  $st = $e.brush.GradientStops
  $n = $e.nstop
  for ($i = 0; $i -lt $n; $i++) {
    $local = $i / ($n - 1)
    $tOnPerim = $edgeStartT + $local * $edgeSpanT
    $d = $dir * ($cometT - $tOnPerim)
    if ($d -lt 0) { $d = $d + 1.0 }
    if ($d -gt $tailLen) {
      if (-not $blend) { $st[$i].Color = [System.Windows.Media.Color]::FromArgb(0,0,0,0) }
      continue
    }
    $frac = 1.0 - ($d / $tailLen)
    $a = [int][Math]::Round(255 * $frac * $frac * $intensity)
    if ($a -lt 0) { $a = 0 }; if ($a -gt 255) { $a = 255 }
    # 单色锁定：色相沿彗尾不变，仅饱和度渐变（头部趋白 = 科技感白核）
    $hh = $hue
    $sat = 0.88 - 0.30 * $frac
    $c = Convert-HsvToRgb $hh $sat 1.0
    # 白热核心
    $wt = $frac * $frac * $whiteBoost
    if ($wt -gt 1.0) { $wt = 1.0 }
    $cr = [int][Math]::Min(255, $c[0] + (255 - $c[0]) * $wt)
    $cg = [int][Math]::Min(255, $c[1] + (255 - $c[1]) * $wt)
    $cb = [int][Math]::Min(255, $c[2] + (255 - $c[2]) * $wt)
    if ($blend) {
      $cur = $st[$i].Color
      if ($a -le $cur.A) { continue }
    }
    $st[$i].Color = [System.Windows.Media.Color]::FromArgb([byte]$a, [byte]$cr, [byte]$cg, [byte]$cb)
  }
}

function New-AlphaBrush([int[]] $rgb, [double] $a) {
  if ($a -lt 0) { $a = 0 } elseif ($a -gt 1) { $a = 1 }
  $al = [byte] [int] [Math]::Round($a * 255)
  $col = [System.Windows.Media.Color]::FromArgb($al, [byte] $rgb[0], [byte] $rgb[1], [byte] $rgb[2])
  return New-Object System.Windows.Media.SolidColorBrush $col
}

# 每条通道的窗口在 New-LaneWindow 中自带独立 Image（$lane.image），
# 旧版单窗口的“色带 + 单一 $CloudImage”元素已移除：多通道并行显示互不覆盖。
$Script:CloudTex = $null
$Script:CloudTexRatio = 1.5
# 红色贴图（报错/阻塞时用，显示在右上角）
$Script:CloudTexRed = $null
$Script:CloudTexRedRatio = 1.778
# 绿色祥云贴图（任务完成 done 时用，显示在屏幕左上角）
$Script:CloudTexDone = $null
$Script:CloudTexDoneRatio = 1.778
try {
  # 透明底贴图（金色祥云 + 电路纹 + 粒子，无背景、无水印）
  $texPath = Join-Path $ScriptRoot 'assets\cloud-keyed.png'
  if (Test-Path -LiteralPath $texPath) {
    $bi = New-Object System.Windows.Media.Imaging.BitmapImage
    $bi.BeginInit()
    $bi.UriSource = New-Object System.Uri($texPath, [System.UriKind]::Absolute)
    $bi.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
    $bi.EndInit()
    $bi.Freeze()
    $Script:CloudTex = $bi
    if ($bi.PixelHeight -gt 0) { $Script:CloudTexRatio = [double] $bi.PixelWidth / [double] $bi.PixelHeight }
    Write-AssistLog ("cloud texture loaded {0}x{1} ratio={2:N3}" -f $bi.PixelWidth, $bi.PixelHeight, $Script:CloudTexRatio)
  } else {
    Write-AssistLog ("cloud texture missing: {0}" -f $texPath)
  }
} catch { Write-AssistLog ("cloud texture load failed: {0}" -f $_.Exception.Message) }

try {
  # 红色祥云贴图（任务无法继续 / 报错），独立加载
  $redPath = Join-Path $ScriptRoot 'assets\cloud-red-keyed.png'
  if (Test-Path -LiteralPath $redPath) {
    $ri = New-Object System.Windows.Media.Imaging.BitmapImage
    $ri.BeginInit()
    $ri.UriSource = New-Object System.Uri($redPath, [System.UriKind]::Absolute)
    $ri.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
    $ri.EndInit()
    $ri.Freeze()
    $Script:CloudTexRed = $ri
    if ($ri.PixelHeight -gt 0) { $Script:CloudTexRedRatio = [double] $ri.PixelWidth / [double] $ri.PixelHeight }
    Write-AssistLog ("red cloud texture loaded {0}x{1} ratio={2:N3}" -f $ri.PixelWidth, $ri.PixelHeight, $Script:CloudTexRedRatio)
  } else {
    Write-AssistLog ("red cloud texture missing: {0}" -f $redPath)
  }
} catch { Write-AssistLog ("red cloud texture load failed: {0}" -f $_.Exception.Message) }

try {
  # 绿色祥云贴图（任务完成 done，显示在屏幕左上角），独立加载
  $donePath = Join-Path $ScriptRoot 'assets\cloud-done-keyed.png'
  if (Test-Path -LiteralPath $donePath) {
    $di = New-Object System.Windows.Media.Imaging.BitmapImage
    $di.BeginInit()
    $di.UriSource = New-Object System.Uri($donePath, [System.UriKind]::Absolute)
    $di.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
    $di.EndInit()
    $di.Freeze()
    $Script:CloudTexDone = $di
    if ($di.PixelHeight -gt 0) { $Script:CloudTexDoneRatio = [double] $di.PixelWidth / [double] $di.PixelHeight }
    Write-AssistLog ("done cloud texture loaded {0}x{1} ratio={2:N3}" -f $di.PixelWidth, $di.PixelHeight, $Script:CloudTexDoneRatio)
  } else {
    Write-AssistLog ("done cloud texture missing: {0}" -f $donePath)
  }
} catch { Write-AssistLog ("done cloud texture load failed: {0}" -f $_.Exception.Message) }

# ---------------------------------------------------------------------------
# 4. 状态机
# ---------------------------------------------------------------------------
$Script:Active = @{}
$Script:LastSeen = @{}
$Script:SeqSeen = 0
$Script:Muted = $false
$Script:Stop = $false

function Now-Ms { return [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }

function Get-KindConfig([string] $kind) {
  if ($Script:Kinds.Contains([string] $kind)) { return $Script:Kinds[[string] $kind] }
  return $Script:Kinds['default']
}

function Signal-Key([string] $kind, [string] $sid, [string] $cid) {
  if ($kind -in @('approval', 'question', 'waiting', 'done', 'error', 'blocked')) {
    if ($cid) { return "$kind|cid|$cid" }
    if ($sid) { return "$kind|sid|$sid" }
  }
  return "$kind|g"
}

function Add-Signal($ev) {
  $kind = [string] $ev.kind
  if ([string]::IsNullOrWhiteSpace($kind) -or -not $Script:Kinds.Contains($kind)) { $kind = 'default' }
  # 云只表达"要人"的三类：等待授权 / 等待回答 / 等待处理；其余信号直接忽略
  if (-not (Test-CloudKind $kind)) { return }
  $kc = Get-KindConfig $kind
  $sid = [string] $ev.sessionId
  # 宿主端写入字段为 `id`；助手端兼容读取 `callId`（新）或 `id`（宿主写入）
  if ($null -ne $ev.callId -and [string] $ev.callId -ne '') { $cid = [string] $ev.callId }
  else { $cid = [string] $ev.id }
  $now = Now-Ms

  # 会话级去抖：同一类型同一会话在 quietMs 内只算一次
  $dk = "$kind|$sid"
  if ($Script:LastSeen.ContainsKey($dk) -and ($now - $Script:LastSeen[$dk]) -lt [double] $Script:Cfg.quietMs) { return }
  $Script:LastSeen[$dk] = $now

  $key = Signal-Key $kind $sid $cid
  $hold = [double] $kc.holdMs
  $Script:Active[$key] = @{
    key = $key; kind = $kind; kc = $kc; sessionId = $sid; callId = $cid; text = [string] $ev.text
    at = $now; arrivedAt = Get-Date
    expires = if ($hold -gt 0) { $now + $hold } else { [int64]::MaxValue }
    hardExpiry = $now + [double] $kc.maxHoldMs
    priority = [double] $kc.priority
  }
  if ($kc.sound -ne 'none' -and -not $Script:Muted -and [bool] $Script:Cfg.sound.enabled) { Play-KindSound ([string] $kc.sound) }
  Write-AssistLog ("signal kind={0} key={1} active={2}" -f $kind, $key, $Script:Active.Count)
  Update-Target
}

function Test-ResolveMatch($e, [string] $target, [string] $sid, [string] $cid) {
  if ($target -and $e.kind -ne $target) { return $false }
  if ($cid -and $e.callId) { return ($e.callId -eq $cid) }
  if ($sid) { return ($e.sessionId -eq $sid) }
  return $true                      # 无范围信息 = 该类全局解除
}

function Resolve-Signal($ev) {
  $target = [string] $ev.target
  if ($target) { if (-not $Script:Kinds.Contains($target)) { $target = 'default' } }
  $sid = [string] $ev.sessionId
  # 宿主 resolve 信号写入 `id` 字段；兼容读取 `callId` 或 `id`
  if ($null -ne $ev.callId -and [string] $ev.callId -ne '') { $cid = [string] $ev.callId }
  else { $cid = [string] $ev.id }
  $drop = @()
  foreach ($k in @($Script:Active.Keys)) {
    if (Test-ResolveMatch $Script:Active[$k] $target $sid $cid) { $drop += $k }
  }
  foreach ($k in $drop) { $Script:Active.Remove($k) }
  if ($drop.Count -gt 0) {
    Write-AssistLog ("resolve target={0} removed={1} active={2}" -f $target, $drop.Count, $Script:Active.Count)
    Update-Target
  }
}

function Clear-All {
  $Script:Active.Clear()
  Update-Target
  Render
}

# ---------------------------------------------------------------------------
# 「打开 DSH 窗口看过就收提醒」
#   前台窗口命中 autoDismiss.processMatch / titleMatch 时，逐条解除已亮满
#   dwellMs 的提醒；刚到的提醒照常显示满 dwellMs，避免"正在窗口里干活时
#   新报错被秒吞"。人不在 DSH 窗口里时提醒照旧常驻，直到被 resolve。
# ---------------------------------------------------------------------------
$Script:DismissHandle = [IntPtr]::Zero
$Script:DismissSince  = 0
$Script:DismissKeys   = $null
$Script:NextDismissDbgMs = 0

function Get-ForegroundInfo {
  try {
    $h = [DshRem.Native]::GetForegroundWindow()
    if ($h -eq [IntPtr]::Zero) { return $null }
    $len = [DshRem.Native]::GetWindowTextLength($h)
    $sb = New-Object System.Text.StringBuilder ($len + 4)
    [void] [DshRem.Native]::GetWindowText($h, $sb, $sb.Capacity)
    $wpid = 0
    [void] [DshRem.Native]::GetWindowThreadProcessId($h, [ref] $wpid)
    $pname = ''
    if ($wpid -gt 0) {
      try { $pname = [string] (Get-Process -Id $wpid -ErrorAction Stop).ProcessName } catch { $pname = '' }
    }
    return @{ handle = $h; title = $sb.ToString(); pid = $wpid; process = $pname }
  } catch { return $null }
}

function Test-DshWindow($info) {
  if ($null -eq $info) { return $false }
  $ad = $Script:Cfg['autoDismiss']
  if ($null -eq $ad -or $ad -isnot [System.Collections.IDictionary]) { return $false }
  $procs = @($ad['processMatch'])
  foreach ($pat in $procs) {
    $p = [string] $pat
    if ([string]::IsNullOrWhiteSpace($p)) { continue }
    if (([string] $info.process).IndexOf($p, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { return $true }
  }
  $titles = @($ad['titleMatch'])
  foreach ($pat in $titles) {
    $p = [string] $pat
    if ([string]::IsNullOrWhiteSpace($p)) { continue }
    if (([string] $info.title).IndexOf($p, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { return $true }
  }
  return $false
}

function Reset-DismissState {
  $Script:DismissHandle = [IntPtr]::Zero
  $Script:DismissSince  = 0
  $Script:DismissKeys   = $null
}

# 让 snapshot.json 与本地状态一致：自动收掉的提醒不该在助手重启后又冒出来
function Clear-Snapshot {
  try {
    @{ at = (Now-Ms); pending = @() } | ConvertTo-Json -Compress | Set-Content -LiteralPath $SnapshotPath -Encoding UTF8
  } catch { }
}

function Update-AutoDismiss {
  $ad = $Script:Cfg['autoDismiss']
  if ($null -eq $ad -or $ad -isnot [System.Collections.IDictionary] -or -not [bool] $ad['enabled']) { Reset-DismissState; return }
  if ($Script:Active.Count -eq 0) { Reset-DismissState; return }
  $info = Get-ForegroundInfo
  if (-not (Test-DshWindow $info)) { Reset-DismissState; return }

  $now = Now-Ms
  $dwell = [double] $ad['dwellMs']
  $Script:DismissHandle = $info.handle

  # 人在 DSH 窗口里：凡是已经亮够 dwellMs 的提醒都算"看过了"，逐条收掉。
  # 刚到的提醒仍会完整显示满 dwellMs，不会被秒吞。
  $removed = 0
  foreach ($k in @($Script:Active.Keys)) {
    $e = $Script:Active[$k]
    if ($null -eq $e) { continue }
    if (($now - [double] $e.at) -ge $dwell) { $Script:Active.Remove($k); $removed++ }
  }
  if ($removed -gt 0) {
    Write-AssistLog ("auto dismiss: DSH window in front ({0}) cleared={1} active={2}" -f ([string] $info.title), $removed, $Script:Active.Count)
    Update-Target
    Render
    Clear-Snapshot
  }
}

# 依据信号类型归入对应通道：done→绿云 / waiting→金云 / error→红云
function Get-LaneFor([string] $kind) {
  foreach ($lane in $Script:Lanes) {
    if ($lane.kinds -contains $kind) { return $lane }
  }
  return $null
}

# 某条通道内部的“最高优先级条目”（按 priority 降序、at 升序），与全局无关
function Pick-Top($lane) {
  $arr = @($Script:Active.Values | Where-Object { $lane.kinds -contains $_.kind } | Sort-Object @{ Expression = { $_.priority }; Descending = $true }, @{ Expression = { $_.at } })
  if ($arr.Count -eq 0) { return $null }
  return $arr[0]
}

# 单通道目标切换：只影响本通道的 shown，不影响其它通道（各通道并行显示）
function Update-Lane($lane) {
  $top = Pick-Top $lane
  $now = Now-Ms
  if ($null -eq $top) {
    if ($null -ne $lane.shown -and -not $lane.shown.exiting) {
      $lane.shown = @{ kind = $lane.shown.kind; kc = $lane.shown.kc; rgb = $lane.shown.rgb
                       exiting = $true; exitAt = $now }
    }
    return
  }
  $shownKey = if ($null -ne $lane.shown -and -not $lane.shown.exiting) { $lane.shown.key } else { $null }
  if ($shownKey -eq $top.key) { return }                       # 还是同一条，无需变化
  if ($null -ne $lane.shown -and $lane.shown.kind -eq $top.kind -and -not $lane.shown.exiting) {
    # 同类别换了一条（例如另一个会话也在等授权）：只换指针，不重启淡入，避免闪烁
    $lane.shown.key = $top.key; $lane.shown.arrivedAt = $top.arrivedAt; $lane.shown.kc = $top.kc
    return
  }
  if ($null -ne $lane.shown -and ($now - $lane.lastSwitch) -lt [double] $Script:Cfg.globalThrottleMs) { return }
  $lane.lastSwitch = $now
  $lane.shown = @{
    key = $top.key; kind = $top.kind; kc = $top.kc
    rgb = ConvertFrom-HexColor ([string] $top.kc.color)
    exiting = $false; enteredAt = $now
    session = $top.sessionId; arrivedAt = $top.arrivedAt
    pulse = [bool] $top.kc.pulse
  }
}

# 全局入口：逐通道刷新各自目标，互不干扰
function Update-Target {
  foreach ($lane in $Script:Lanes) { Update-Lane $lane }
}

function Prune-Active {
  $now = Now-Ms
  $changed = $false
  foreach ($k in @($Script:Active.Keys)) {
    $e = $Script:Active[$k]
    if ($now -gt $e.hardExpiry -or ($e.expires -ne [int64]::MaxValue -and $now -gt $e.expires)) {
      $Script:Active.Remove($k); $changed = $true
    }
  }
  if ($changed) { Update-Target }
}

# ---------------------------------------------------------------------------
# 5. 渲染
# ---------------------------------------------------------------------------
function EaseOut([double] $t) { if ($t -lt 0) { $t = 0 } elseif ($t -gt 1) { $t = 1 }; return 1 - [Math]::Pow(1 - $t, 3) }

function Frame-Alpha($s, [double] $scale) {
  $now = Now-Ms
  if ($s.exiting) {
    $m = [double] $Script:Cfg.motion.fadeOutMs
    if ($s.kind -eq 'done') {
      $dcf = $Script:Cfg['doneCloud']
      if ($null -ne $dcf -and $dcf.Contains('fadeOutMs')) { $m = [double] $dcf['fadeOutMs'] }
    }
    if ($m -le 0) { return 0 }
    return $scale * (1 - (EaseOut (($now - $s.exitAt) / $m)))
  }
  $a = 1.0
  $fi = [double] $Script:Cfg.motion.fadeInMs
  if ($s.kind -eq 'done') {
    $dcf = $Script:Cfg['doneCloud']
    if ($null -ne $dcf -and $dcf.Contains('fadeInMs')) { $fi = [double] $dcf['fadeInMs'] }
  }
  if ($fi -gt 0) { $a = EaseOut (($now - $s.enteredAt) / $fi) }
  if ($s.pulse) {
    $pm = [double] $Script:Cfg.motion.pulseMs
    $pd = [double] $Script:Cfg.motion.pulseDepth
    $a = $a * (1 - $pd + $pd * (0.5 + 0.5 * [Math]::Sin((($now % $pm) / $pm) * 2 * [Math]::PI)))
  }
  return $scale * $a
}

function Hide-Lane($lane) {
  $lane.window.Opacity = 0
  $lane.image.Visibility = [System.Windows.Visibility]::Collapsed
}

# 云渲染：按通道贴图与位置。
#   done    → 绿色祥云，屏幕左上角
#   waiting → 金色祥云，屏幕顶部居中
#   error   → 红色祥云，屏幕右上角
function Render-LaneCloud($lane, $s, [double] $alphaType) {
  $kind = [string] $s.kind
  $tex = $null
  $ratio = 1.5
  $cfg = $null
  $isDone = ($kind -eq 'done')
  $isError = ($kind -in @('error', 'blocked'))

  $dc = $Script:Cfg['doneCloud']
  if ($null -eq $dc -or $dc -isnot [System.Collections.IDictionary]) {
    $dc = @{ widthFraction = 0.10; opacity = 0.92; marginLeft = 0.03; marginTop = 0.03; enabled = $true }
  }
  # 完成任务绿云开关：enabled=false 时不显示绿云
  if ($isDone -and -not [bool] $dc['enabled']) {
    $lane.image.Visibility = [System.Windows.Visibility]::Collapsed
    $lane.window.Opacity = 0
    return $false
  }

  if ($isError) {
    $er = $Script:Cfg['errorCloud']
    if ($null -eq $er -or $er -isnot [System.Collections.IDictionary]) {
      $er = @{ enabled = $false; widthFraction = 0.18; opacity = 0.92; marginRight = 0.02; marginTop = 0.03 }
    }
    # 故障红云开关：enabled=false 时不显示红云（边框极光照常按故障色亮起）
    if (-not $er.Contains('enabled') -or -not [bool] $er['enabled']) {
      $lane.image.Visibility = [System.Windows.Visibility]::Collapsed
      $lane.window.Opacity = 0
      return $false
    }
    $cfg = $er; $tex = $Script:CloudTexRed; $ratio = $Script:CloudTexRedRatio
  } elseif ($isDone) {
    $cfg = $dc; $tex = $Script:CloudTexDone; $ratio = $Script:CloudTexDoneRatio
  } else {
    $cl = $Script:Cfg['cloud']
    if ($null -eq $cl -or $cl -isnot [System.Collections.IDictionary]) {
      $cl = @{ enabled = $false; widthFraction = 0.1; opacity = 0.92; centerX = 0.5 }
    }
    # 等待类金云开关：enabled=false 时不显示金云（边框极光照常按等待色亮起）
    if (-not $cl.Contains('enabled') -or -not [bool] $cl['enabled']) {
      $lane.image.Visibility = [System.Windows.Visibility]::Collapsed
      $lane.window.Opacity = 0
      return $false
    }
    $cfg = $cl; $tex = $Script:CloudTex; $ratio = $Script:CloudTexRatio
  }
  if ($ratio -le 0) { $ratio = 1.5 }

  # 目标显示器物理边界（相对虚拟桌面原点，可含副屏的偏移量）
  $dr = Get-DisplayRect
  $screenW = [double] $dr.W
  $screenH = [double] $dr.H
  $screenX = [double] $dr.L
  $screenY = [double] $dr.T

  if ($isError) {
    $cw = $screenW * [double] $cfg['widthFraction']
    $ch = $cw / $ratio
    $left = $screenX + $screenW - $cw - ($screenW * [double] $cfg['marginRight'])
    $top = $screenY + $screenH * [double] $cfg['marginTop']
    if ($left -lt $screenX) { $left = $screenX }
    if ($top -lt $screenY) { $top = $screenY }
    $imgA = [double] $cfg['opacity'] * [double] $alphaType
  } elseif ($isDone) {
    $cw = $screenW * [double] $cfg['widthFraction']
    $ch = $cw / $ratio
    $left = $screenX + $screenW * [double] $cfg['marginLeft']
    $top = $screenY + $screenH * [double] $cfg['marginTop']
    if ($left + $cw -gt $screenX + $screenW) { $left = $screenX + $screenW - $cw }
    if ($top + $ch -gt $screenY + $screenH) { $top = $screenY + $screenH - $ch }
    $imgA = [double] $cfg['opacity'] * [double] $alphaType
  } else {
    $cw = $screenW * [double] $cfg['widthFraction']
    $ch = $cw / $ratio
    $left = $screenX + $screenW * [double] $cfg['centerX'] - $cw / 2
    $top = $screenY
    if ($left -lt $screenX) { $left = $screenX }
    if ($left + $cw -gt $screenX + $screenW) { $left = $screenX + $screenW - $cw }
    $imgA = [double] $cfg['opacity'] * [double] $alphaType
  }

  if ([Math]::Abs($lane.window.Width - $cw) -gt 0.5) { $lane.window.Width = $cw }
  if ([Math]::Abs($lane.window.Height - $ch) -gt 0.5) { $lane.window.Height = $ch }
  $lane.window.Left = [double] $left
  $lane.window.Top = [double] $top

  if ($null -ne $tex) {
    if (-not [object]::ReferenceEquals($lane.image.Source, $tex)) { $lane.image.Source = $tex }
    $lane.image.Visibility = [System.Windows.Visibility]::Visible
    $lane.image.Width = $cw
    $lane.image.Height = $ch
    $lane.image.Opacity = [Math]::Max(0, [Math]::Min(1, $imgA))
  } else {
    $lane.image.Visibility = [System.Windows.Visibility]::Collapsed
  }
  $lane.window.Opacity = 1
  return $true
}

function Render {
  $now = Now-Ms
  $v = Get-ViewCfg
  $cfg = $Script:Cfg

  Prune-Active
  Update-Target                  # 重试此前被全局节流推迟的切换

  $scale = [double] $cfg.typeAlphaScale
  if ([bool] $cfg.dimWhenFullscreen) {
    try {
      $pr = $Script:PhysRect
      if ([DshRem.Native]::IsForegroundFullscreenOnPrimary([int] $pr.L, [int] $pr.T, [int] $pr.R, [int] $pr.B)) {
        # 常驻提醒不能因全屏工作被压到看不清：只压到 0.7
        $scale = $scale * 0.7
      }
    } catch { }
  }

  $activeLane = $null
  foreach ($lane in $Script:Lanes) {
    $s = $lane.shown
    if ($null -eq $s) {
      Hide-Lane $lane
      continue
    }
    if ($s.exiting -and (($now - $s.exitAt) -gt ([double] $cfg.motion.fadeOutMs + 80))) {
      $lane.shown = $null
      Hide-Lane $lane
      continue
    }
    $alphaType = Frame-Alpha $s $scale
    Render-LaneCloud $lane $s $alphaType | Out-Null
  }

  # 全局缩放缓存给独立的 30fps 动画定时器使用（边框动画不再挂在 8fps 的信号轮询上）
  $Script:GlobalScale = $scale
  return
}

# 渲染一帧（由独立 30fps 定时器驱动，与信号轮询解耦）
function Render-BorderFlash([long] $now, [double] $globalScale) {
  $bf = $Script:BorderFlash
  $eg = $Script:Cfg['edgeGlow']

  if ($null -eq $eg -or -not [bool] $eg['enabled']) {
    if ($bf.shown) { $bf.window.Opacity = 0; $bf.shown = $false }
    $Script:GlowShown = $false
    return
  }

  # 单窗口始终铺满目标屏
  $dr = Get-DisplayRect
  $sw = [double] $dr.W; $sh = [double] $dr.H
  $bf.window.Left = [double] $dr.L
  $bf.window.Top  = [double] $dr.T
  $bf.window.Width  = $sw
  $bf.window.Height = $sh

  # 取源信号：error > waiting > done（决定基准色相）
  $glowSrc = $null
  $errLane = $Script:Lanes | Where-Object { $_.key -eq 'error' } | Select-Object -First 1
  if ($null -ne $errLane -and $null -ne $errLane.shown) { $glowSrc = $errLane.shown }
  else {
    $waitLane = $Script:Lanes | Where-Object { $_.key -eq 'waiting' } | Select-Object -First 1
    if ($null -ne $waitLane -and $null -ne $waitLane.shown) { $glowSrc = $waitLane.shown }
    else {
      $doneLane = $Script:Lanes | Where-Object { $_.key -eq 'done' } | Select-Object -First 1
      if ($null -ne $doneLane -and $null -ne $doneLane.shown) { $glowSrc = $doneLane.shown }
    }
  }

  if ($null -eq $glowSrc) {
    if ($bf.shown) { $bf.window.Opacity = 0; $bf.shown = $false }
    $Script:GlowShown = $false
    return
  }

  # 基准色
  $kind = [string] $glowSrc.kind
  $kc = $eg['kindColors']; $hex = $null
  if ($kc -is [System.Collections.IDictionary]) {
    if ($kc.Contains([string] $kind)) { $hex = [string] $kc[[string] $kind] }
  } elseif ($null -ne $kc -and $kc.PSObject.Properties[[string] $kind]) {
    $hex = [string] $kc.PSObject.Properties[[string] $kind].Value
  }
  if ($null -ne $hex -and (Test-HexColor $hex)) { $rgb = ConvertFrom-HexColor $hex }
  else { $rgb = $glowSrc.rgb }
  Apply-BorderFlashStyle $bf $rgb

  # 四层几何
  $basePx  = [double] $eg['borderPx']; if ($basePx  -le 0) { $basePx  = 3 }
  $glowPx  = [double] $eg['glowPx'];   if ($glowPx  -le 0) { $glowPx  = 30 }
  $sweepPx = [double] $eg['sweepPx'];  if ($sweepPx -le 0) { $sweepPx = 8 }
  $corePx  = [double] $eg['corePx'];   if ($corePx  -le 0) { $corePx  = 2 }
  Layout-BorderFlash $bf $sw $sh $basePx $glowPx $sweepPx $corePx

  # ── 时间 ──
  $tsec = [double] $now / 1000.0
  $flowSpeed = [double] $eg['flowSpeed']; if ($flowSpeed -le 0) { $flowSpeed = 0.42 }
  $tailLen   = [double] $eg['cometTail']; if ($tailLen   -le 0) { $tailLen   = 0.20 }
  $intensity = [double] $eg['opacity'];   if ($intensity -le 0) { $intensity = 1.0 }
  $cycleMs   = [double] $eg['cycleMs'];   if ($cycleMs   -le 0) { $cycleMs   = 3000 }
  # 单色锁定：基准色相固定，不再随时间漂移/摆动（用户要求单色：琥珀就是琥珀）
  $hue = $bf.baseHue

  # 呼吸感 = 明暗深浅的正弦脉动（亮度在 0.72~1.00 间摆动），色相保持单色
  $breath = 0.72 + 0.28 * [Math]::Sin($tsec * 2.0 * [Math]::PI / ($cycleMs / 1000.0))
  $eff = $intensity * $globalScale * $breath

  # 双向彗星：A 顺时针、B 逆时针 → 周期性相遇
  $headA = ($tsec * $flowSpeed) % 1.0
  $headB = (0.62 - $tsec * $flowSpeed * 0.78) % 1.0
  if ($headB -lt 0) { $headB = $headB + 1.0 }
  # 相遇度：两束头在周长上的接近程度（0~1）
  $sep = [Math]::Abs($headA - $headB)
  if ($sep -gt 0.5) { $sep = 1.0 - $sep }
  $meet = [Math]::Max(0.0, 1.0 - $sep / 0.09)   # 距离 <9% 周长时爆发
  $burst = $meet * $meet

  $perimeter = 2 * ($sw + $sh)
  $topSpan = $sw / $perimeter
  $rightStartT = $topSpan; $rightSpan = $sh / $perimeter
  $bottomStartT = $topSpan + $rightSpan; $bottomSpan = $sw / $perimeter
  $leftStartT = $topSpan + $rightSpan + $bottomSpan; $leftSpan = $sh / $perimeter
  $spans = @{
    Top    = @{ s=0.0;            w=$topSpan }
    Right  = @{ s=$rightStartT;   w=$rightSpan }
    Bottom = @{ s=$bottomStartT;  w=$bottomSpan }
    Left   = @{ s=$leftStartT;    w=$leftSpan }
  }

  # 爆发时整体增强、彗尾拉长、白核更亮（事件感）
  $effNow = $eff * (1.0 + 0.55 * $burst)
  $tailNow = $tailLen * (1.0 + 0.45 * $burst)
  $whiteBoost = 0.82 + 0.18 * $burst

  foreach ($e in $bf.edges) {
    $sp = $spans[$e.key]
    Paint-Comet $e $headA $tailNow $hue $effNow $sp.s $sp.w 1 $false $whiteBoost
    Paint-Comet $e $headB ($tailNow * 0.82) $hue ($effNow * 0.82) $sp.s $sp.w -1 $true $whiteBoost
  }

  # 四角 HUD 节点：感应彗星临近（角点位于周长 t=0/.5 附近）+ 呼吸
  $cornerTs = @(0.0, $topSpan, ($topSpan + $rightSpan), ($topSpan + $rightSpan + $bottomSpan))
  for ($i = 0; $i -lt 4; $i++) {
    $ct = $cornerTs[$i]
    $da = [Math]::Abs($headA - $ct); if ($da -gt 0.5) { $da = 1.0 - $da }
    $db = [Math]::Abs($headB - $ct); if ($db -gt 0.5) { $db = 1.0 - $db }
    $near = [Math]::Max(0.0, 1.0 - [Math]::Min($da,$db) / 0.10)
    $pulse = 0.5 + 0.5 * [Math]::Sin($tsec * 3.0 + $i * 1.57)
    $a = [int][Math]::Round((70 + 110 * $pulse + 75 * $near + 60 * $burst) * $eff)
    if ($a -gt 255) { $a = 255 }
    $sz = 9 + 9 * [Math]::Max($near, $burst)
    $c = $bf.corners[$i]
    $c.Width = $sz; $c.Height = $sz
    $fill = $c.Fill
    $hc = Convert-HsvToRgb $hue 0.5 1.0
    $fill.Color = [System.Windows.Media.Color]::FromArgb([byte]$a, [byte]$hc[0], [byte]$hc[1], [byte]$hc[2])
  }

  # 相遇瞬间：常亮底线整体提亮（全场共鸣）
  $baseAlpha = [int][Math]::Round(34 + 90 * $burst)
  if ($baseAlpha -gt 255) { $baseAlpha = 255 }
  $b0 = $bf.edges[0].baseRect.Fill
  $b0.Color = [System.Windows.Media.Color]::FromArgb([byte]$baseAlpha, [byte]$rgb[0], [byte]$rgb[1], [byte]$rgb[2])

  $bf.window.Opacity = 1
  $bf.shown = $true
  $Script:GlowShown = $true
}

# ---------------------------------------------------------------------------
# 6. 声音
# ---------------------------------------------------------------------------
function Play-KindSound([string] $which) {
  try {
    switch ($which) {
      'ok'       { [void] [DshRem.Native]::MessageBeep(0x00) }
      'question' { [void] [DshRem.Native]::MessageBeep(0x20); Start-Sleep -Milliseconds 150; [void] [DshRem.Native]::MessageBeep(0x20) }
      'hand'     { [void] [DshRem.Native]::MessageBeep(0x10) }
    }
  } catch { Write-AssistLog ("sound failed: {0}" -f $_.Exception.Message) }
}

# ---------------------------------------------------------------------------
# 7. 信号通道（文件增量 tail）
# ---------------------------------------------------------------------------
$Script:TailPos = 0
$Script:TailPartial = ''
$Script:NextTailMs = 0

function Invoke-SignalLine([string] $line) {
  $ev = $null
  try { $ev = ConvertTo-Plain ($line | ConvertFrom-Json) } catch { Write-AssistLog ("bad signal line: $line"); return }
  if ($null -eq $ev) { return }
  # seq 去重已移除：文件 tail 位置 + Active key 已足够保证幂等性；
  # 旧逻辑 `seq <= SeqSeen 丢弃` 会因宿主重启 seq 归零导致大量信号丢失。
  switch ([string] $ev.type) {
    'resolve' { Resolve-Signal $ev }
    'clear'   { Clear-All }
    'ping'    { }
    default   { Add-Signal $ev }
  }
}

function Read-SignalFile {
  if (-not (Test-Path -LiteralPath $SignalPath)) { return }
  $fs = $null
  try {
    $fs = [System.IO.File]::Open($SignalPath, 'Open', 'Read', [System.IO.FileShare]::ReadWrite)
    if ($fs.Length -lt $Script:TailPos) { $Script:TailPos = 0; $Script:TailPartial = '' }
    if ($Script:TailPos -gt 0) { [void] $fs.Seek($Script:TailPos, 'Begin') }
    $sr = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8)
    $chunk = $sr.ReadToEnd()
    $Script:TailPos = $fs.Length
    $sr.Dispose()                    # StreamReader 连带关闭底层 FileStream
    $fs = $null
    if ([string]::IsNullOrEmpty($chunk)) { return }
    $lines = ($Script:TailPartial + $chunk) -split "`n"
    $Script:TailPartial = $lines[$lines.Count - 1]
    for ($i = 0; $i -lt $lines.Count - 1; $i++) {
      $line = $lines[$i].Trim([char]13, [char]10, ' ', [char]0xFEFF)
      if ($line) { Invoke-SignalLine $line }
    }
  } catch {
    Write-AssistLog ("tail error: {0}" -f $_.Exception.Message)
  } finally {
    if ($fs) { try { $fs.Dispose() } catch { } }
  }
}

function Restore-Snapshot {
  # 启动时把信号文件的读取位置移到末尾：历史行属于上一轮会话，重放会为一堆
  # 早已结束的提示重新亮灯。只有 snapshot.json 里记录的未解除项才需要恢复。
  try {
    if (Test-Path -LiteralPath $SignalPath) {
      $Script:TailPos = (Get-Item -LiteralPath $SignalPath).Length
    }
  } catch { $Script:TailPos = 0 }
  if (-not (Test-Path -LiteralPath $SnapshotPath)) { return }
  try {
    $j = ConvertTo-Plain (Get-Content -LiteralPath $SnapshotPath -Raw -Encoding UTF8 | ConvertFrom-Json)
    if ($null -eq $j -or -not $j.ContainsKey('pending')) { return }
    $now = Now-Ms
    foreach ($p in @($j.pending)) {
      if ($null -eq $p) { continue }
      $kind = [string] $p.kind
      if (-not $Script:Kinds.Contains($kind)) { continue }
      $kc = Get-KindConfig $kind
      if ([double] $kc.holdMs -gt 0) { continue }        # 只恢复常驻等待
      $sid = [string] $p.sessionId
      $cid = [string] $p.callId
      $key = Signal-Key $kind $sid $cid
      $Script:Active[$key] = @{
        key = $key; kind = $kind; kc = $kc; sessionId = $sid; callId = $cid; text = [string] $p.text
        at = $now; arrivedAt = Get-Date; expires = [int64]::MaxValue
        hardExpiry = $now + [double] $kc.maxHoldMs; priority = [double] $kc.priority
      }
      Write-AssistLog ("restored pending $key")
    }
    Update-Target
  } catch { Write-AssistLog ("snapshot error: {0}" -f $_.Exception.Message) }
}

# ---------------------------------------------------------------------------
# 8. 托盘
# ---------------------------------------------------------------------------
$Script:Tray = $null

function New-TrayIcon {
  $bmp = New-Object System.Drawing.Bitmap(32, 32)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.Clear([System.Drawing.Color]::Transparent)
  $bg = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(210, 10, 14, 20))
  $ln = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(240, 86, 212, 224), 4)
  $st = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(120, 201, 212, 226), 1)
  $g.FillRectangle($bg, 0, 6, 32, 17)
  $g.DrawLine($ln, 0, 25, 32, 25)
  $g.DrawLine($st, 0, 6, 32, 6)
  $g.Dispose()
  return [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
}

function Show-TrayTip([string] $title, [string] $text) {
  if ($null -eq $Script:Tray) { return }
  try { $Script:Tray.ShowBalloonTip(2200, $title, $text, [System.Windows.Forms.ToolTipIcon]::Info) } catch { }
}

function Set-TrayText {
  if ($null -eq $Script:Tray) { return }
  $st = '空闲'
  $labels = @()
  foreach ($lane in $Script:Lanes) {
    if ($null -ne $lane.shown -and -not $lane.shown.exiting) {
      $labels += [string] $lane.shown.kc.label
    }
  }
  if ($labels.Count -ge 2) {
    $st = '多任务（' + ($labels -join '/') + '）'
  } elseif ($labels.Count -eq 1) {
    $st = $labels[0]
  }
  $t = 'DSH 提醒 · {0} · 泛光 {1:P0}/{2:0.0}s{3}' -f $st, (Get-GlowAlpha), ((Get-PulseMs) / 1000.0), $(if ($Script:Muted) { ' · 静音' } else { '' })
  if ($t.Length -gt 63) { $t = $t.Substring(0, 63) }
  $Script:Tray.Text = $t
}

function Set-Profile([string] $p) {
  $Script:Cfg['profile'] = $p
  try {
    $disk = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $disk.profile = $p
    ($disk | ConvertTo-Json -Depth 12) | Set-Content -LiteralPath $ConfigPath -Encoding UTF8
  } catch { Write-AssistLog ("profile persist failed: {0}" -f $_.Exception.Message) }
  Update-Target; Render; Set-TrayText
}

function Set-Alpha([double] $v) {
  # 用 hashtable 索引赋值，不依赖属性语法；并保证键一定存在
  if ($null -eq $Script:Cfg) { return }
  $Script:Cfg['typeAlphaScale'] = Clamp $v 0 1
  Render
  Set-TrayText
}

function Set-AdjustAlpha([double] $d) {
  # 替代原本不存在的托盘滚轮：菜单「更亮 / 更暗」按 10% 步进
  if ($null -eq $Script:Cfg) { return }
  $cur = 1.0
  if ($Script:Cfg -is [System.Collections.IDictionary] -and $Script:Cfg.Contains('typeAlphaScale')) {
    $cur = [double] $Script:Cfg['typeAlphaScale']
  }
  Set-Alpha ($cur + $d)
}

function Set-GlowAlpha([double] $v) {
  # 边缘发光带的透明度上限
  if ($null -eq $Script:Cfg) { return }
  if (-not $Script:Cfg.Contains('edgeGlow')) { $Script:Cfg['edgeGlow'] = @{} }
  $eg = $Script:Cfg['edgeGlow']
  if (-not ($eg -is [System.Collections.IDictionary])) { $eg = @{}; $Script:Cfg['edgeGlow'] = $eg }
  $eg['opacity'] = Clamp $v 0 1
  Render
  Set-TrayText
  # 写回配置文件，重启后保持
  try {
    $disk = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $disk.PSObject.Properties['edgeGlow']) {
      $disk | Add-Member -NotePropertyName 'edgeGlow' -NotePropertyValue ([pscustomobject]@{ enabled = $true; widthDip = 10; opacity = [double] $eg['opacity']; pulseMs = 2200; sweepRatio = 0.28; idleGlow = $false; idleOpacity = 0.06; kindColors = @{} })
    } else {
      $disk.edgeGlow.opacity = [double] $eg['opacity']
    }
    ($disk | ConvertTo-Json -Depth 12) | Set-Content -LiteralPath $ConfigPath -Encoding UTF8
  } catch { Write-AssistLog ("edgeGlow opacity persist failed: {0}" -f $_.Exception.Message) }
}

function Get-GlowAlpha {
  if ($null -eq $Script:Cfg -or -not $Script:Cfg.Contains('edgeGlow')) { return 1.0 }
  $eg = $Script:Cfg['edgeGlow']
  if ($eg -isnot [System.Collections.IDictionary] -or -not $eg.Contains('opacity')) { return 1.0 }
  return [double] $eg['opacity']
}

function Set-AdjustGlowAlpha([double] $d) {
  Set-GlowAlpha ((Get-GlowAlpha) + $d)
}

function Get-PulseMs {
  # 新架构：闪烁周期 cycleMs（豆包 0.6s）
  if ($null -eq $Script:Cfg -or -not $Script:Cfg.Contains('edgeGlow')) { return 600 }
  $eg = $Script:Cfg['edgeGlow']
  if ($eg -isnot [System.Collections.IDictionary] -or -not $eg.Contains('cycleMs')) { return 600 }
  return [double] $eg['cycleMs']
}

function Set-PulseMs([double] $ms) {
  if ($null -eq $Script:Cfg) { return }
  $ms = Clamp $ms 100 10000
  if (-not $Script:Cfg.Contains('edgeGlow')) { $Script:Cfg['edgeGlow'] = @{} }
  $eg = $Script:Cfg['edgeGlow']
  if (-not ($eg -is [System.Collections.IDictionary])) { $eg = @{}; $Script:Cfg['edgeGlow'] = $eg }
  $eg['cycleMs'] = $ms
  Render
  Set-TrayText
  try {
    $disk = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($disk.PSObject.Properties['edgeGlow']) { $disk.edgeGlow.cycleMs = [double] $ms }
    ($disk | ConvertTo-Json -Depth 12) | Set-Content -LiteralPath $ConfigPath -Encoding UTF8
  } catch { Write-AssistLog ("edgeGlow cycleMs persist failed: {0}" -f $_.Exception.Message) }
}

function Get-ErrorCfg {
  if ($null -ne $Script:Cfg -and $Script:Cfg.Contains('errorCloud') -and ($Script:Cfg['errorCloud'] -is [System.Collections.IDictionary])) {
    return $Script:Cfg['errorCloud']
  }
  return @{ enabled = $true; widthFraction = 0.18; opacity = 0.92; marginRight = 0.02; marginTop = 0.03; glowColor = '#FF3030' }
}

function Set-ErrorCloud([string] $key, [double] $v) {
  # 红云可调项：widthFraction / opacity / marginRight / marginTop / glowOpacity
  if ($null -eq $Script:Cfg) { return }
  if (-not $Script:Cfg.Contains('errorCloud')) { $Script:Cfg['errorCloud'] = @{} }
  $er = $Script:Cfg['errorCloud']
  if (-not ($er -is [System.Collections.IDictionary])) { $er = @{}; $Script:Cfg['errorCloud'] = $er }
  switch ($key) {
    'enabled'       { $er['enabled'] = [bool] ($v -ge 0.5) }
    'widthFraction' { $er['widthFraction'] = Clamp $v 0.05 0.5 }
    'opacity'       { $er['opacity'] = Clamp $v 0.05 1 }
    'marginRight'   { $er['marginRight'] = Clamp $v 0 0.3 }
    'marginTop'     { $er['marginTop'] = Clamp $v 0 0.3 }
    'glowOpacity'   { $er['glowOpacity'] = Clamp $v 0 0.5 }
  }
  if (-not $er.Contains('enabled')) { $er['enabled'] = $false }
  if (-not $er.Contains('glowOpacity')) { $er['glowOpacity'] = 0.22 }
  Render
  Set-TrayText
  try {
    $disk = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $disk.PSObject.Properties['errorCloud']) {
      $disk | Add-Member -NotePropertyName 'errorCloud' -NotePropertyValue ([pscustomobject]@{
        enabled = $false; widthFraction = 0.18; opacity = 0.92; marginRight = 0.02; marginTop = 0.03; glowColor = '#FF3030'
      })
    }
    if ($key -eq 'enabled') { $disk.errorCloud.enabled = [bool] $er['enabled'] }
    else { $disk.errorCloud.$key = [double] $er[$key] }
    ($disk | ConvertTo-Json -Depth 12) | Set-Content -LiteralPath $ConfigPath -Encoding UTF8
  } catch { Write-AssistLog ("error cloud persist failed: {0}" -f $_.Exception.Message) }
}

function Set-AdjustErrorCloud([string] $key, [double] $d) {
  $er = Get-ErrorCfg
  Set-ErrorCloud $key ([double] $er[$key] + $d)
}

function Set-CloudWidth([double] $v) {
  # 等待类云宽（顶部居中），cloud.widthFraction
  if ($null -eq $Script:Cfg) { return }
  if (-not $Script:Cfg.Contains('cloud')) { $Script:Cfg['cloud'] = @{} }
  $cl = $Script:Cfg['cloud']
  if (-not ($cl -is [System.Collections.IDictionary])) { $cl = @{}; $Script:Cfg['cloud'] = $cl }
  $cl['widthFraction'] = Clamp $v 0.05 0.5
  Render
  Set-TrayText
  try {
    $disk = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $disk.PSObject.Properties['cloud']) {
      $disk | Add-Member -NotePropertyName 'cloud' -NotePropertyValue ([pscustomobject]@{ widthFraction = [double] $cl['widthFraction']; opacity = 0.92; centerX = 0.5; labelInside = $true })
    } else {
      $disk.cloud.widthFraction = [double] $cl['widthFraction']
    }
    ($disk | ConvertTo-Json -Depth 12) | Set-Content -LiteralPath $ConfigPath -Encoding UTF8
  } catch { Write-AssistLog ("cloud width persist failed: {0}" -f $_.Exception.Message) }
}

function Set-CloudEnabled([double] $v) {
  # 等待类金云贴图开关：cloud.enabled
  if ($null -eq $Script:Cfg) { return }
  if (-not $Script:Cfg.Contains('cloud')) { $Script:Cfg['cloud'] = @{} }
  $cl = $Script:Cfg['cloud']
  if (-not ($cl -is [System.Collections.IDictionary])) { $cl = @{}; $Script:Cfg['cloud'] = $cl }
  $cl['enabled'] = [bool] ($v -ge 0.5)
  Render
  Set-TrayText
  try {
    $disk = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $disk.PSObject.Properties['cloud']) {
      $disk | Add-Member -NotePropertyName 'cloud' -NotePropertyValue ([pscustomobject]@{
        enabled = [bool] $cl['enabled']; widthFraction = 0.10; opacity = 0.92; centerX = 0.5; labelInside = $true
      })
    } else {
      $disk.cloud | Add-Member -NotePropertyName 'enabled' -NotePropertyValue ([bool] $cl['enabled']) -Force
    }
    ($disk | ConvertTo-Json -Depth 12) | Set-Content -LiteralPath $ConfigPath -Encoding UTF8
  } catch { Write-AssistLog ("cloud enabled persist failed: {0}" -f $_.Exception.Message) }
}

function Set-AutoDismiss([double] $v) {
  # 「打开窗口自动收提醒」开关：autoDismiss.enabled
  if ($null -eq $Script:Cfg) { return }
  if (-not $Script:Cfg.Contains('autoDismiss')) { $Script:Cfg['autoDismiss'] = @{} }
  $ad = $Script:Cfg['autoDismiss']
  if (-not ($ad -is [System.Collections.IDictionary])) { $ad = @{}; $Script:Cfg['autoDismiss'] = $ad }
  $ad['enabled'] = [bool] ($v -ge 0.5)
  Render
  Set-TrayText
  try {
    $disk = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $disk.PSObject.Properties['autoDismiss']) {
      $disk | Add-Member -NotePropertyName 'autoDismiss' -NotePropertyValue ([pscustomobject]@{
        enabled = [bool] $ad['enabled']; dwellMs = 800
        processMatch = @('DeepSeek Harness'); titleMatch = @('DeepSeek Harness')
      })
    } else {
      $disk.autoDismiss | Add-Member -NotePropertyName 'enabled' -NotePropertyValue ([bool] $ad['enabled']) -Force
    }
    ($disk | ConvertTo-Json -Depth 12) | Set-Content -LiteralPath $ConfigPath -Encoding UTF8
  } catch { Write-AssistLog ("autoDismiss persist failed: {0}" -f $_.Exception.Message) }
}

function Get-DoneCfg {
  if ($null -ne $Script:Cfg -and $Script:Cfg.Contains('doneCloud') -and ($Script:Cfg['doneCloud'] -is [System.Collections.IDictionary])) {
    return $Script:Cfg['doneCloud']
  }
  return @{ enabled = $true; widthFraction = 0.10; opacity = 0.92; marginLeft = 0.03; marginTop = 0.03; fadeInMs = 700; fadeOutMs = 900; glowColor = '#35D07F'; glowOpacity = 0.14 }
}

function Set-DoneCloud([string] $key, [double] $v) {
  # 完成任务绿云可调项：enabled(开关) / widthFraction / opacity / fadeInMs / fadeOutMs / glowOpacity
  if ($null -eq $Script:Cfg) { return }
  if (-not $Script:Cfg.Contains('doneCloud')) { $Script:Cfg['doneCloud'] = @{} }
  $dc = $Script:Cfg['doneCloud']
  if (-not ($dc -is [System.Collections.IDictionary])) { $dc = @{}; $Script:Cfg['doneCloud'] = $dc }
  switch ($key) {
    'enabled'     { $dc['enabled'] = [bool] ($v -ge 0.5) }
    'widthFraction' { $dc['widthFraction'] = Clamp $v 0.02 0.6 }
    'opacity'     { $dc['opacity'] = Clamp $v 0.05 1 }
    'fadeInMs'    { $dc['fadeInMs'] = Clamp $v 0 3000 }
    'fadeOutMs'   { $dc['fadeOutMs'] = Clamp $v 0 3000 }
    'glowOpacity' { $dc['glowOpacity'] = Clamp $v 0 0.5 }
  }
  if (-not $dc.Contains('enabled')) { $dc['enabled'] = $true }
  Render
  Set-TrayText
  try {
    $disk = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $disk.PSObject.Properties['doneCloud']) {
      $disk | Add-Member -NotePropertyName 'doneCloud' -NotePropertyValue ([pscustomobject]@{
        enabled = $true; widthFraction = 0.10; opacity = 0.92; marginLeft = 0.03; marginTop = 0.03; fadeInMs = 700; fadeOutMs = 900
      })
    }
    switch ($key) {
      'enabled'     { $disk.doneCloud.enabled = [bool] ($v -ge 0.5) }
      'widthFraction'{ $disk.doneCloud.widthFraction = [double] $dc['widthFraction'] }
      'opacity'     { $disk.doneCloud.opacity = [double] $dc['opacity'] }
      'fadeInMs'    { $disk.doneCloud.fadeInMs = [double] $dc['fadeInMs'] }
      'fadeOutMs'   { $disk.doneCloud.fadeOutMs = [double] $dc['fadeOutMs'] }
      'glowOpacity' { $disk.doneCloud.glowOpacity = [double] $dc['glowOpacity'] }
    }
    ($disk | ConvertTo-Json -Depth 12) | Set-Content -LiteralPath $ConfigPath -Encoding UTF8
  } catch { Write-AssistLog ("done cloud persist failed: {0}" -f $_.Exception.Message) }
}

function Get-CloudWidth {
  if ($null -eq $Script:Cfg -or -not $Script:Cfg.Contains('cloud')) { return 0.10 }
  $cl = $Script:Cfg['cloud']
  if ($cl -isnot [System.Collections.IDictionary] -or -not $cl.Contains('widthFraction')) { return 0.10 }
  return [double] $cl['widthFraction']
}

function Apply-Setting([string] $key, [double] $v) {
  switch ($key) {
    'autoDismissEnabled' { Set-AutoDismiss $v }
    'cloudEnabled' { Set-CloudEnabled $v }
    'errorEnabled' { Set-ErrorCloud 'enabled' $v }
    'cloudWidth'   { Set-CloudWidth $v }
    'glowOpacity'  { Set-GlowAlpha $v }
    'edgeGlowOpacity' { Set-GlowAlpha $v }
    'pulseMs'      { Set-PulseMs $v }
    'errorWidth'   { Set-ErrorCloud 'widthFraction' $v }
    'errorOpacity' { Set-ErrorCloud 'opacity' $v }
    'marginRight'  { Set-ErrorCloud 'marginRight' $v }
    'marginTop'    { Set-ErrorCloud 'marginTop' $v }
    'errorGlow'    { Set-ErrorCloud 'glowOpacity' $v }
    'globalAlpha'  { Set-Alpha $v }
    'doneEnabled'  { Set-DoneCloud 'enabled' $v }
    'doneWidth'    { Set-DoneCloud 'widthFraction' $v }
    'doneOpacity'  { Set-DoneCloud 'opacity' $v }
    'doneGlow'     { Set-DoneCloud 'glowOpacity' $v }
    'doneFadeIn'   { Set-DoneCloud 'fadeInMs' $v }
    'doneFadeOut'  { Set-DoneCloud 'fadeOutMs' $v }
    'edgeGlowEnabled' {
      if ($null -eq $Script:Cfg) { return }
      if (-not $Script:Cfg.Contains('edgeGlow')) { $Script:Cfg['edgeGlow'] = @{} }
      $eg = $Script:Cfg['edgeGlow']
      if (-not ($eg -is [System.Collections.IDictionary])) { $eg = @{}; $Script:Cfg['edgeGlow'] = $eg }
      $eg['enabled'] = ($v -ge 0.5)
      Render
      Set-TrayText
      try {
        $disk = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if (-not $disk.PSObject.Properties['edgeGlow']) {
          $disk | Add-Member -NotePropertyName 'edgeGlow' -NotePropertyValue ([pscustomobject]@{ enabled = ($v -ge 0.5); widthDip = 10; opacity = 0.55; pulseMs = 2200; sweepRatio = 0.28; idleGlow = $false; idleOpacity = 0.06; kindColors = @{} })
        } else {
          $disk.edgeGlow.enabled = ($v -ge 0.5)
        }
        ($disk | ConvertTo-Json -Depth 12) | Set-Content -LiteralPath $ConfigPath -Encoding UTF8
      } catch { Write-AssistLog ("edgeGlow enabled persist failed: {0}" -f $_.Exception.Message) }
    }
  }
}

function Set-ScreenDisplay([string] $v) {
  # 目标显示器：primary / all / 数字序号（1,2,3...）
  $d = ([string] $v).Trim().ToLowerInvariant()
  if ($d -ne 'primary' -and $d -ne 'all' -and $d -ne 'a' -and $d -ne '*' -and -not ($d -match '^\d+$')) { return }
  if ($null -eq $Script:Cfg) { return }
  $Script:Cfg['screen'] = $d
  try {
    $disk = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $disk.screen = $d
    ($disk | ConvertTo-Json -Depth 12) | Set-Content -LiteralPath $ConfigPath -Encoding UTF8
    # 立即重定位（与热加载同一逻辑）
    $newRect = Get-DisplayRect
    if ($Script:PhysRect.Device -ne $newRect.Device) {
      $Script:PhysRect = $newRect
      # 边框闪烁窗口会在下一帧 Render-BorderFlash 中自动重定位
      Write-AssistLog ("display target changed -> {0} rect=({1},{2})-({3},{4})" -f $newRect.Device, $newRect.L, $newRect.T, $newRect.R, $newRect.B)
    }
    Render
  } catch { Write-AssistLog ("screen persist failed: {0}" -f $_.Exception.Message) }
}

function Get-ScreenLabel([string] $v) {
  $d = ([string] $v).Trim().ToLowerInvariant()
  if ($d -eq 'all' -or $d -eq 'a' -or $d -eq '*') { return '所有屏幕（铺满）' }
  if ($d -match '^\d+$') {
    $screens = @([System.Windows.Forms.Screen]::AllScreens)
    $sorted = @($screens | Sort-Object @{ Expression = { $_.Bounds.X } }, @{ Expression = { $_.Bounds.Y } })
    $idx = [int] $d
    if ($idx -ge 1 -and $idx -le $sorted.Count) { $s=$sorted[$idx-1]; return ('屏幕 {0}（{1}）' -f $idx, ($(if ($s.Primary) { '主' } else { '副' }))) }
    return ('屏幕 {0}' -f $idx)
  }
  return '主显示器'
}

function Get-SettingValue([string] $key) {
  switch ($key) {
    'autoDismissEnabled' { if ($null -ne $Script:Cfg -and $Script:Cfg.Contains('autoDismiss') -and ($Script:Cfg['autoDismiss'] -is [System.Collections.IDictionary]) -and [bool] $Script:Cfg['autoDismiss']['enabled']) { return 1.0 } else { return 0.0 } }
    'cloudEnabled' { if ($null -ne $Script:Cfg -and $Script:Cfg.Contains('cloud') -and ($Script:Cfg['cloud'] -is [System.Collections.IDictionary]) -and [bool] $Script:Cfg['cloud']['enabled']) { return 1.0 } else { return 0.0 } }
    'errorEnabled' { if ([bool] (Get-ErrorCfg)['enabled']) { return 1.0 } else { return 0.0 } }
    'cloudWidth'   { return Get-CloudWidth }
    'glowOpacity'  { return Get-GlowAlpha }
    'edgeGlowOpacity' { return Get-GlowAlpha }
    'pulseMs'      { return Get-PulseMs }
    'errorWidth'   { return [double] (Get-ErrorCfg)['widthFraction'] }
    'errorOpacity' { return [double] (Get-ErrorCfg)['opacity'] }
    'marginRight'  { return [double] (Get-ErrorCfg)['marginRight'] }
    'marginTop'    { return [double] (Get-ErrorCfg)['marginTop'] }
    'errorGlow'    { return [double] (Get-ErrorCfg)['glowOpacity'] }
    'globalAlpha'  { if ($null -eq $Script:Cfg) { return 1.0 }; return [double] $Script:Cfg['typeAlphaScale'] }
    'doneEnabled'  { if ([bool] (Get-DoneCfg)['enabled']) { return 1.0 } else { return 0.0 } }
    'doneWidth'    { return [double] (Get-DoneCfg)['widthFraction'] }
    'doneOpacity'  { return [double] (Get-DoneCfg)['opacity'] }
    'doneFadeIn'   { return [double] (Get-DoneCfg)['fadeInMs'] }
    'doneFadeOut'  { return [double] (Get-DoneCfg)['fadeOutMs'] }
    'doneGlow'     { return [double] (Get-DoneCfg)['glowOpacity'] }
    'edgeGlowEnabled' {
      if ($null -eq $Script:Cfg -or -not $Script:Cfg.Contains('edgeGlow')) { return 1.0 }
      $eg = $Script:Cfg['edgeGlow']
      if ($eg -isnot [System.Collections.IDictionary] -or -not $eg.Contains('enabled')) { return 1.0 }
      if ([bool] $eg['enabled']) { return 1.0 } else { return 0.0 }
    }
  }
  return 0
}

# ── 效果颜色（三类单色）：内存 + 持久化 + 即时重绘 ──────────────────────────
function Get-KindColor([string] $group) {
  $first = switch ($group) { 'waiting' { 'approval' } 'error' { 'error' } 'done' { 'done' } default { $group } }
  if ($null -ne $Script:Kinds -and $Script:Kinds.Contains($first)) {
    $c = $Script:Kinds[$first]['color']
    if (Test-HexColor ([string] $c)) { return ([string] $c) }
  }
  if ($group -eq 'waiting') { return '#FFB454' }
  if ($group -eq 'error')   { return '#FF6B6B' }
  if ($group -eq 'done')    { return '#35D07F' }
  return '#FFB454'
}

function Set-KindColor([string] $group, [string] $hex) {
  if (-not (Test-HexColor $hex)) { return }
  $members = switch ($group) {
    'waiting' { @('approval', 'question', 'waiting') }
    'error'   { @('error', 'blocked') }
    'done'    { @('done') }
    default   { @() }
  }
  # 1) 内存：色带/云渲染消费的 $Script:Kinds
  foreach ($k in $members) {
    if ($null -ne $Script:Kinds -and $Script:Kinds.Contains($k)) { $Script:Kinds[$k]['color'] = $hex }
  }
  # 2) 内存：边框能量场 kindColors
  if ($null -ne $Script:Cfg -and $Script:Cfg.Contains('edgeGlow')) {
    $eg = $Script:Cfg['edgeGlow']
    if ($eg -is [System.Collections.IDictionary]) {
      if (-not $eg.Contains('kindColors')) { $eg['kindColors'] = @{} }
      $kc = $eg['kindColors']
      if ($kc -isnot [System.Collections.IDictionary]) { $kc = @{}; $eg['kindColors'] = $kc }
      foreach ($k in $members) { $kc[$k] = $hex }
    }
  }
  # 3) 写盘：kinds.*.color 与 edgeGlow.kindColors.* 同步
  try {
    $disk = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($k in $members) {
      if ($disk.PSObject.Properties['kinds'] -and $disk.kinds.PSObject.Properties[$k]) { $disk.kinds.$k.color = $hex }
      if ($disk.PSObject.Properties['edgeGlow']) {
        if (-not $disk.edgeGlow.PSObject.Properties['kindColors']) { $disk.edgeGlow | Add-Member -NotePropertyName 'kindColors' -NotePropertyValue ([pscustomobject]@{}) }
        $disk.edgeGlow.kindColors.$k = $hex
      }
    }
    ($disk | ConvertTo-Json -Depth 12) | Set-Content -LiteralPath $ConfigPath -Encoding UTF8
  } catch { Write-AssistLog ("kind color persist failed: {0}" -f $_.Exception.Message) }
  Render
}

function New-ColorSwatch([string] $group, [string] $hex, [double] $size) {
  $b = New-Object System.Windows.Controls.Button
  $b.Width = $size; $b.Height = $size
  $b.Margin = New-Object System.Windows.Thickness(0, 0, 6, 0)
  $b.VerticalAlignment = 'Center'
  $b.BorderThickness = New-Object System.Windows.Thickness(1)
  $b.BorderBrush = [System.Windows.Media.Brushes]::DarkGray
  $rgb = ConvertFrom-HexColor $hex
  $b.Background = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb([byte]$rgb[0], [byte]$rgb[1], [byte]$rgb[2]))
  $b.Tag = @{ group = $group; hex = $hex }
  $b.Add_Click({
    param($s, $e)
    $t = $s.Tag
    Set-KindColor ([string] $t.group) ([string] $t.hex)
    if ($Script:ColorPreview.ContainsKey([string] $t.group)) {
      $pv = $Script:ColorPreview[[string] $t.group]
      $n = ConvertFrom-HexColor ([string] $t.hex)
      $pv.Background = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb([byte]$n[0], [byte]$n[1], [byte]$n[2]))
    }
  })
  return $b
}

function New-ColorRow([string] $label, [string] $group, [string[]] $swatches) {
  $row = New-Object System.Windows.Controls.StackPanel
  $row.Orientation = 'Horizontal'
  $row.Margin = New-Object System.Windows.Thickness(0, 5, 0, 5)

  $lbl = New-Object System.Windows.Controls.TextBlock
  $lbl.Text = $label
  $lbl.Width = 92
  $lbl.VerticalAlignment = 'Center'
  $lbl.Foreground = [System.Windows.Media.Brushes]::White

  $curHex = Get-KindColor $group
  $n = ConvertFrom-HexColor $curHex
  $pv = New-Object System.Windows.Controls.Border
  $pv.Width = 24; $pv.Height = 24
  $pv.VerticalAlignment = 'Center'
  $pv.Margin = New-Object System.Windows.Thickness(0, 0, 10, 0)
  $pv.BorderThickness = New-Object System.Windows.Thickness(1)
  $pv.BorderBrush = [System.Windows.Media.Brushes]::White
  $pv.Background = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb([byte]$n[0], [byte]$n[1], [byte]$n[2]))
  $pv.ToolTip = $curHex
  if ($null -eq $Script:ColorPreview) { $Script:ColorPreview = @{} }
  $Script:ColorPreview[$group] = $pv

  $row.Children.Add($lbl) | Out-Null
  $row.Children.Add($pv) | Out-Null
  foreach ($hx in $swatches) { [void] $row.Children.Add((New-ColorSwatch $group $hx 22)) }
  return $row
}

# ---------------------------------------------------------------------------
# 可视化效果设置窗口（WPF）
# ---------------------------------------------------------------------------
$Script:SettingsWin = $null
$Script:SettingsInit = $false
$Script:SettingsSliders = @{}
$Script:SettingsChecks = @{}

function New-SliderRow([string] $label, [string] $key, [double] $min, [double] $max, [double] $val, [string] $fmt) {
  $row = New-Object System.Windows.Controls.StackPanel
  $row.Orientation = 'Horizontal'
  $row.Margin = New-Object System.Windows.Thickness(0, 5, 0, 5)

  $lbl = New-Object System.Windows.Controls.TextBlock
  $lbl.Text = $label
  $lbl.Width = 92
  $lbl.VerticalAlignment = 'Center'
  $lbl.Foreground = [System.Windows.Media.Brushes]::White

  $sld = New-Object System.Windows.Controls.Slider
  $sld.Minimum = $min
  $sld.Maximum = $max
  $sld.Width = 230
  $sld.VerticalAlignment = 'Center'
  $sld.SmallChange = [double] (($max - $min) / 100)
  $sld.LargeChange = [double] (($max - $min) / 20)

  $txt = New-Object System.Windows.Controls.TextBlock
  $txt.Width = 68
  $txt.TextAlignment = 'Right'
  $txt.VerticalAlignment = 'Center'
  $txt.Foreground = [System.Windows.Media.Brushes]::LightCyan

  $sld.Tag = @{ key = $key; txt = $txt; fmt = $fmt }
  $sld.Add_ValueChanged({
    param($s, $e)
    if ($null -eq $s.Tag) { return }
    $t = $s.Tag.txt
    if ($s.Tag.fmt -eq 'sec') {
      $t.Text = ('{0:0.0} 秒' -f ($s.Value / 1000.0))
    } elseif ($s.Tag.fmt -eq 'ms') {
      $t.Text = ('{0:0} 毫秒' -f $s.Value)
    } elseif ($s.Tag.fmt -eq 'px') {
      $t.Text = ('{0:0} px' -f $s.Value)
    } else {
      $t.Text = ('{0:P0}' -f $s.Value)
    }
    if (-not $Script:SettingsInit) {
      Apply-Setting ([string] $s.Tag.key) ([double] $s.Value)
    }
  })

  $row.Children.Add($lbl) | Out-Null
  $row.Children.Add($sld) | Out-Null
  $row.Children.Add($txt) | Out-Null

  $Script:SettingsSliders[$key] = $sld
  # 设置初始值（触发 ValueChanged 更新文本，但 SettingsInit 抑制 Apply）
  $sld.Value = $val
  return $row
}

function New-SectionTitle([string] $text) {
  $t = New-Object System.Windows.Controls.TextBlock
  $t.Text = $text
  $t.FontWeight = 'Bold'
  $t.FontSize = 13
  $t.Foreground = [System.Windows.Media.Brushes]::Gold
  $t.Margin = New-Object System.Windows.Thickness(0, 10, 0, 2)
  return $t
}

# 开关行（布尔设置）：label / key / checked
function New-ToggleRow([string] $label, [string] $key, [bool] $checked) {
  $row = New-Object System.Windows.Controls.StackPanel
  $row.Orientation = 'Horizontal'
  $row.Margin = New-Object System.Windows.Thickness(0, 5, 0, 5)

  $lbl = New-Object System.Windows.Controls.TextBlock
  $lbl.Text = $label
  $lbl.Width = 92
  $lbl.VerticalAlignment = 'Center'
  $lbl.Foreground = [System.Windows.Media.Brushes]::White

  $ck = New-Object System.Windows.Controls.CheckBox
  $ck.VerticalAlignment = 'Center'
  $ck.IsChecked = $checked
  $ck.Tag = @{ key = $key }
  $ck.Add_Checked({ Apply-Setting ([string] $_.Tag.key) 1.0 })
  $ck.Add_Unchecked({ Apply-Setting ([string] $_.Tag.key) 0.0 })
  $Script:SettingsChecks[$key] = $ck

  $row.Children.Add($lbl) | Out-Null
  $row.Children.Add($ck) | Out-Null
  return $row
}

function Get-EdgeGlowWidth {
  if ($null -eq $Script:Cfg -or -not $Script:Cfg.Contains('edgeGlow')) { return 10 }
  $eg = $Script:Cfg['edgeGlow']
  if ($eg -isnot [System.Collections.IDictionary] -or -not $eg.Contains('widthDip')) { return 10 }
  return [double] $eg['widthDip']
}

function Set-EdgeGlowWidth([double] $v) {
  if ($null -eq $Script:Cfg) { return }
  if (-not $Script:Cfg.Contains('edgeGlow')) { $Script:Cfg['edgeGlow'] = @{} }
  $eg = $Script:Cfg['edgeGlow']
  if (-not ($eg -is [System.Collections.IDictionary])) { $eg = @{}; $Script:Cfg['edgeGlow'] = $eg }
  $eg['widthDip'] = Clamp $v 2 30
  Render
  Set-TrayText
  try {
    $disk = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $disk.PSObject.Properties['edgeGlow']) {
      $disk | Add-Member -NotePropertyName 'edgeGlow' -NotePropertyValue ([pscustomobject]@{ enabled = $true; widthDip = [double] $eg['widthDip']; opacity = 0.55; pulseMs = 2200; sweepRatio = 0.28; idleGlow = $false; idleOpacity = 0.06; kindColors = @{} })
    } else {
      $disk.edgeGlow.widthDip = [double] $eg['widthDip']
    }
    ($disk | ConvertTo-Json -Depth 12) | Set-Content -LiteralPath $ConfigPath -Encoding UTF8
  } catch { Write-AssistLog ("edgeGlow width persist failed: {0}" -f $_.Exception.Message) }
}

function Get-EdgeSweepRatio {
  if ($null -eq $Script:Cfg -or -not $Script:Cfg.Contains('edgeGlow')) { return 0.28 }
  $eg = $Script:Cfg['edgeGlow']
  if ($eg -isnot [System.Collections.IDictionary] -or -not $eg.Contains('sweepRatio')) { return 0.28 }
  return [double] $eg['sweepRatio']
}

function Set-EdgeSweepRatio([double] $v) {
  if ($null -eq $Script:Cfg) { return }
  if (-not $Script:Cfg.Contains('edgeGlow')) { $Script:Cfg['edgeGlow'] = @{} }
  $eg = $Script:Cfg['edgeGlow']
  if (-not ($eg -is [System.Collections.IDictionary])) { $eg = @{}; $Script:Cfg['edgeGlow'] = $eg }
  $eg['sweepRatio'] = Clamp $v 0.05 0.8
  Render
  Set-TrayText
  try {
    $disk = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $disk.PSObject.Properties['edgeGlow']) {
      $disk | Add-Member -NotePropertyName 'edgeGlow' -NotePropertyValue ([pscustomobject]@{ enabled = $true; widthDip = 10; opacity = 0.55; pulseMs = 2200; sweepRatio = [double] $eg['sweepRatio']; idleGlow = $false; idleOpacity = 0.06; kindColors = @{} })
    } else {
      $disk.edgeGlow.sweepRatio = [double] $eg['sweepRatio']
    }
    ($disk | ConvertTo-Json -Depth 12) | Set-Content -LiteralPath $ConfigPath -Encoding UTF8
  } catch { Write-AssistLog ("edgeGlow sweepRatio persist failed: {0}" -f $_.Exception.Message) }
}

function Get-IdleGlow {
  if ($null -eq $Script:Cfg -or -not $Script:Cfg.Contains('edgeGlow')) { return $false }
  $eg = $Script:Cfg['edgeGlow']
  if ($eg -isnot [System.Collections.IDictionary] -or -not $eg.Contains('idleGlow')) { return $false }
  return [bool] $eg['idleGlow']
}

function Set-IdleGlow([bool] $on) {
  if ($null -eq $Script:Cfg) { return }
  if (-not $Script:Cfg.Contains('edgeGlow')) { $Script:Cfg['edgeGlow'] = @{} }
  $eg = $Script:Cfg['edgeGlow']
  if (-not ($eg -is [System.Collections.IDictionary])) { $eg = @{}; $Script:Cfg['edgeGlow'] = $eg }
  $eg['idleGlow'] = $on
  Render
  Set-TrayText
  try {
    $disk = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $disk.PSObject.Properties['edgeGlow']) {
      $disk | Add-Member -NotePropertyName 'edgeGlow' -NotePropertyValue ([pscustomobject]@{ enabled = $true; widthDip = 10; opacity = 0.55; pulseMs = 2200; sweepRatio = 0.28; idleGlow = $on; idleOpacity = 0.06; kindColors = @{} })
    } else {
      $disk.edgeGlow.idleGlow = $on
    }
    ($disk | ConvertTo-Json -Depth 12) | Set-Content -LiteralPath $ConfigPath -Encoding UTF8
  } catch { Write-AssistLog ("edgeGlow idleGlow persist failed: {0}" -f $_.Exception.Message) }
}

function Set-Muted([bool] $on) {
  $Script:Muted = $on
  Set-TrayText
}

function Set-SettingsRow([string] $key, [double] $v) {
  # 恢复默认后的窗口行同步：只改 UI 值，不重复写盘（Apply-Setting 已持久化）
  if ($Script:SettingsSliders.ContainsKey($key)) { $Script:SettingsSliders[$key].Value = $v }
  if ($Script:SettingsChecks.ContainsKey($key)) { $Script:SettingsChecks[$key].IsChecked = ($v -ge 0.5) }
}

function Invoke-ErrorDemo {
  try {
    $line = (@{ type = 'signal'; kind = 'error'; sessionId = 'session-error-demo'; text = ''; seq = ([long] $Script:SeqSeen + 1); at = (Now-Ms) } | ConvertTo-Json -Compress)
    [System.IO.File]::AppendAllText($SignalPath, $line + "`n", (New-Object System.Text.UTF8Encoding($false)))
  } catch { Write-AssistLog ("error demo failed: {0}" -f $_.Exception.Message) }
}

function Invoke-WaitingDemo {
  try {
    $line = (@{ type = 'signal'; kind = 'approval'; sessionId = 'settings-demo'; text = ''; at = (Now-Ms) } | ConvertTo-Json -Compress)
    [System.IO.File]::AppendAllText($SignalPath, $line + "`n", (New-Object System.Text.UTF8Encoding($false)))
  } catch { Write-AssistLog ("waiting demo failed: {0}" -f $_.Exception.Message) }
}

function Invoke-DoneDemo {
  try {
    $line = (@{ type = 'signal'; kind = 'done'; sessionId = 'settings-done-demo'; text = ''; at = (Now-Ms) } | ConvertTo-Json -Compress)
    [System.IO.File]::AppendAllText($SignalPath, $line + "`n", (New-Object System.Text.UTF8Encoding($false)))
  } catch { Write-AssistLog ("done demo failed: {0}" -f $_.Exception.Message) }
}

function Invoke-OpenConfig { Start-Process -FilePath $ConfigPath }
function Invoke-OpenSignal { if (Test-Path -LiteralPath $SignalPath) { Start-Process -FilePath $SignalPath } }

function Invoke-Exit {
  $Script:Stop = $true
  [System.Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeShutdown()
}

function Show-SettingsWindow {
  if ($null -ne $Script:SettingsWin) {
    try { $Script:SettingsWin.Activate(); return } catch { }
  }

  $win = New-Object System.Windows.Window
  $win.Title = 'DSH 桌面提醒 · 效果设置'
  $win.Width = 430
  $win.Height = 680
  $win.WindowStartupLocation = 'CenterScreen'
  # 可调整大小：CanResize + 最小尺寸兜底，内容在 ScrollViewer 内随窗口伸缩
  $win.ResizeMode = 'CanResize'
  $win.MinWidth = 380
  $win.MinHeight = 420
  $win.Topmost = $true
  $win.Background = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(24, 27, 32))

  $sp = New-Object System.Windows.Controls.StackPanel
  $sp.Margin = New-Object System.Windows.Thickness(16, 12, 16, 12)

  $Script:SettingsInit = $true
  $Script:SettingsSliders = @{}
  $Script:SettingsChecks = @{}

  # ── 分区：通用 ──
  [void] $sp.Children.Add((New-SectionTitle '通用'))

  # 显示器选择
  $dispRow = New-Object System.Windows.Controls.StackPanel
  $dispRow.Orientation = 'Horizontal'
  $dispRow.Margin = New-Object System.Windows.Thickness(0, 5, 0, 5)

  $dispLbl = New-Object System.Windows.Controls.TextBlock
  $dispLbl.Text = '显示器'
  $dispLbl.Width = 92
  $dispLbl.VerticalAlignment = 'Center'
  $dispLbl.Foreground = [System.Windows.Media.Brushes]::White

  $combo = New-Object System.Windows.Controls.ComboBox
  $combo.Width = 250
  $combo.VerticalAlignment = 'Center'

  $curDisp = ''
  if ($null -ne $Script:Cfg) { $curDisp = ([string] $Script:Cfg.screen).Trim().ToLowerInvariant() }
  if ($curDisp -eq 'a' -or $curDisp -eq '*') { $curDisp = 'all' }
  if ($curDisp -eq '') { $curDisp = 'primary' }

  $screens = @([System.Windows.Forms.Screen]::AllScreens)
  $sorted = @($screens | Sort-Object @{ Expression = { $_.Bounds.X } }, @{ Expression = { $_.Bounds.Y } })
  $items = [System.Collections.Generic.List[object]]::new()
  $optAll = New-Object System.Windows.Controls.ComboBoxItem
  $optAll.Content = '所有屏幕（铺满）'
  $optAll.Tag = 'all'
  $items.Add($optAll)
  for ($i = 0; $i -lt $sorted.Count; $i++) {
    $s = $sorted[$i]
    $it = New-Object System.Windows.Controls.ComboBoxItem
    $it.Content = ('屏幕 {0}（{1}）' -f ($i + 1), $(if ($s.Primary) { '主' } elseif ($i+1 -eq 1) { '主' } else { '副' }))
    $it.Tag = [string] ($i + 1)
    $items.Add($it)
    if ($curDisp -eq [string] ($i + 1)) { $selected = $it }
  }
  if ($curDisp -eq 'all' -or $curDisp -eq '*') { $selected = $optAll }
  foreach ($it in $items) { [void] $combo.Items.Add($it) }
  if ($null -ne $selected) { $combo.SelectedItem = $selected } elseif ($items.Count -gt 0) { $combo.SelectedIndex = 0 }

  $combo.Add_SelectionChanged({
    param($s, $e)
    if ($null -eq $s.SelectedItem) { return }
    $tag = $s.SelectedItem.Tag
    Set-ScreenDisplay ([string] $tag)
  })

  $dispRow.Children.Add($dispLbl) | Out-Null
  $dispRow.Children.Add($combo) | Out-Null
  [void] $sp.Children.Add($dispRow)

  # 看过就收提醒 / 静音 / 外观档
  [void] $sp.Children.Add((New-ToggleRow '看过就收提醒' 'autoDismissEnabled' ([bool] ((Get-SettingValue 'autoDismissEnabled') -ge 0.5))))

  $muteRow = New-Object System.Windows.Controls.StackPanel
  $muteRow.Orientation = 'Horizontal'
  $muteRow.Margin = New-Object System.Windows.Thickness(0, 5, 0, 5)
  $muteLbl = New-Object System.Windows.Controls.TextBlock
  $muteLbl.Text = '声音'
  $muteLbl.Width = 92
  $muteLbl.VerticalAlignment = 'Center'
  $muteLbl.Foreground = [System.Windows.Media.Brushes]::White
  $muteCk = New-Object System.Windows.Controls.CheckBox
  $muteCk.Content = '提示音开启'
  $muteCk.VerticalAlignment = 'Center'
  $muteCk.IsChecked = (-not $Script:Muted)
  $muteCk.Add_Checked({ Set-Muted $false })
  $muteCk.Add_Unchecked({ Set-Muted $true })
  $muteRow.Children.Add($muteLbl) | Out-Null
  $muteRow.Children.Add($muteCk) | Out-Null
  [void] $sp.Children.Add($muteRow)

  $profRow = New-Object System.Windows.Controls.StackPanel
  $profRow.Orientation = 'Horizontal'
  $profRow.Margin = New-Object System.Windows.Thickness(0, 5, 0, 5)
  $profLbl = New-Object System.Windows.Controls.TextBlock
  $profLbl.Text = '外观档'
  $profLbl.Width = 92
  $profLbl.VerticalAlignment = 'Center'
  $profLbl.Foreground = [System.Windows.Media.Brushes]::White
  $profCombo = New-Object System.Windows.Controls.ComboBox
  $profCombo.Width = 250
  $profCombo.VerticalAlignment = 'Center'
  $profBanner = New-Object System.Windows.Controls.ComboBoxItem
  $profBanner.Content = 'banner  色带 + 文字'
  $profBanner.Tag = 'banner'
  $profMinimal = New-Object System.Windows.Controls.ComboBoxItem
  $profMinimal.Content = 'minimal  仅发丝线'
  $profMinimal.Tag = 'minimal'
  [void] $profCombo.Items.Add($profBanner)
  [void] $profCombo.Items.Add($profMinimal)
  if (([string] $Script:Cfg['profile']) -eq 'minimal') { $profCombo.SelectedItem = $profMinimal } else { $profCombo.SelectedItem = $profBanner }
  $profCombo.Add_SelectionChanged({
    param($s, $e)
    if ($null -eq $s.SelectedItem) { return }
    Set-Profile ([string] $s.SelectedItem.Tag)
  })
  $profRow.Children.Add($profLbl) | Out-Null
  $profRow.Children.Add($profCombo) | Out-Null
  [void] $sp.Children.Add($profRow)

  # ── 分区：效果颜色（三类单色，正确默认色已置顶） ──
  [void] $sp.Children.Add((New-SectionTitle '效果颜色（三类单色）'))
  $palette = @('#FFB454', '#FF6B6B', '#35D07F', '#56D4E0', '#7CA6FF', '#9D8CFF')
  [void] $sp.Children.Add((New-ColorRow '等待类' 'waiting' $palette))
  [void] $sp.Children.Add((New-ColorRow '错误类' 'error'   $palette))
  [void] $sp.Children.Add((New-ColorRow '完成类' 'done'    $palette))

  # ── 分区：色带 ──
  [void] $sp.Children.Add((New-SectionTitle '色带'))
  [void] $sp.Children.Add((New-SliderRow '全局透明度' 'globalAlpha' 0.10 1.00 (Get-SettingValue 'globalAlpha') 'pct'))

  # ── 分区：边缘能量场 ──
  # 说明：本分区只保留渲染引擎（Render-BorderFlash）真实消费的键：
  #   enabled / opacity（Set-GlowAlpha）/ cycleMs（Set-PulseMs）。
  # 原托盘/窗口曾有的 widthDip / sweepRatio / idleGlow 在渲染路径零引用（假设置），已删除。
  [void] $sp.Children.Add((New-SectionTitle '边缘能量场（边框流光）'))
  [void] $sp.Children.Add((New-ToggleRow '启用能量场' 'edgeGlowEnabled' ([bool] ((Get-SettingValue 'edgeGlowEnabled') -ge 0.5))))
  [void] $sp.Children.Add((New-SliderRow '发光浓淡'   'edgeGlowOpacity' 0.00 1.00 (Get-SettingValue 'edgeGlowOpacity') 'pct'))
  [void] $sp.Children.Add((New-SliderRow '闪烁节奏'   'pulseMs'      400 10000 (Get-SettingValue 'pulseMs')      'sec'))

  # 三类云图（金云/红云/绿云）已按用户要求移除：设置窗口不再暴露云图选项。

  $Script:SettingsInit = $false

  # ── 分区：调试工具 ──
  [void] $sp.Children.Add((New-SectionTitle '调试工具'))

  $row1 = New-Object System.Windows.Controls.StackPanel
  $row1.Orientation = 'Horizontal'
  $row1.HorizontalAlignment = 'Center'
  $row1.Margin = New-Object System.Windows.Thickness(0, 6, 0, 0)

  $btnTest = New-Object System.Windows.Controls.Button
  $btnTest.Content = '测试等待类'
  $btnTest.Width = 110
  $btnTest.Margin = New-Object System.Windows.Thickness(0, 0, 8, 0)
  $btnTest.Add_Click({ Invoke-WaitingDemo })

  $btnErr = New-Object System.Windows.Controls.Button
  $btnErr.Content = '测试错误类'
  $btnErr.Width = 110
  $btnErr.Margin = New-Object System.Windows.Thickness(0, 0, 8, 0)
  $btnErr.Add_Click({ Invoke-ErrorDemo })

  $btnDone = New-Object System.Windows.Controls.Button
  $btnDone.Content = '测试完成类'
  $btnDone.Width = 110
  $btnDone.Margin = New-Object System.Windows.Thickness(0, 0, 8, 0)
  $btnDone.Add_Click({ Invoke-DoneDemo })

  $row1.Children.Add($btnTest) | Out-Null
  $row1.Children.Add($btnErr) | Out-Null
  $row1.Children.Add($btnDone) | Out-Null
  [void] $sp.Children.Add($row1)

  $row2 = New-Object System.Windows.Controls.StackPanel
  $row2.Orientation = 'Horizontal'
  $row2.HorizontalAlignment = 'Center'
  $row2.Margin = New-Object System.Windows.Thickness(0, 8, 0, 0)

  $btnClear = New-Object System.Windows.Controls.Button
  $btnClear.Content = '清除当前提示'
  $btnClear.Width = 110
  $btnClear.Margin = New-Object System.Windows.Thickness(0, 0, 8, 0)
  $btnClear.Add_Click({ Clear-All })

  $btnDemo = New-Object System.Windows.Controls.Button
  $btnDemo.Content = '演示三类'
  $btnDemo.Width = 90
  $btnDemo.Margin = New-Object System.Windows.Thickness(0, 0, 8, 0)
  $btnDemo.Add_Click({ Invoke-Demo })

  $btnReset = New-Object System.Windows.Controls.Button
  $btnReset.Content = '恢复默认'
  $btnReset.Width = 90
  $btnReset.Add_Click({
    $def = @{ autoDismissEnabled = 1.0; pulseMs = 2600; globalAlpha = 1.0; edgeGlowEnabled = 1.0; edgeGlowOpacity = 0.16 }
    $Script:SettingsInit = $true
    foreach ($k in $Script:SettingsSliders.Keys) {
      if ($def.ContainsKey($k)) { $Script:SettingsSliders[$k].Value = [double] $def[$k] }
    }
    foreach ($k in @($Script:SettingsChecks.Keys)) {
      if ($def.ContainsKey($k)) { $Script:SettingsChecks[$k].IsChecked = ([double] $def[$k] -ge 0.5) }
    }
    $Script:SettingsInit = $false
    foreach ($k in @($def.Keys)) { Apply-Setting $k ([double] $def[$k]) }
    # 三类颜色恢复为正确默认色
    Set-KindColor 'waiting' '#FFB454'
    Set-KindColor 'error'   '#FF6B6B'
    Set-KindColor 'done'    '#35D07F'
    foreach ($g in @('waiting', 'error', 'done')) {
      if ($Script:ColorPreview.ContainsKey($g)) {
        $hex = Get-KindColor $g
        $n = ConvertFrom-HexColor $hex
        $Script:ColorPreview[$g].Background = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb([byte]$n[0], [byte]$n[1], [byte]$n[2]))
      }
    }
    # 显示器选择不在 Apply-Setting 数值体系内，单独恢复
    try { Set-ScreenDisplay 'primary' } catch { }
    $profCombo.SelectedItem = $profBanner
  })

  $row2.Children.Add($btnClear) | Out-Null
  $row2.Children.Add($btnDemo) | Out-Null
  $row2.Children.Add($btnReset) | Out-Null
  [void] $sp.Children.Add($row2)

  # 其他分区行：打开文件 / 退出
  [void] $sp.Children.Add((New-SectionTitle '其他'))
  $otherRow = New-Object System.Windows.Controls.StackPanel
  $otherRow.Orientation = 'Horizontal'
  $otherRow.HorizontalAlignment = 'Center'
  $otherRow.Margin = New-Object System.Windows.Thickness(0, 6, 0, 0)
  $btnCfg = New-Object System.Windows.Controls.Button
  $btnCfg.Content = '打开配置文件'
  $btnCfg.Width = 110
  $btnCfg.Margin = New-Object System.Windows.Thickness(0, 0, 8, 0)
  $btnCfg.Add_Click({ Invoke-OpenConfig })
  $btnSig = New-Object System.Windows.Controls.Button
  $btnSig.Content = '打开信号文件'
  $btnSig.Width = 110
  $btnSig.Margin = New-Object System.Windows.Thickness(0, 0, 8, 0)
  $btnSig.Add_Click({ Invoke-OpenSignal })
  $btnExit = New-Object System.Windows.Controls.Button
  $btnExit.Content = '退出助手'
  $btnExit.Width = 90
  $btnExit.Add_Click({ Invoke-Exit })
  $otherRow.Children.Add($btnCfg) | Out-Null
  $otherRow.Children.Add($btnSig) | Out-Null
  $otherRow.Children.Add($btnExit) | Out-Null
  [void] $sp.Children.Add($otherRow)

  # 内容超长时可滚动，确保新增的设置都能看到
  $sv = New-Object System.Windows.Controls.ScrollViewer
  $sv.VerticalScrollBarVisibility = 'Auto'
  $sv.HorizontalScrollBarVisibility = 'Disabled'
  $sv.Content = $sp
  $win.Content = $sv
  $win.Add_Closed({ $Script:SettingsWin = $null })
  $Script:SettingsWin = $win
  $win.Show()
}

function Build-TrayMenu {
  # 精简入口：所有实际生效的设置项已收编进设置窗口（Show-SettingsWindow）。
  # 托盘只保留少量必要动作，删除此前与窗口重复的各设置子菜单。
  $cm = New-Object System.Windows.Forms.ContextMenuStrip
  [void] $cm.Items.Add('效果设置窗口…', $null, { Show-SettingsWindow })
  [void] $cm.Items.Add('清除当前提示', $null, { Clear-All })
  [void] $cm.Items.Add('测试：依次演示 3 种颜色', $null, { Invoke-Demo })
  [void] $cm.Items.Add('-')
  [void] $cm.Items.Add('打开配置文件', $null, { Invoke-OpenConfig })
  [void] $cm.Items.Add('打开信号文件', $null, { Invoke-OpenSignal })
  [void] $cm.Items.Add('-')
  [void] $cm.Items.Add('退出助手', $null, { Invoke-Exit })
  return $cm
}

function Invoke-Demo {
  # 演示走真实通道：把信号追加进 signal.jsonl，由 tail 循环读回来
  try {
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $SignalPath) | Out-Null
    $sb = New-Object System.Text.StringBuilder
    $q = [long] $Script:SeqSeen
    foreach ($k in @('approval', 'error', 'done')) {
      $q++
      [void] $sb.AppendLine((@{ type = 'signal'; kind = $k; sessionId = 'session-demo0000'; text = 'DEMO'; seq = $q; at = (Now-Ms) } | ConvertTo-Json -Compress))
    }
    [System.IO.File]::AppendAllText($SignalPath, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))
    Write-AssistLog 'demo signals appended'
  } catch { Write-AssistLog ("demo failed: {0}" -f $_.Exception.Message) }
}

# ---------------------------------------------------------------------------
# 9. 启动窗口 + 主循环
# ---------------------------------------------------------------------------
$v0 = Get-ViewCfg
foreach ($lane in $Script:Lanes) {
  $lane.window.Left = 0
  $lane.window.Top = 0
  $lane.window.Width = $Script:BandWidthDip
  $lane.window.Height = [double] $v0.backdrop.height
  $lane.window.Opacity = 0
  $lane.image.Visibility = [System.Windows.Visibility]::Collapsed
  $lane.window.Show()

  try {
    $hwnd = (New-Object System.Windows.Interop.WindowInteropHelper($lane.window)).Handle
    $cur = [DshRem.Native]::GetWindowLong($hwnd, $GWL_EXSTYLE)
    [void] [DshRem.Native]::SetWindowLong($hwnd, $GWL_EXSTYLE, ($cur -bor $Script:ExStyleMask))
    [void] [DshRem.Native]::SetWindowPos($hwnd, [IntPtr] (-1), 0, 0, 0, 0, ($SWP_NOSIZE -bor $SWP_NOMOVE -bor $SWP_NOACTIVATE))
    Write-AssistLog ("lane {0} exstyle applied hwnd={1} before=0x{2:X8} after=0x{3:X8}" -f $lane.key, $hwnd, $cur, [DshRem.Native]::GetWindowLong($hwnd, $GWL_EXSTYLE))
  } catch {
    Write-AssistLog ("lane {0} exstyle failed: {1}" -f $lane.key, $_.Exception.Message)
  }
}

# 边框闪烁单窗口：显示并应用 WS_EX_LAYERED|TRANSPARENT|TOOLWINDOW|NOACTIVATE
try {
  $bfw = $Script:BorderFlash.window
  $bfw.Show()
  $hwnd = (New-Object System.Windows.Interop.WindowInteropHelper($bfw)).Handle
  $cur = [DshRem.Native]::GetWindowLong($hwnd, $GWL_EXSTYLE)
  [void] [DshRem.Native]::SetWindowLong($hwnd, $GWL_EXSTYLE, ($cur -bor $Script:ExStyleMask))
  [void] [DshRem.Native]::SetWindowPos($hwnd, [IntPtr] (-1), 0, 0, 0, 0, ($SWP_NOSIZE -bor $SWP_NOMOVE -bor $SWP_NOACTIVATE))
  $rect = New-Object DshRem.Native+RECT
  [void] [DshRem.Native]::GetWindowRect($hwnd, [ref] $rect)
  Write-AssistLog ("borderflash hwnd={0} rect=({1},{2})-({3},{4}) visible={5} exstyle=0x{6:X8}" -f $hwnd, $rect.Left, $rect.Top, $rect.Right, $rect.Bottom, [DshRem.Native]::IsWindowVisible($hwnd), [DshRem.Native]::GetWindowLong($hwnd, $GWL_EXSTYLE))
  Write-AssistLog "borderflash window ready"
} catch {
  Write-AssistLog ("borderflash init failed: {0}" -f $_.Exception.Message)
}

if (-not $NoTray) {
  try {
    $Script:Tray = New-Object System.Windows.Forms.NotifyIcon
    $Script:Tray.Icon = New-TrayIcon
    $Script:Tray.Visible = $true
    $Script:Tray.ContextMenuStrip = Build-TrayMenu
    # WinForms NotifyIcon 没有 Add_MouseWheel；滚轮调节改由菜单里的「更亮/更暗」承担，
    # 否则这里抛异常会中断整个 try，连 Set-TrayText 都执行不到。
    Set-TrayText
  } catch { Write-AssistLog ("tray failed: {0}" -f $_.Exception.Message) }
}

Restore-Snapshot
Update-Target

if ($ShowSettings) {
  # 启动即弹出效果设置窗口；主循环照常运行（提醒、热加载、托盘都不受影响）
  $Script:SettingsTick = New-Object System.Windows.Threading.DispatcherTimer
  $Script:SettingsTick.Interval = [TimeSpan]::FromMilliseconds(300)
  $Script:SettingsTick.Add_Tick({
    $Script:SettingsTick.Stop()
    Show-SettingsWindow
  })
  $Script:SettingsTick.Start()
}

$Script:NextTailMs = 0
$Script:NextCfgMs = 0
$Script:NextPingMs = 0
$Script:NextTrayMs = 0
$Script:NextDismissMs = 0
$Script:Deadline = if ($SelfTest) { (Now-Ms) + $SelfTestMs } else { [int64]::MaxValue }

$Script:TimerInstance = New-Object System.Windows.Threading.DispatcherTimer
$Script:TimerInstance.Interval = [TimeSpan]::FromMilliseconds([double] $Script:Cfg.pollMs)
$Script:TimerInstance.Add_Tick({
  $now = Now-Ms
  if ($Script:Stop -or $now -gt $Script:Deadline) {
    $Script:TimerInstance.Stop()
    if ($null -ne $Script:AnimTimer) { try { $Script:AnimTimer.Stop() } catch { } }
    $Script:Stop = $true
    foreach ($lane in $Script:Lanes) { try { $lane.window.Close() } catch { } }
    if ($SelfTest) { Write-AssistLog 'selftest finished' }
    [System.Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeShutdown()
    return
  }

  if ($now -ge $Script:NextTailMs) {
    $Script:NextTailMs = $now + [double] $Script:Cfg.fallback.pollMs
    Read-SignalFile
  }

  # 用户切到 DSH 窗口看过之后自动收掉先前的提醒（250ms 一次，代价极低）
  if ($now -ge $Script:NextDismissMs) {
    $Script:NextDismissMs = $now + 250
    try { Update-AutoDismiss } catch { Write-AssistLog ("auto dismiss error: {0}" -f $_.Exception.Message) }
  }

  if ($now -ge $Script:NextCfgMs) {
    $Script:NextCfgMs = $now + 1000
    Write-PidHeartbeat
    try {
      if ((Test-Path -LiteralPath $ConfigPath) -and (Get-Item -LiteralPath $ConfigPath).LastWriteTimeUtc -ne $Script:CfgStamp) {
        if (Read-Config) {
          $Script:TimerInstance.Interval = [TimeSpan]::FromMilliseconds([double] $Script:Cfg.pollMs)
          # 目标显示器改变时，边框闪烁窗口会在下一帧 Render-BorderFlash 中自动重定位
          $newRect = Get-DisplayRect
          if ($Script:PhysRect.Device -ne $newRect.Device -or $Script:PhysRect.L -ne $newRect.L -or $Script:PhysRect.T -ne $newRect.T) {
            $Script:PhysRect = $newRect
            Write-AssistLog ("display target changed -> {0} rect=({1},{2})-({3},{4})" -f $newRect.Device, $newRect.L, $newRect.T, $newRect.R, $newRect.B)
          }
          Write-AssistLog 'config reloaded'
          Show-TrayTip 'DSH 提醒' '配置已热加载'
        } else {
          Write-AssistLog 'config reload failed, keeping previous values'
        }
      }
    } catch { Write-AssistLog ("config watch error: {0}" -f $_.Exception.Message) }
  }

  if ($now -ge $Script:NextPingMs) {
    $Script:NextPingMs = $now + 2000
    try {
      foreach ($lane in $Script:Lanes) {
        $hwnd = (New-Object System.Windows.Interop.WindowInteropHelper($lane.window)).Handle
        [void] [DshRem.Native]::SetWindowPos($hwnd, [IntPtr] (-1), 0, 0, 0, 0, ($SWP_NOSIZE -bor $SWP_NOMOVE -bor $SWP_NOACTIVATE))
      }
      $hwnd = (New-Object System.Windows.Interop.WindowInteropHelper($Script:BorderFlash.window)).Handle
        [void] [DshRem.Native]::SetWindowPos($hwnd, [IntPtr] (-1), 0, 0, 0, 0, ($SWP_NOSIZE -bor $SWP_NOMOVE -bor $SWP_NOACTIVATE))
    } catch { }
  }

  Render

  if ($null -ne $Script:Tray -and $now -ge $Script:NextTrayMs) {
    $Script:NextTrayMs = $now + 1500
    Set-TrayText
  }
})
$Script:TimerInstance.Start()

# ── 独立 30fps 动画定时器（第一性原理：流畅度是「惊艳」的前提）──────────────
# 信号/云带仍由上面的 120ms 轮询驱动；边框能量场单独以 ~33ms 推进，
# 解耦后彗星移动连续平滑，不再随信号轮询一顿一顿。
# 用 try/catch 包裹，动画异常绝不影响信号主循环与进程存活。
$Script:GlobalScale = 1.0
$Script:AnimTimer = New-Object System.Windows.Threading.DispatcherTimer
$Script:AnimTimer.Interval = [TimeSpan]::FromMilliseconds(33)
$Script:AnimTimer.Add_Tick({
  try {
    $scaleNow = $Script:GlobalScale
    if ($null -eq $scaleNow) { $scaleNow = 1.0 }
    Render-BorderFlash (Now-Ms) $scaleNow
  } catch {
    # 只记一次，避免刷屏
    if (-not $Script:AnimErrLogged) {
      Write-AssistLog ("anim tick error: " + $_.Exception.Message)
      $Script:AnimErrLogged = $true
    }
  }
})
$Script:AnimTimer.Start()

Write-PidHeartbeat
Write-AssistLog ("assistant started pid={0} profile={1} signal={2}" -f $PID, $Script:Cfg.profile, $SignalPath)

function Save-WindowShot([string] $tag) {
  # 离屏渲染当前窗口内容为 PNG：不依赖屏幕截图，alpha 是真实合成结果，可量像素
  # 多通道并行：每条通道单独输出一张（tag 后缀 lane key），便于核对 done/等待/故障同时显示。
  try {
    New-Item -ItemType Directory -Force -Path $CaptureDir | Out-Null
    foreach ($lane in $Script:Lanes) {
      $w = [int] [Math]::Max(1, [Math]::Round($lane.window.Width))
      $h = [int] [Math]::Max(1, [Math]::Round($lane.window.Height))
      $rtb = New-Object System.Windows.Media.Imaging.RenderTargetBitmap($w, $h, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
      $dv = New-Object System.Windows.Media.DrawingVisual
      $dc = $dv.RenderOpen()
      $dc.DrawRectangle([System.Windows.Media.Brushes]::Black, $null, (New-Object System.Windows.Rect(0, 0, $w, $h)))
      if ($null -ne $lane.image -and $lane.image.Visibility -eq [System.Windows.Visibility]::Visible) {
        $dc.DrawRectangle([System.Windows.Media.VisualBrush]::new($lane.image), $null, (New-Object System.Windows.Rect(0, 0, $w, $h)))
      }
      $dc.Close()
      $rtb.Render($dv)
      $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
      $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($rtb))
      $fp = Join-Path $CaptureDir ("shot_{0}_{1}.png" -f $tag, $lane.key)
      $fs = [System.IO.File]::Create($fp)
      $enc.Save($fs); $fs.Dispose()
      Write-AssistLog ("capture {0}/{1} -> {2}" -f $tag, $lane.key, $fp)
    }
  } catch { Write-AssistLog ("capture failed: {0}" -f $_.Exception.Message) }
}

if ($SelfTest) {
  # 自检必须走定时器：Start-Sleep 会阻塞 Dispatcher 泵消息，色带根本不会渲染
  $Script:DemoQueue = New-Object System.Collections.Generic.Queue[object]
  $q = 500
  foreach ($k in @('done', 'approval', 'question', 'error', 'team', 'jobs', 'schedule', 'waiting')) {
    $q++
    $Script:DemoQueue.Enqueue(@{ kind = $k; seq = $q })
  }
  $q++
  $Script:DemoQueue.Enqueue(@{ resolve = 'approval'; seq = $q })
  $Script:DemoTick = New-Object System.Windows.Threading.DispatcherTimer
  $Script:DemoTick.Interval = [TimeSpan]::FromMilliseconds(1100)
  $Script:DemoTick.Add_Tick({
    if ($Script:DemoQueue.Count -eq 0) { $Script:DemoTick.Stop(); Write-AssistLog 'demo queue drained'; return }
    $d = $Script:DemoQueue.Dequeue()
    if ($d.resolve) {
      Invoke-SignalLine (@{ type = 'resolve'; target = $d.resolve; sessionId = 'session-demo0000'; seq = $d.seq; at = (Now-Ms) } | ConvertTo-Json -Compress)
    } else {
      Invoke-SignalLine (@{ type = 'signal'; kind = $d.kind; sessionId = 'session-demo0000'; text = ''; seq = $d.seq; at = (Now-Ms) } | ConvertTo-Json -Compress)
    }
    Write-AssistLog ("selftest inject {0}" -f $(if ($d.resolve) { "resolve:$($d.resolve)" } else { $d.kind }))
    if ($CaptureDir) {
      # 等淡入完成再截，量到的是稳定态
      $Script:CapTag = if ($d.resolve) { "resolve_$($d.resolve)" } else { [string] $d.kind }
      $Script:CapTimer = New-Object System.Windows.Threading.DispatcherTimer
      $Script:CapTimer.Interval = [TimeSpan]::FromMilliseconds(420)
      $Script:CapTimer.Add_Tick({
        $Script:CapTimer.Stop()
        Save-WindowShot ([string] $Script:CapTag)
      })
      $Script:CapTimer.Start()
    }
  })
  $Script:DemoTick.Start()

  # 透明度交互自检：等价于依次点托盘各档 + 更亮/更暗。
  # 任何一步抛异常都写进日志，自测跑完看一眼日志即可判定是否跑通。
  $Script:AlphaTest = New-Object System.Windows.Threading.DispatcherTimer
  $Script:AlphaTest.Interval = [TimeSpan]::FromMilliseconds(900)
  $Script:AlphaTest.Add_Tick({
    $Script:AlphaTest.Stop()
    try {
      foreach ($v in @(1.0, 0.8, 0.6, 0.4, 0.2, 0.1)) { Set-Alpha $v }
      Set-AdjustAlpha 0.1
      Set-AdjustAlpha -0.1
      Write-AssistLog ("alpha function test OK -> {0}" -f $Script:Cfg['typeAlphaScale'])
      Set-Alpha 1.0
    } catch {
      Write-AssistLog ("alpha function test FAILED: {0}" -f $_.Exception.Message)
    }
    if ($null -ne $Script:Tray -and $null -ne $Script:Tray.ContextMenuStrip) {
      try {
        $hit = $false
        foreach ($it in $Script:Tray.ContextMenuStrip.Items) {
          if ($it.Text -like '全局透明度*' -and $it.DropDownItems.Count -gt 2) {
            $it.DropDownItems[2].PerformClick()
            $it.DropDownItems[$it.DropDownItems.Count - 2].PerformClick()
            $hit = $true
            break
          }
        }
        if ($hit) { Write-AssistLog ("alpha menu click OK -> {0}" -f $Script:Cfg['typeAlphaScale']) }
        else { Write-AssistLog 'alpha menu click SKIPPED (item not found)' }
      } catch {
        Write-AssistLog ("alpha menu click FAILED: {0}" -f $_.Exception.Message)
      }
    } else {
      Write-AssistLog 'alpha menu click SKIPPED (no tray)'
    }
    Set-Alpha 1.0
  })
  $Script:AlphaTest.Start()
}

[System.Windows.Threading.Dispatcher]::Run()

try { if ($Script:Tray) { $Script:Tray.Visible = $false; $Script:Tray.Dispose() } } catch { }
try { Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue } catch { }
try { [void] $Script:Mutex.ReleaseMutex(); $Script:Mutex.Dispose() } catch { }
Write-AssistLog 'assistant stopped'
exit 0
