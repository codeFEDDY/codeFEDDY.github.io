$ErrorActionPreference = "Stop"

$HomeDir = Join-Path $env:LOCALAPPDATA "Clintware\QuillgeistLite"
$ServiceDir = Join-Path $HomeDir "service"

$BaseRaw = "https://raw.githubusercontent.com/codeFEDDY/codeFEDDY.github.io/main/quillgeist-lite"
$CacheBust = "?v=20260924-qq-recovery-5"
$RunnerPath = Join-Path $HomeDir "runner.ps1"
$LauncherPath = Join-Path $HomeDir "launcher.ps1"
$ServiceSourcePath = Join-Path $ServiceDir "QuillgeistLiteHealthService.cs"
$ServiceInstallerPath = Join-Path $ServiceDir "install-service.ps1"
$TerminalRepairPath = Join-Path $HomeDir "terminal_repair.py"
$BootSplashPath = Join-Path $HomeDir "boot_splash.py"
$EnsurePwshPath = Join-Path $HomeDir "ensure-powershell.ps1"
$AutoRepairPath = Join-Path $HomeDir "auto-repair-runtime.ps1"
$ServiceRepairPath = Join-Path $HomeDir "repair-local-service.ps1"
$RecoveryWatchPath = Join-Path $ServiceDir "recovery-watch.ps1"
$BootstrapPath = Join-Path $HomeDir "service-bootstrap.json"

Write-Host ""
Write-Host "=== INSTALL CODEFEDDY QQ ===" -ForegroundColor Cyan
Write-Host "Event-driven MCP -> local execution bridge + Windows health service" -ForegroundColor DarkGray
Write-Host "Quality-first runtime selection: PowerShell / Python / C" -ForegroundColor DarkGray
Write-Host ""

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
  if (Get-Command winget -ErrorAction SilentlyContinue) {
    Write-Host "Installing GitHub CLI..." -ForegroundColor Cyan
    winget install --id GitHub.cli --exact --source winget --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -ne 0) { throw "GitHub CLI installation failed." }

    $possibleGh = Join-Path $env:ProgramFiles "GitHub CLI"
    if (Test-Path $possibleGh) { $env:Path += ";$possibleGh" }
  } else {
    throw "GitHub CLI is required and winget is not available."
  }
}

gh auth status 2>$null
if ($LASTEXITCODE -ne 0) {
  Write-Host "Authenticating GitHub CLI..." -ForegroundColor Cyan
  gh auth login --hostname github.com --git-protocol https --web
  if ($LASTEXITCODE -ne 0) { throw "GitHub authentication failed." }
}

$login = (gh api user --jq .login).Trim()
if ($LASTEXITCODE -ne 0 -or $login.ToLowerInvariant() -ne "codeFEDDY") {
  throw "Quillgeist Lite expects the Clintware GitHub identity 'clintkosh'. Current identity: $login"
}

New-Item -ItemType Directory -Force -Path $HomeDir,$ServiceDir | Out-Null

$downloads = @{
  "$BaseRaw/runner.ps1$CacheBust" = $RunnerPath
  "$BaseRaw/launcher.ps1$CacheBust" = $LauncherPath
  "$BaseRaw/service/QuillgeistLiteHealthService.cs$CacheBust" = $ServiceSourcePath
  "$BaseRaw/service/install-service.ps1$CacheBust" = $ServiceInstallerPath
  "$BaseRaw/tools/terminal_repair.py$CacheBust" = $TerminalRepairPath
  "$BaseRaw/tools/boot_splash.py$CacheBust" = $BootSplashPath
  "$BaseRaw/tasks/ensure-powershell.ps1$CacheBust" = $EnsurePwshPath
  "$BaseRaw/tasks/auto-repair-runtime.ps1$CacheBust" = $AutoRepairPath
  "$BaseRaw/tasks/repair-local-service.ps1$CacheBust" = $ServiceRepairPath
  "$BaseRaw/service/recovery-watch.ps1$CacheBust" = $RecoveryWatchPath
}

foreach ($entry in $downloads.GetEnumerator()) {
  Invoke-WebRequest -Uri $entry.Key -OutFile $entry.Value -UseBasicParsing
  if (-not (Test-Path $entry.Value)) { throw "Download failed: $($entry.Key)" }
}

