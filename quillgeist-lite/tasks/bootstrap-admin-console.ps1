param(
  [switch]$Elevated,
  [int]$RunnerPid = 0
)

$ErrorActionPreference = "Stop"

$TaskName = "CodeFEDDY qq Runner"
$HomeDir = Join-Path $env:LOCALAPPDATA "Clintware\QuillgeistLite"

function Test-Administrator {
  $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = New-Object Security.Principal.WindowsPrincipal($identity)
  return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Find-RunnerPid {
  try {
    $current = Get-CimInstance Win32_Process -Filter "ProcessId=$PID"
    if ($current.ParentProcessId) {
      $parent = Get-CimInstance Win32_Process -Filter ("ProcessId=" + [int]$current.ParentProcessId)
      if ([string]$parent.CommandLine -match '(?i)quillgeistlite.*runner\.ps1|quillgeist-lite.*runner\.ps1|runner\.ps1') {
        return [int]$current.ParentProcessId
      }

      if ($parent.ParentProcessId) {
        $grand = Get-CimInstance Win32_Process -Filter ("ProcessId=" + [int]$parent.ParentProcessId)
        if ([string]$grand.CommandLine -match '(?i)quillgeistlite.*runner\.ps1|quillgeist-lite.*runner\.ps1|runner\.ps1') {
          return [int]$parent.ParentProcessId
        }
      }
    }
  } catch {}
  return 0
}

if ($RunnerPid -le 0) {
  $RunnerPid = Find-RunnerPid
}

if (-not (Test-Administrator)) {
  $self = $MyInvocation.MyCommand.Path
  if (-not $self) { throw "qq admin bootstrap must run from a saved script file." }

  Write-Host "ADMIN // Windows will request one UAC approval for the managed qq service." -ForegroundColor DarkYellow
  $args = '-NoProfile -ExecutionPolicy Bypass -File "' + $self + '" -Elevated -RunnerPid ' + $RunnerPid
  $p = Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList $args -Verb RunAs -Wait -PassThru
  if ($p.ExitCode -ne 0) {
    throw "qq admin bootstrap failed with exit code $($p.ExitCode)."
  }
  exit 0
}

$installedNow = $false
$changedPrincipal = $false
$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue

if (-not $task) {
  Write-Host "SERVICE // qq managed service/task is missing. Installing it now." -ForegroundColor Cyan
  $installerUrl = "https://raw.githubusercontent.com/codeFEDDY/codeFEDDY.github.io/main/quillgeist-lite/install.ps1?v=20260922-qq-admin-2"
  $installer = (Invoke-WebRequest -Uri $installerUrl -UseBasicParsing -Headers @{"Cache-Control"="no-cache"}).Content
  if (-not $installer) { throw "Could not download the maintained qq installer." }

  Invoke-Expression $installer
  $installedNow = $true

  $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
  if (-not $task) {
    throw "qq installer completed without creating the managed interactive task."
  }
}

if (([string]$task.Principal.RunLevel) -ne "Highest") {
  $user = $task.Principal.UserId
  if (-not $user) {
    $user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
  }
  $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
  Set-ScheduledTask -TaskName $TaskName -Principal $principal | Out-Null
  $changedPrincipal = $true
  Write-Host "ADMIN // managed qq task upgraded to Highest privilege." -ForegroundColor Cyan
}

if (-not $installedNow -and -not $changedPrincipal -and -not $Elevated) {
  Write-Host "READY // qq is already the supervised interactive ADMIN console." -ForegroundColor Green
  exit 0
}

Write-Host "SERVICE // health service owns qq lifecycle and will relaunch the visible console when the runner is absent." -ForegroundColor Cyan

$helper = Join-Path $HomeDir "restart-supervised-admin-console.ps1"
$helperContent = @'
param(
  [int]$RunnerPid,
  [string]$TaskName
)

Start-Sleep -Seconds 5

if ($RunnerPid -gt 0) {
  try { Stop-Process -Id $RunnerPid -Force -ErrorAction Stop } catch {}
}

Start-Sleep -Seconds 1

try {
  Start-ScheduledTask -TaskName $TaskName
} catch {
  schtasks.exe /Run /TN $TaskName | Out-Null
}
'@

[IO.File]::WriteAllText($helper,$helperContent,(New-Object Text.UTF8Encoding($false)))

$helperArgs = '-NoProfile -ExecutionPolicy Bypass -File "' + $helper + '" -RunnerPid ' + $RunnerPid + ' -TaskName "' + $TaskName + '"'
Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList $helperArgs -WindowStyle Hidden

Write-Host "READY // qq will reopen as an interactive ADMIN console after this task result returns." -ForegroundColor Green

