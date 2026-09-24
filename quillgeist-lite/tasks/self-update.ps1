$ErrorActionPreference = "Stop"

$HomeDir = Join-Path $env:LOCALAPPDATA "Clintware\QuillgeistLite"
$RunnerPath = Join-Path $HomeDir "runner.ps1"
$LauncherPath = Join-Path $HomeDir "launcher.ps1"
$ServiceRepairPath = Join-Path $HomeDir "repair-local-service.ps1"
$EnsurePwshPath = Join-Path $HomeDir "ensure-powershell.ps1"
$AutoRepairPath = Join-Path $HomeDir "auto-repair-runtime.ps1"
$BaseUrl = "https://raw.githubusercontent.com/codeFEDDY/codeFEDDY.github.io/main/quillgeist-lite"
$RestartHelper = Join-Path $HomeDir "restart-runner.ps1"
$RunnerPidPath = Join-Path $HomeDir "runner.pid"

New-Item -ItemType Directory -Force -Path $HomeDir | Out-Null

$updates = @(
  @{ Name = "runner";   Url = "$BaseUrl/runner.ps1";   Target = $RunnerPath },
  @{ Name = "launcher"; Url = "$BaseUrl/launcher.ps1"; Target = $LauncherPath },
  @{ Name = "service-repair"; Url = "$BaseUrl/tasks/repair-local-service.ps1"; Target = $ServiceRepairPath },
  @{ Name = "ensure-powershell"; Url = "$BaseUrl/tasks/ensure-powershell.ps1"; Target = $EnsurePwshPath },
  @{ Name = "auto-repair"; Url = "$BaseUrl/tasks/auto-repair-runtime.ps1"; Target = $AutoRepairPath }
)

Write-Host "SYNC" -ForegroundColor White -NoNewline
Write-Host " // downloading latest Quillgeist Lite terminal + runner" -ForegroundColor Cyan

foreach ($item in $updates) {
  $temp = $item.Target + ".new"
  Invoke-WebRequest -Uri ($item.Url + "?cb=" + [Guid]::NewGuid().ToString("n")) -OutFile $temp -UseBasicParsing -Headers @{"Cache-Control"="no-cache"}

  if (-not (Test-Path $temp)) {
    throw "$($item.Name) update download failed."
  }

  $tokens = $null
  $errors = $null
  [System.Management.Automation.Language.Parser]::ParseFile(
    (Resolve-Path $temp),
    [ref]$tokens,
    [ref]$errors
  ) | Out-Null

  if ($errors.Count -gt 0) {
    $errors | Format-List *
    Remove-Item $temp -Force -ErrorAction SilentlyContinue
    throw "Updated $($item.Name) failed local PowerShell parse validation."
  }
}

foreach ($item in $updates) {
  Move-Item ($item.Target + ".new") $item.Target -Force
  Write-Host ("UPDATED // " + $item.Name) -ForegroundColor Cyan
}

# Keep the service credential and device registration intact while refreshing the
# watchdog binary + scheduled-task recovery policy. When qq is already elevated
# this is silent; older standard installs may request one UAC approval.
$healthService = Get-Service -Name "CodeFEDDYQQHealth" -ErrorAction SilentlyContinue
if ($healthService) {
  Write-Host "SERVICE // repairing supervised runner recovery" -ForegroundColor Cyan
  $repairArgs = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "' + $ServiceRepairPath + '"'
  $repairHost = Get-Command pwsh.exe -ErrorAction SilentlyContinue
  $repairExe = if ($repairHost) { $repairHost.Source } else { "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" }
  $repair = Start-Process -FilePath $repairExe -ArgumentList $repairArgs -Wait -PassThru
  if ($repair.ExitCode -ne 0) {
    throw "qq health-service repair failed with exit code $($repair.ExitCode)."
  }
  Write-Host "UPDATED // health-service watchdog + stale-task policy" -ForegroundColor Cyan
}

$oldRunnerPid = 0

# The managed runner publishes its PID for the health service. Prefer that
# authoritative local marker over parent-process inference because Windows
# Terminal / PowerShell process ancestry can vary between hosts.
try {
  if (Test-Path $RunnerPidPath) {
    $rawPid = (Get-Content $RunnerPidPath -Raw).Trim()
    $parsedPid = 0
    if ([int]::TryParse($rawPid,[ref]$parsedPid) -and $parsedPid -gt 0) {
      $probe = Get-Process -Id $parsedPid -ErrorAction Stop
      if (-not $probe.HasExited) {
        $oldRunnerPid = $parsedPid
      }
    }
  }
} catch {}

if ($oldRunnerPid -le 0) {
  try {
    $current = Get-CimInstance Win32_Process -Filter "ProcessId=$PID"
    $currentCommand = [string]$current.CommandLine

    if ($currentCommand -match '(?i)quillgeistlite.*runner\.ps1|quillgeist-lite.*runner\.ps1|runner\.ps1') {
      $oldRunnerPid = $PID
    }
    elseif ($current.ParentProcessId) {
      $parent = Get-CimInstance Win32_Process -Filter ("ProcessId=" + [int]$current.ParentProcessId)
      $parentCommand = [string]$parent.CommandLine
      if ($parentCommand -match '(?i)quillgeistlite.*runner\.ps1|quillgeist-lite.*runner\.ps1|runner\.ps1') {
        $oldRunnerPid = [int]$current.ParentProcessId
      }
    }
  } catch {}
}

if ($oldRunnerPid -le 0) {
  Write-Host "WARN // files updated; runner PID could not be identified for automatic restart." -ForegroundColor DarkYellow
  exit 0
}

$helper = @'
param(
  [int]$OldRunnerPid,
  [string]$LauncherPath,
  [string]$HomeDir
)

Start-Sleep -Seconds 4

if ($OldRunnerPid -gt 0) {
  try {
    Stop-Process -Id $OldRunnerPid -Force -ErrorAction Stop
  } catch {}
}

Start-Sleep -Milliseconds 700

$pwsh = Get-Command pwsh.exe -ErrorAction SilentlyContinue
if (-not $pwsh) {
  $candidate = Join-Path $env:ProgramFiles "PowerShell\7\pwsh.exe"
  if (Test-Path $candidate) { $pwsh = Get-Item $candidate }
}
$exe = if ($pwsh) { $pwsh.Source } else { "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" }
$args = '-NoLogo -NoProfile -ExecutionPolicy Bypass -NoExit -File "' + $LauncherPath + '"'
Start-Process -FilePath $exe -ArgumentList $args -WorkingDirectory $HomeDir -WindowStyle Normal
'@

Set-Content -Path $RestartHelper -Value $helper -Encoding UTF8

Write-Host "RESTART // applying Clintware terminal theme after result return" -ForegroundColor Cyan
$restartArgs = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "' + $RestartHelper + '" -OldRunnerPid ' + $oldRunnerPid + ' -LauncherPath "' + $LauncherPath + '" -HomeDir "' + $HomeDir + '"'
$restartHost = Get-Command pwsh.exe -ErrorAction SilentlyContinue
$restartExe = if ($restartHost) { $restartHost.Source } else { "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" }
Start-Process -FilePath $restartExe -ArgumentList $restartArgs -WindowStyle Hidden

Write-Host "READY // Quillgeist Lite self-update staged successfully." -ForegroundColor White

