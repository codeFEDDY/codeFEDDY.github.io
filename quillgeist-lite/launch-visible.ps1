$ErrorActionPreference = "Stop"

$HomeDir = Join-Path $env:LOCALAPPDATA "Clintware\QuillgeistLite"
$LauncherPath = Join-Path $HomeDir "launcher.ps1"
$EnsurePwshPath = Join-Path $HomeDir "ensure-powershell.ps1"
$BaseRaw = "https://raw.githubusercontent.com/codeFEDDY/codeFEDDY.github.io/main/quillgeist-lite"

New-Item -ItemType Directory -Force -Path $HomeDir | Out-Null

Write-Host "Refreshing CodeFEDDY qq launcher..." -ForegroundColor Cyan

$downloads = @(
  @{ Url = "$BaseRaw/launcher.ps1?v=2026.09.24.8"; Target = $LauncherPath },
  @{ Url = "$BaseRaw/tasks/ensure-powershell.ps1?v=2026.09.24.8"; Target = $EnsurePwshPath }
)

foreach ($item in $downloads) {
  $temp = $item.Target + ".new"
  Invoke-WebRequest -Uri $item.Url -OutFile $temp -UseBasicParsing -Headers @{"Cache-Control"="no-cache"}

  $tokens = $null
  $errors = $null
  [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $temp),[ref]$tokens,[ref]$errors) | Out-Null
  if ($errors.Count -gt 0) {
    Remove-Item $temp -Force -ErrorAction SilentlyContinue
    throw "Downloaded qq launcher component failed PowerShell validation: $($item.Target)"
  }

  Move-Item $temp $item.Target -Force
}

$pwshPath = $null
try {
  $pwshPath = @(& $EnsurePwshPath) | Select-Object -Last 1
  $pwshPath = [string]$pwshPath
} catch {
  Write-Host ("PWSH WARN // " + $_.Exception.Message) -ForegroundColor DarkYellow
}

if (-not $pwshPath -or -not (Test-Path $pwshPath)) {
  $pwsh = Get-Command pwsh.exe -ErrorAction SilentlyContinue
  if ($pwsh) { $pwshPath = $pwsh.Source }
}

if (-not $pwshPath -or -not (Test-Path $pwshPath)) {
  $pwshPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
}

Write-Host ("Opening visible Quillgeist Lite window with " + $pwshPath) -ForegroundColor Green
Start-Process -FilePath $pwshPath -ArgumentList @("-NoLogo","-NoProfile","-ExecutionPolicy","Bypass","-NoExit","-File",$LauncherPath) -WorkingDirectory $HomeDir -WindowStyle Normal

Write-Host "Launch requested. Look for a window titled: CodeFEDDY qq" -ForegroundColor Green

