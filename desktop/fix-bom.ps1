# Add a UTF-8 BOM to the .ps1 files in this directory, then syntax-check them.
#
# Why: Windows PowerShell 5.1 decodes a BOM-less UTF-8 script as ANSI, which
# turns every Chinese string literal into mojibake and can break parsing. Our
# editor/toolchain writes BOM-less UTF-8, so run this after each edit:
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File desktop\fix-bom.ps1
#
# This file is deliberately ASCII-only, so it works without a BOM.
param([string] $Dir = (Split-Path -Parent $MyInvocation.MyCommand.Path))

$targets = @(Get-ChildItem -LiteralPath $Dir -Filter '*.ps1' -File)
if ($targets.Count -eq 0) { Write-Host 'no .ps1 files found'; exit 1 }

foreach ($t in $targets) {
  $bytes = [System.IO.File]::ReadAllBytes($t.FullName)
  if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
    Write-Host ("bom already present: " + $t.Name)
    continue
  }
  $out = New-Object byte[] ($bytes.Length + 3)
  $out[0] = 0xEF; $out[1] = 0xBB; $out[2] = 0xBF
  [Array]::Copy($bytes, 0, $out, 3, $bytes.Length)
  [System.IO.File]::WriteAllBytes($t.FullName, $out)
  Write-Host ("bom added: " + $t.Name)
}

$fail = 0
foreach ($t in $targets) {
  $errs = $null; $toks = $null
  [void] [System.Management.Automation.Language.Parser]::ParseFile($t.FullName, [ref] $toks, [ref] $errs)
  if ($errs -and $errs.Count -gt 0) {
    $fail = 1
    Write-Host ("SYNTAX FAIL: " + $t.Name) -ForegroundColor Red
    foreach ($e in ($errs | Select-Object -First 6)) {
      Write-Host ("  L" + $e.Extent.StartLineNumber + ": " + $e.Message)
    }
  } else {
    Write-Host ("syntax ok: " + $t.Name) -ForegroundColor Green
  }
}
exit $fail
