param(
  [switch]$Force
)

$ErrorActionPreference = "Stop"

$HomeDir = Join-Path $env:LOCALAPPDATA "Clintware\QuillgeistLite"
$MarkerPath = Join-Path $HomeDir "powershell7-check.json"
New-Item -ItemType Directory -Force -Path $HomeDir | Out-Null

function Resolve-Pwsh {
  $cmd = Get-Command pwsh.exe -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }

  $candidates = @(
    (Join-Path $env:ProgramFiles "PowerShell\7\pwsh.exe"),
    (Join-Path $env:ProgramW6432 "PowerShell\7\pwsh.exe")
  ) | Where-Object { $_ -and (Test-Path $_) }

  return ($candidates | Select-Object -First 1)
}

function Test-RefreshDue {
  if ($Force) { return $true }
  if (-not (Test-Path $MarkerPath)) { return $true }
  try {
    $marker = Get-Content $MarkerPath -Raw | ConvertFrom-Json
    $checked = [DateTime]::Parse([string]$marker.checked_at).ToUniversalTime()
    return (([DateTime]::UtcNow - $checked).TotalHours -ge 24)
  } catch {
    return $true
  }
}

$pwsh = Resolve-Pwsh
$refreshDue = Test-RefreshDue
$winget = Get-Command winget.exe -ErrorAction SilentlyContinue

if (-not $pwsh) {
  if (-not $winget) {
    throw "PowerShell 7 is not installed and winget is unavailable."
  }

  Write-Host "PWSH // installing current PowerShell 7" -ForegroundColor Cyan
  & $winget.Source install --id Microsoft.PowerShell --exact --source winget --accept-package-agreements --accept-source-agreements --silent
  $pwsh = Resolve-Pwsh
  if (-not $pwsh) {
    throw "PowerShell 7 installation completed without a discoverable pwsh.exe."
  }
}
elseif ($refreshDue -and $winget) {
  Write-Host "PWSH // checking for PowerShell 7 updates" -ForegroundColor DarkCyan
  try {
    & $winget.Source upgrade --id Microsoft.PowerShell --exact --source winget --accept-package-agreements --accept-source-agreements --silent --include-unknown
  } catch {
    Write-Host ("PWSH WARN // update check failed: " + $_.Exception.Message) -ForegroundColor DarkYellow
  }

  $pwsh = Resolve-Pwsh
}

$version = ""
try {
  $version = (& $pwsh -NoLogo -NoProfile -Command '$PSVersionTable.PSVersion.ToString()' 2>$null | Select-Object -First 1).Trim()
} catch {}

[ordered]@{
  checked_at = [DateTime]::UtcNow.ToString("o")
  path = $pwsh
  version = $version
} | ConvertTo-Json | Set-Content -Path $MarkerPath -Encoding UTF8

Write-Host ("PWSH_READY // " + $version + " // " + $pwsh) -ForegroundColor Green
$pwsh
