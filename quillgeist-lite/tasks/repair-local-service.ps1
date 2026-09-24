param(
  [switch]$SkipRunnerRestart
)

$ErrorActionPreference = "Stop"

$HomeDir = Join-Path $env:LOCALAPPDATA "Clintware\QuillgeistLite"
$ServiceDir = Join-Path $HomeDir "service"
$SourcePath = Join-Path $ServiceDir "QuillgeistLiteHealthService.cs"
$ProgramDir = Join-Path $env:ProgramData "Clintware\QuillgeistLite"
$ServiceExe = Join-Path $ProgramDir "QuillgeistLiteHealthService.exe"
$ServiceName = "CodeFEDDYQQHealth"
$TaskName = "CodeFEDDY qq Runner"
$LauncherPath = Join-Path $HomeDir "launcher.ps1"
$SourceUrl = "https://raw.githubusercontent.com/codeFEDDY/codeFEDDY.github.io/main/quillgeist-lite/service/QuillgeistLiteHealthService.cs"
$SelfUrl = "https://raw.githubusercontent.com/codeFEDDY/codeFEDDY.github.io/main/quillgeist-lite/tasks/repair-local-service.ps1"
$RepairVersion = "2026.09.24.8"
$LocalRepairPath = Join-Path $HomeDir "repair-local-service.ps1"
$AutoRepairPath = Join-Path $HomeDir "auto-repair-runtime.ps1"
$DeadmanPath = Join-Path $ProgramDir "service-restart-deadman.ps1"
$MaintenanceMarker = Join-Path $ProgramDir "maintenance.lock"
$RecoveryWatchPath = Join-Path $ServiceDir "recovery-watch.ps1"
$RecoveryWatchUrl = "https://raw.githubusercontent.com/codeFEDDY/codeFEDDY.github.io/main/quillgeist-lite/service/recovery-watch.ps1"
$FallbackTaskName = "CodeFEDDY qq Fallback Recovery"
$RecoveryConfigPath = Join-Path $ProgramDir "recovery.json"

Write-Host ("REPAIR // Quillgeist Lite self-heal " + $RepairVersion) -ForegroundColor White

function Test-Administrator {
  $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
  return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Administrator)) {
  $self = $MyInvocation.MyCommand.Path
  if (-not $self) { throw "qq service repair must run from a saved script file." }
  Write-Host "ADMIN // Windows may request approval to repair the qq health service." -ForegroundColor DarkYellow
  $args = '-NoProfile -ExecutionPolicy Bypass -File "' + $self + '"'
  $p = Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList $args -Verb RunAs -Wait -PassThru
  if ($p.ExitCode -ne 0) { throw "qq health-service repair failed with exit code $($p.ExitCode)." }
  exit 0
}

New-Item -ItemType Directory -Force -Path $ServiceDir,$ProgramDir | Out-Null

function Get-ClintwareRepoFile {
  param(
    [Parameter(Mandatory=$true)][string]$RepoPath,
    [Parameter(Mandatory=$true)][string]$Destination
  )

  $gh = Get-Command gh.exe -ErrorAction SilentlyContinue
  if (-not $gh) { $gh = Get-Command gh -ErrorAction SilentlyContinue }

  if ($gh) {
    try {
      $apiPath = "repos/codeFEDDY/codeFEDDY.github.io/contents/" + $RepoPath + "?ref=main"
      $metaRaw = (& $gh.Source api $apiPath 2>$null | Out-String).Trim()
      if ($LASTEXITCODE -eq 0 -and $metaRaw) {
        $meta = $metaRaw | ConvertFrom-Json
        if ($meta.content) {
          $base64 = ([string]$meta.content) -replace '\s',''
          $bytes = [Convert]::FromBase64String($base64)
          [IO.File]::WriteAllBytes($Destination,$bytes)
          return
        }
      }
    } catch {}
  }

  $raw = "https://raw.githubusercontent.com/codeFEDDY/codeFEDDY.github.io/main/" + $RepoPath
  Invoke-WebRequest -Uri ($raw + "?cb=" + [Guid]::NewGuid().ToString("n")) -Headers @{"Cache-Control"="no-cache"} -OutFile $Destination -UseBasicParsing
}



