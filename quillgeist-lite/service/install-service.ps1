param(
  [Parameter(Mandatory=$true)]
  [string]$BootstrapPath
)

$ErrorActionPreference = "Stop"

function Test-Administrator {
  $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = New-Object Security.Principal.WindowsPrincipal($identity)
  return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Administrator)) {
  $self = $MyInvocation.MyCommand.Path
  if (-not $self) { throw "Service installer must run from a saved script file." }

  $args = '-NoProfile -ExecutionPolicy Bypass -File "' + $self + '" -BootstrapPath "' + $BootstrapPath + '"'
  $p = Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList $args -Verb RunAs -Wait -PassThru
  if ($p.ExitCode -ne 0) { throw "Elevated Quillgeist Lite service installation failed with exit code $($p.ExitCode)." }
  return
}

$bootstrap = Get-Content $BootstrapPath -Raw | ConvertFrom-Json

$HomeDir = [string]$bootstrap.HomeDir
$DeviceId = [string]$bootstrap.DeviceId
$DeviceToken = [string]$bootstrap.DeviceToken
$Endpoint = [string]$bootstrap.Endpoint
$UserName = [string]$bootstrap.UserName

if (-not $HomeDir -or -not $DeviceId -or -not $DeviceToken -or -not $Endpoint -or -not $UserName) {
  throw "Quillgeist Lite service bootstrap data is incomplete."
}

$ProgramDir = Join-Path $env:ProgramData "Clintware\QuillgeistLite"
$SourcePath = Join-Path $HomeDir "service\QuillgeistLiteHealthService.cs"
$ServiceExe = Join-Path $ProgramDir "QuillgeistLiteHealthService.exe"
$ConfigPath = Join-Path $ProgramDir "service.json"
$ServiceLog = Join-Path $ProgramDir "service-local.log"
$MaintenanceMarker = Join-Path $ProgramDir "maintenance.lock"

$LauncherPath = Join-Path $HomeDir "launcher.ps1"
$RunnerPidPath = Join-Path $HomeDir "runner.pid"
$RunnerLogPath = Join-Path $HomeDir "runner.log"
$CrashLogPath = Join-Path $HomeDir "runner-crash.log"
$AutoRepairPath = Join-Path $HomeDir "auto-repair-runtime.ps1"

$ServiceName = "CodeFEDDYQQHealth"
$TaskName = "CodeFEDDY qq Runner"

New-Item -ItemType Directory -Force -Path $ProgramDir | Out-Null

if (-not (Test-Path $SourcePath)) { throw "Missing health service source: $SourcePath" }
if (-not (Test-Path $LauncherPath)) { throw "Missing Quillgeist Lite launcher: $LauncherPath" }

Write-Host "Compiling CodeFEDDY qq health service..." -ForegroundColor Cyan

$existingService = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($existingService) {
  Set-Content -Path $MaintenanceMarker -Value ((Get-Date).ToUniversalTime().ToString("o")) -Encoding ASCII
  try { Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue } catch {}
}

Start-Sleep -Milliseconds 800
Remove-Item $ServiceExe -Force -ErrorAction SilentlyContinue

$cscCandidates = @(
  "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe",
  "$env:WINDIR\Microsoft.NET\Framework\v4.0.30319\csc.exe"
)
$csc = $cscCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $csc) { throw "The .NET Framework C# compiler (csc.exe) is required to install the Quillgeist Lite health service." }

& $csc /nologo /target:winexe /optimize+ /out:$ServiceExe /reference:System.ServiceProcess.dll /reference:System.Runtime.Serialization.dll $SourcePath
if ($LASTEXITCODE -ne 0) { throw "Health service C# compilation failed with exit code $LASTEXITCODE." }

if (-not (Test-Path $ServiceExe)) { throw "Health service compilation did not produce $ServiceExe" }

$config = [ordered]@{
  Endpoint = $Endpoint
  DeviceId = $DeviceId
  Token = $DeviceToken
  TaskName = $TaskName
  RunnerPidPath = $RunnerPidPath
  RunnerLogPath = $RunnerLogPath
  CrashLogPath = $CrashLogPath
  LocalServiceLogPath = $ServiceLog
  AutoRepairPath = $AutoRepairPath
}

$config | ConvertTo-Json -Depth 6 | Set-Content -Path $ConfigPath -Encoding UTF8

& icacls.exe $ProgramDir /inheritance:r /grant:r "SYSTEM:(OI)(CI)F" "Administrators:(OI)(CI)F" | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Could not secure the Quillgeist Lite service directory." }

Write-Host "Registering interactive Quillgeist Lite runner task..." -ForegroundColor Cyan

$oldTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($oldTask) {
  Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}

$pwsh = Get-Command pwsh.exe -ErrorAction SilentlyContinue
if (-not $pwsh) {
  $pwshCandidate = Join-Path $env:ProgramFiles "PowerShell\7\pwsh.exe"
  if (Test-Path $pwshCandidate) { $pwsh = Get-Item $pwshCandidate }
}
$psExe = if ($pwsh) { $pwsh.Source } else { "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" }
$taskArgs = '-NoLogo -NoProfile -ExecutionPolicy Bypass -NoExit -File "' + $LauncherPath + '"'

$action = New-ScheduledTaskAction -Execute $psExe -Argument $taskArgs -WorkingDirectory $HomeDir
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $UserName
# The service cannot display UI from Session 0. It launches this interactive task
# in the signed-in user's session instead. RunLevel Highest makes qq an admin
# console after this one-time elevated installation while the remote MCP surface
# remains constrained to the reviewed task allowlist.
$principal = New-ScheduledTaskPrincipal -UserId $UserName -LogonType Interactive -RunLevel Highest
# Use a policy actually supported by this machine. The watchdog itself ends stale
# wrappers before restarting the task, so StopExisting is neither required nor portable.
$settingsArgs = @{
  AllowStartIfOnBatteries = $true
  DontStopIfGoingOnBatteries = $true
  StartWhenAvailable = $true
  ExecutionTimeLimit = [TimeSpan]::Zero
  ErrorAction = "Stop"
}
$multi = (Get-Command New-ScheduledTaskSettingsSet -ErrorAction Stop).Parameters["MultipleInstances"]
if ($multi -and $multi.ParameterType -and $multi.ParameterType.IsEnum) {
  $supported = [Enum]::GetNames($multi.ParameterType)
  if ($supported -contains "IgnoreNew") { $settingsArgs["MultipleInstances"] = "IgnoreNew" }
  elseif ($supported -contains "Queue") { $settingsArgs["MultipleInstances"] = "Queue" }
  elseif ($supported -contains "Parallel") { $settingsArgs["MultipleInstances"] = "Parallel" }
}
$settings = New-ScheduledTaskSettingsSet @settingsArgs

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description "Interactive ADMIN CodeFEDDY qq console. Automatically launched and supervised by the local health service; stale instances are replaced." | Out-Null
Enable-ScheduledTask -TaskName $TaskName -ErrorAction Stop | Out-Null

Write-Host "Registering Windows health service..." -ForegroundColor Cyan

if (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue) {
  & sc.exe delete $ServiceName | Out-Null
  Start-Sleep -Seconds 2
}

New-Service -Name $ServiceName -BinaryPathName ('"' + $ServiceExe + '"') -DisplayName "CodeFEDDY qq Health" -Description "Maintains Quillgeist Lite local runner health and securely uplinks bounded diagnostics to the CodeFEDDY Control Plane." -StartupType Automatic | Out-Null

& sc.exe config $ServiceName start= delayed-auto | Out-Null
& sc.exe failure $ServiceName reset= 86400 actions= restart/5000/restart/15000/restart/60000 | Out-Null
& sc.exe failureflag $ServiceName 1 | Out-Null

$startupShortcut = Join-Path ([Environment]::GetFolderPath("CommonStartup")) "CodeFEDDY qq.lnk"
$userStartupShortcut = Join-Path ([Environment]::GetFolderPath("Startup")) "CodeFEDDY qq.lnk"
Remove-Item $startupShortcut -Force -ErrorAction SilentlyContinue
Remove-Item $userStartupShortcut -Force -ErrorAction SilentlyContinue

Start-Service -Name $ServiceName
Remove-Item $MaintenanceMarker -Force -ErrorAction SilentlyContinue
Enable-ScheduledTask -TaskName $TaskName -ErrorAction Stop | Out-Null
Start-ScheduledTask -TaskName $TaskName -ErrorAction Stop

Start-Sleep -Seconds 2

$service = Get-Service -Name $ServiceName
if ($service.Status -ne "Running") { throw "Quillgeist Lite health service did not reach Running state." }

Set-Content -Path (Join-Path $HomeDir "service-install.ok") -Value ((Get-Date).ToUniversalTime().ToString("o")) -Encoding ASCII

Write-Host ""
Write-Host "HEALTH SERVICE ACTIVE" -ForegroundColor Green
Write-Host "Service : $ServiceName"
Write-Host "Runner  : $TaskName"
Write-Host "Device  : $DeviceId"
Write-Host ""

Remove-Item $BootstrapPath -Force -ErrorAction SilentlyContinue