Write-Host "Validating local PowerShell files..." -ForegroundColor Cyan
foreach ($file in @($RunnerPath,$LauncherPath,$ServiceInstallerPath,$EnsurePwshPath,$AutoRepairPath,$ServiceRepairPath,$RecoveryWatchPath)) {
  $tokens = $null
  $errors = $null
  [System.Management.Automation.Language.Parser]::ParseFile($file,[ref]$tokens,[ref]$errors) | Out-Null
  if ($errors.Count -gt 0) {
    $errors | Format-List *
    throw "PowerShell parse validation failed: $file"
  }
}

Write-Host "Ensuring current PowerShell 7 runtime..." -ForegroundColor Cyan
try {
  & $EnsurePwshPath | Out-Host
} catch {
  Write-Host ("PWSH WARN // bootstrap will continue and launcher will retry: " + $_.Exception.Message) -ForegroundColor DarkYellow
}

Write-Host "Installing Python retro DOS boot renderer..." -ForegroundColor Cyan
Write-Host "SAFE HOST // Windows Terminal is intentionally excluded from the automatic qq lifecycle." -ForegroundColor DarkYellow

Write-Host "Provisioning health-service device credential..." -ForegroundColor Cyan

$bytes = New-Object byte[] 48
$rng = [Security.Cryptography.RandomNumberGenerator]::Create()
try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }

$DeviceToken = [Convert]::ToBase64String($bytes).TrimEnd("=").Replace("+","-").Replace("/","_")
$sha = [Security.Cryptography.SHA256]::Create()
try {
  $hashBytes = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($DeviceToken))
} finally {
  $sha.Dispose()
}
$TokenHash = -join ($hashBytes | ForEach-Object { $_.ToString("x2") })

$DeviceId = $env:COMPUTERNAME
$UserName = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$ghToken = (gh auth token).Trim()
if (-not $ghToken) { throw "GitHub CLI did not return an authentication token." }

$registerBody = @{
  device_id = $DeviceId
  token_hash = $TokenHash
  label = "$DeviceId / $env:USERNAME"
} | ConvertTo-Json -Compress

$registered = $false
$lastRegistrationError = $null

for ($i = 1; $i -le 18; $i++) {
  try {
    $response = Invoke-RestMethod -Method Post -Uri "https://mcp.codefeddy.com/api/v1/quillgeist-lite/devices/register" -Headers @{Authorization=("Bearer " + $ghToken)} -ContentType "application/json" -Body $registerBody
    if ($response.ok) {
      $registered = $true
      break
    }
  } catch {
    $lastRegistrationError = $_.Exception.Message
  }

  Write-Host "Waiting for CodeFEDDY Control Plane device endpoint ($i/18)..." -ForegroundColor DarkGray
  Start-Sleep -Seconds 5
}

if (-not $registered) {
  throw "Could not register the Quillgeist Lite health device. Last error: $lastRegistrationError"
}

$bootstrap = [ordered]@{
  HomeDir = $HomeDir
  DeviceId = $DeviceId
  DeviceToken = $DeviceToken
  Endpoint = "https://mcp.codefeddy.com"
  UserName = $UserName
}

$bootstrap | ConvertTo-Json -Depth 5 | Set-Content -Path $BootstrapPath -Encoding UTF8

$ServiceInstallMarker = Join-Path $HomeDir "service-install.ok"
Remove-Item $ServiceInstallMarker -Force -ErrorAction SilentlyContinue

try {
  Write-Host ""
  Write-Host "Windows will request one UAC approval to install the local health service." -ForegroundColor Yellow
  & $ServiceInstallerPath -BootstrapPath $BootstrapPath

  if (-not (Test-Path $ServiceInstallMarker)) {
    throw "Health service installation did not produce its success marker."
  }
}
finally {
  Remove-Item $BootstrapPath -Force -ErrorAction SilentlyContinue
  $DeviceToken = $null
  $ghToken = $null
}

Write-Host ""
Write-Host "==============================================" -ForegroundColor Green
Write-Host " CODEFEDDY QQ INSTALLED" -ForegroundColor Green
Write-Host "==============================================" -ForegroundColor Green
Write-Host "Health service : CodeFEDDYQQHealth"
Write-Host "Runner task    : CodeFEDDY qq Runner"
Write-Host "Execution      : PowerShell 7 preferred/self-updating / Python / C"
Write-Host "Policy         : Best result first; efficiency after quality"
Write-Host "Transport      : Event-driven outbound control channel"
Write-Host "Diagnostics    : Bounded health/errors -> CodeFEDDY Control Plane"
Write-Host "Terminal       : Safe PowerShell host + Python retro DOS boot splash"
Write-Host ""