Write-Host "SERVICE // refreshing stale-task recovery watchdog" -ForegroundColor Cyan
$tempSource = $SourcePath + ".new"
Get-ClintwareRepoFile -RepoPath "quillgeist-lite/service/QuillgeistLiteHealthService.cs" -Destination $tempSource
if (-not (Test-Path $tempSource)) { throw "Could not download maintained qq health-service source." }
Move-Item $tempSource $SourcePath -Force

$cscCandidates = @(
  "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe",
  "$env:WINDIR\Microsoft.NET\Framework\v4.0.30319\csc.exe"
)
$csc = $cscCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $csc) { throw "The .NET Framework C# compiler is required to repair the qq health service." }

$tempExe = Join-Path $env:TEMP ("QuillgeistLiteHealthService-" + [Guid]::NewGuid().ToString("n") + ".exe")
& $csc /nologo /target:winexe /optimize+ /out:$tempExe /reference:System.ServiceProcess.dll /reference:System.Runtime.Serialization.dll $SourcePath
if ($LASTEXITCODE -ne 0 -or -not (Test-Path $tempExe)) {
  throw "Updated qq health-service source did not compile."
}

$service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if (-not $service) {
  Remove-Item $tempExe -Force -ErrorAction SilentlyContinue
  throw "The qq health service is not installed; run the maintained qq installer instead."
}

function Test-ServiceConfiguration {
  $configPath = Join-Path $ProgramDir "service.json"
  if (-not (Test-Path $configPath)) {
    throw "qq health-service config is missing: $configPath"
  }

  try {
    $cfg = Get-Content $configPath -Raw | ConvertFrom-Json
  } catch {
    throw ("qq health-service config is not valid JSON: " + $_.Exception.Message)
  }

  foreach ($name in @("Endpoint","DeviceId","Token","TaskName","RunnerPidPath")) {
    if (-not $cfg.$name) {
      throw ("qq health-service config is missing required field: " + $name)
    }
  }

  # Rewrite validated JSON without a BOM to avoid framework/parser ambiguity.
  $json = $cfg | ConvertTo-Json -Depth 8
  [IO.File]::WriteAllText($configPath,$json,(New-Object Text.UTF8Encoding($false)))
  Write-Host "CONFIG // health-service configuration validated" -ForegroundColor Cyan
  return $cfg
}

function Repair-ServiceRegistration {
  Write-Host "SERVICE // validating Windows service registration" -ForegroundColor Cyan

  $quotedExe = '"' + $ServiceExe + '"'
  & sc.exe config $ServiceName binPath= $quotedExe start= delayed-auto obj= LocalSystem type= own | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw "Could not repair Windows service registration."
  }

  & sc.exe failure $ServiceName reset= 86400 actions= restart/5000/restart/15000/restart/60000 | Out-Null
  & sc.exe failureflag $ServiceName 1 | Out-Null

  $svcInfo = Get-CimInstance Win32_Service -Filter ("Name='" + $ServiceName + "'") -ErrorAction SilentlyContinue
  if ($svcInfo) {
    Write-Host ("SERVICE // registered path " + $svcInfo.PathName) -ForegroundColor DarkCyan
    Write-Host ("SERVICE // account " + $svcInfo.StartName + " / start " + $svcInfo.StartMode) -ForegroundColor DarkCyan
  }
}

