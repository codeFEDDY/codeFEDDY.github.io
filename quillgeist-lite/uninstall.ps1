param(
  [switch]$Purge
)

$ErrorActionPreference = "Stop"

$ServiceName = "CodeFEDDYQQHealth"
$TaskName = "CodeFEDDY qq Runner"
$HomeDir = Join-Path $env:LOCALAPPDATA "Clintware\QuillgeistLite"
$ProgramDir = Join-Path $env:ProgramData "Clintware\QuillgeistLite"
$MaintenanceMarker = Join-Path $ProgramDir "maintenance.lock"

function Test-Administrator {
  $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = New-Object Security.Principal.WindowsPrincipal($identity)
  return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Administrator)) {
  $self = $MyInvocation.MyCommand.Path
  if (-not $self) { throw "Uninstaller must run from a saved script file." }

  $args = '-NoProfile -ExecutionPolicy Bypass -File "' + $self + '"'
  if ($Purge) { $args += ' -Purge' }

  $p = Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList $args -Verb RunAs -Wait -PassThru
  if ($p.ExitCode -ne 0) { throw "Elevated uninstall failed with exit code $($p.ExitCode)." }
  exit 0
}

$service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($service) {
  try { Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue } catch {}
  & sc.exe delete $ServiceName | Out-Null
}

$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($task) {
  Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}

$startupShortcut = Join-Path ([Environment]::GetFolderPath("Startup")) "CodeFEDDY qq.lnk"
$commonShortcut = Join-Path ([Environment]::GetFolderPath("CommonStartup")) "CodeFEDDY qq.lnk"
Remove-Item $startupShortcut -Force -ErrorAction SilentlyContinue
Remove-Item $commonShortcut -Force -ErrorAction SilentlyContinue

if ($Purge) {
  Remove-Item $ProgramDir -Recurse -Force -ErrorAction SilentlyContinue
  Remove-Item $HomeDir -Recurse -Force -ErrorAction SilentlyContinue
  Write-Host "Quillgeist Lite service, task, configuration, logs, and local files removed." -ForegroundColor Green
} else {
  Write-Host "Quillgeist Lite service and runner task removed." -ForegroundColor Green
  Write-Host "Local logs/files retained at: $HomeDir"
  Write-Host "Machine health files retained at: $ProgramDir"
}