function Show-ServiceStartDiagnostics {
  Write-Host "SERVICE // startup diagnostics" -ForegroundColor DarkYellow

  try {
    $q = & sc.exe queryex $ServiceName 2>&1 | Out-String
    if ($q) { Write-Host ($q.Trim()) -ForegroundColor DarkYellow }
  } catch {}

  $startupLog = Join-Path $ProgramDir "service-startup-error.log"
  if (Test-Path $startupLog) {
    Write-Host "SERVICE STARTUP ERROR LOG:" -ForegroundColor Red
    Get-Content $startupLog -Tail 20 | ForEach-Object { Write-Host $_ -ForegroundColor Red }
  }

  try {
    $events = Get-WinEvent -FilterHashtable @{
      LogName = "System"
      ProviderName = "Service Control Manager"
      StartTime = (Get-Date).AddMinutes(-5)
    } -ErrorAction Stop | Where-Object {
      $_.Message -like ("*" + $ServiceName + "*") -or $_.Message -like "*Quillgeist Lite*"
    } | Select-Object -First 8
    foreach ($evt in $events) {
      Write-Host ("SCM " + $evt.Id + " // " + ($evt.Message -replace '[
]+',' ')) -ForegroundColor DarkYellow
    }
  } catch {}
}

function Install-FallbackRecovery {
  try {
    Write-Host "FALLBACK // installing scheduled qq recovery watchdog" -ForegroundColor DarkYellow

    $recoveryConfig = [ordered]@{
      ServiceRepairPath = $LocalRepairPath
      AutoRepairPath = $AutoRepairPath
      RecoveryWatchPath = $RecoveryWatchPath
      UpdatedAt = (Get-Date).ToUniversalTime().ToString("o")
    }
    [IO.File]::WriteAllText(
      $RecoveryConfigPath,
      ($recoveryConfig | ConvertTo-Json -Depth 6),
      (New-Object Text.UTF8Encoding($false))
    )
    Write-Host "RECOVERY // fallback repair paths persisted" -ForegroundColor DarkCyan

    Get-ClintwareRepoFile -RepoPath "quillgeist-lite/service/recovery-watch.ps1" -Destination $RecoveryWatchPath
    if (-not (Test-Path $RecoveryWatchPath)) { throw "recovery watchdog download failed" }

    $tokens = $null
    $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile(
      (Resolve-Path $RecoveryWatchPath),
      [ref]$tokens,
      [ref]$parseErrors
    ) | Out-Null
    if ($parseErrors.Count -gt 0) { throw "recovery watchdog parse validation failed" }

    $hostExe = Get-Command pwsh.exe -ErrorAction SilentlyContinue
    $exe = if ($hostExe) { $hostExe.Source } else { Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe" }
    $cmd = '"' + $exe + '" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "' + $RecoveryWatchPath + '"'

    & schtasks.exe /Create /TN $FallbackTaskName /TR $cmd /SC MINUTE /MO 1 /RU SYSTEM /RL HIGHEST /F | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "could not register fallback recovery task" }

    & schtasks.exe /Run /TN $FallbackTaskName | Out-Null
    Write-Host "FALLBACK // recovery watchdog active every minute" -ForegroundColor Green
    return $true
  } catch {
    Write-Host ("FALLBACK WARN // " + $_.Exception.Message) -ForegroundColor DarkYellow
    return $false
  }
}

function New-CompatibleTaskSettings {
  $common = @{
    AllowStartIfOnBatteries = $true
    DontStopIfGoingOnBatteries = $true
    StartWhenAvailable = $true
    ExecutionTimeLimit = [TimeSpan]::Zero
    ErrorAction = "Stop"
  }

  # The health service explicitly ends stale Task Scheduler wrappers before /Run,
  # so IgnoreNew is the desired policy. Resolve it from the local cmdlet metadata
  # instead of ever passing an enum value that this Windows build does not expose.
  try {
    $command = Get-Command New-ScheduledTaskSettingsSet -ErrorAction Stop
    $multi = $command.Parameters["MultipleInstances"]
    if ($multi -and $multi.ParameterType -and $multi.ParameterType.IsEnum) {
      $supported = [Enum]::GetNames($multi.ParameterType)
      if ($supported -contains "IgnoreNew") {
        $common["MultipleInstances"] = "IgnoreNew"
      } elseif ($supported -contains "Queue") {
        Write-Host "TASK // IgnoreNew unavailable; using Queue compatibility policy" -ForegroundColor DarkYellow
        $common["MultipleInstances"] = "Queue"
      } elseif ($supported -contains "Parallel") {
        Write-Host "TASK // only Parallel is available; watchdog will still end stale wrappers explicitly" -ForegroundColor DarkYellow
        $common["MultipleInstances"] = "Parallel"
      }
    }
  } catch {
    Write-Host ("WARN // could not inspect MultipleInstances support; using ScheduledTasks default: " + $_.Exception.Message) -ForegroundColor DarkYellow
  }

  return New-ScheduledTaskSettingsSet @common
}

$validatedConfig = Test-ServiceConfiguration
$settings = New-CompatibleTaskSettings

Write-Host "SERVICE // replacing watchdog binary" -ForegroundColor Cyan
$serviceWasRunning = ($service.Status -eq [System.ServiceProcess.ServiceControllerStatus]::Running)

# Arm an independent one-shot recovery process before stopping the service.
# If this repair process is terminated or crashes after Stop-Service, the
# helper restores the health service instead of leaving qq unsupervised.
$deadman = @'
param([string]$ServiceName,[string]$MaintenanceMarker)
Start-Sleep -Seconds 75
try { Remove-Item $MaintenanceMarker -Force -ErrorAction SilentlyContinue } catch {}
try {
  $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
  if ($svc -and $svc.Status -ne "Running") {
    Start-Service -Name $ServiceName -ErrorAction SilentlyContinue
  }
} catch {}
'@
[IO.File]::WriteAllText($DeadmanPath,$deadman,(New-Object Text.UTF8Encoding($false)))
Set-Content -Path $MaintenanceMarker -Value ((Get-Date).ToUniversalTime().ToString("o")) -Encoding ASCII
$deadmanArgs = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "' + $DeadmanPath + '" -ServiceName "' + $ServiceName + '" -MaintenanceMarker "' + $MaintenanceMarker + '"'
Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList $deadmanArgs -WindowStyle Hidden
Write-Host "SERVICE // arming restart dead-man" -ForegroundColor DarkCyan

Stop-Service -Name $ServiceName -Force -ErrorAction Stop
$service.WaitForStatus([System.ServiceProcess.ServiceControllerStatus]::Stopped,[TimeSpan]::FromSeconds(20))

$backup = $ServiceExe + ".previous"
Remove-Item $backup -Force -ErrorAction SilentlyContinue
if (Test-Path $ServiceExe) { Move-Item $ServiceExe $backup -Force }

try {
  Move-Item $tempExe $ServiceExe -Force

  $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue

if (-not $task) {
  if (-not (Test-Path $LauncherPath)) {
    throw "The qq launcher is missing: $LauncherPath"
  }

  Write-Host "TASK // runner task missing; recreating automatically" -ForegroundColor DarkYellow
  $pwsh = Get-Command pwsh.exe -ErrorAction SilentlyContinue
  if (-not $pwsh) {
    $pwshCandidate = Join-Path $env:ProgramFiles "PowerShell\7\pwsh.exe"
    if (Test-Path $pwshCandidate) { $pwsh = Get-Item $pwshCandidate }
  }
  $psExe = if ($pwsh) { $pwsh.Source } else { "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" }
  $taskArgs = '-NoLogo -NoProfile -ExecutionPolicy Bypass -NoExit -File "' + $LauncherPath + '"'
  $action = New-ScheduledTaskAction -Execute $psExe -Argument $taskArgs -WorkingDirectory $HomeDir
  $userName = [Security.Principal.WindowsIdentity]::GetCurrent().Name
  $trigger = New-ScheduledTaskTrigger -AtLogOn -User $userName
  $principal = New-ScheduledTaskPrincipal -UserId $userName -LogonType Interactive -RunLevel Highest

  Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description "Interactive ADMIN CodeFEDDY qq console. Automatically launched and supervised by the local health service." | Out-Null
  $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
} else {
  $pwsh = Get-Command pwsh.exe -ErrorAction SilentlyContinue
  if (-not $pwsh) {
    $pwshCandidate = Join-Path $env:ProgramFiles "PowerShell\7\pwsh.exe"
    if (Test-Path $pwshCandidate) { $pwsh = Get-Item $pwshCandidate }
  }
  $psExe = if ($pwsh) { $pwsh.Source } else { "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" }
  $taskArgs = '-NoLogo -NoProfile -ExecutionPolicy Bypass -NoExit -File "' + $LauncherPath + '"'
  $action = New-ScheduledTaskAction -Execute $psExe -Argument $taskArgs -WorkingDirectory $HomeDir
  Set-ScheduledTask -TaskName $TaskName -Action $action -Settings $settings | Out-Null
}

try {
  $configPath = Join-Path $ProgramDir "service.json"
  if (Test-Path $configPath) {
    $cfg = Get-Content $configPath -Raw | ConvertFrom-Json
    $cfg | Add-Member -NotePropertyName AutoRepairPath -NotePropertyValue $AutoRepairPath -Force
    $cfg | ConvertTo-Json -Depth 8 | Set-Content -Path $configPath -Encoding UTF8
  }
} catch {
  Write-Host ("WARN // could not persist auto-repair path: " + $_.Exception.Message) -ForegroundColor DarkYellow
}

try {
  Enable-ScheduledTask -TaskName $TaskName -ErrorAction Stop | Out-Null
  Write-Host "TASK // runner task enabled" -ForegroundColor Cyan
} catch {
  Write-Host ("WARN // runner task could not be enabled: " + $_.Exception.Message) -ForegroundColor DarkYellow
}

Write-Host "TASK // automatic runner recovery is configured" -ForegroundColor Cyan

Set-Service -Name $ServiceName -StartupType Automatic
Repair-ServiceRegistration

$serviceStarted = $false
try {
  Start-Service -Name $ServiceName -ErrorAction Stop
  Remove-Item $MaintenanceMarker -Force -ErrorAction SilentlyContinue
  (Get-Service -Name $ServiceName).WaitForStatus([System.ServiceProcess.ServiceControllerStatus]::Running,[TimeSpan]::FromSeconds(20))
  $serviceStarted = $true
} catch {
  Remove-Item $MaintenanceMarker -Force -ErrorAction SilentlyContinue
  Write-Host ("SERVICE WARN // native watchdog could not start: " + $_.Exception.Message) -ForegroundColor DarkYellow
  Show-ServiceStartDiagnostics
  [void](Install-FallbackRecovery)
}

if ($serviceStarted) {
  Write-Host "SERVICE // native health watchdog running" -ForegroundColor Green
} else {
  Write-Host "SERVICE // using scheduled fallback watchdog while native service is unavailable" -ForegroundColor DarkYellow
}

# Always retain a second, independent SYSTEM recovery path. It is idempotent and
# only intervenes when the service or runner is unhealthy.
if (Install-FallbackRecovery) {
  Write-Host "FALLBACK // independent recovery layer ensured" -ForegroundColor Green
}

if (-not $SkipRunnerRestart) {
  try {
    Enable-ScheduledTask -TaskName $TaskName -ErrorAction Stop | Out-Null
    Start-ScheduledTask -TaskName $TaskName -ErrorAction Stop
    Write-Host "TASK // runner start requested immediately" -ForegroundColor Cyan
  } catch {
    Write-Host ("WARN // runner task could not be started immediately: " + $_.Exception.Message) -ForegroundColor DarkYellow
  }
} else {
  Write-Host "TASK // runner restart deferred because an active qq job is using this session" -ForegroundColor DarkGray
}

  Remove-Item $backup -Force -ErrorAction SilentlyContinue

  # Persist the known-good repair logic locally so future self-update/control-plane
  # recovery does not depend on an older cached copy.
  try {
    $localRepairTemp = $LocalRepairPath + ".new"
    Get-ClintwareRepoFile -RepoPath "quillgeist-lite/tasks/repair-local-service.ps1" -Destination $localRepairTemp
    $tokens = $null
    $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile(
      (Resolve-Path $localRepairTemp),
      [ref]$tokens,
      [ref]$parseErrors
    ) | Out-Null
    if ($parseErrors.Count -gt 0) {
      Remove-Item $localRepairTemp -Force -ErrorAction SilentlyContinue
      throw "downloaded repair script failed parser validation"
    }
    Move-Item $localRepairTemp $LocalRepairPath -Force
    Write-Host "SELF-HEAL // canonical repair logic cached locally" -ForegroundColor Cyan
  } catch {
    Write-Host ("WARN // service is repaired, but local repair-script refresh failed: " + $_.Exception.Message) -ForegroundColor DarkYellow
  }

  Write-Host "READY // qq recovery repaired; native service or scheduled fallback is supervising the runner." -ForegroundColor Green
} catch {
  $repairError = $_
  Write-Host ("SELF-HEAL // repair step failed: " + $repairError.Exception.Message) -ForegroundColor Red

  try {
    Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
    if (Test-Path $backup) {
      Remove-Item $ServiceExe -Force -ErrorAction SilentlyContinue
      Move-Item $backup $ServiceExe -Force
      Write-Host "SELF-HEAL // previous watchdog binary restored" -ForegroundColor DarkYellow
    }
    Set-Service -Name $ServiceName -StartupType Automatic -ErrorAction SilentlyContinue
    Remove-Item $MaintenanceMarker -Force -ErrorAction SilentlyContinue
    Start-Service -Name $ServiceName -ErrorAction SilentlyContinue
    $recovered = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($recovered -and $recovered.Status -eq "Running") {
      Write-Host "SELF-HEAL // watchdog returned to Running state" -ForegroundColor Green
    }
  } catch {
    Write-Host ("SELF-HEAL WARN // rollback encountered: " + $_.Exception.Message) -ForegroundColor DarkYellow
  }

  Remove-Item $tempExe -Force -ErrorAction SilentlyContinue
  throw $repairError
}

