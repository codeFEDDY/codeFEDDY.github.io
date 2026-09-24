$ErrorActionPreference = "Stop"

$TaskName = "CodeFEDDY qq Runner"
$HomeDir = Join-Path $env:LOCALAPPDATA "Clintware\QuillgeistLite"
$RunnerPidPath = Join-Path $HomeDir "runner.pid"
$LauncherPath = Join-Path $HomeDir "launcher.ps1"

if (-not (Test-Path $LauncherPath)) {
  throw "qq launcher is missing: $LauncherPath"
}

$runnerPid = 0
try {
  if (Test-Path $RunnerPidPath) {
    $raw = (Get-Content $RunnerPidPath -Raw).Trim()
    [void][int]::TryParse($raw,[ref]$runnerPid)
  }
} catch {}

$helper = Join-Path $HomeDir "restart-window.ps1"
$helperContent = @'
param(
  [int]$RunnerPid,
  [string]$TaskName
)

Start-Sleep -Seconds 3

if ($RunnerPid -gt 0) {
  try { Stop-Process -Id $RunnerPid -Force -ErrorAction Stop } catch {}
}

Start-Sleep -Seconds 1

try {
  Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
} catch {}

Start-Sleep -Milliseconds 500

try {
  Start-ScheduledTask -TaskName $TaskName
} catch {
  schtasks.exe /Run /TN $TaskName | Out-Null
}
'@

[IO.File]::WriteAllText($helper,$helperContent,(New-Object Text.UTF8Encoding($false)))

$pwsh = Get-Command pwsh.exe -ErrorAction SilentlyContinue
$hostExe = if ($pwsh) { $pwsh.Source } else { "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" }
$args = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "' + $helper + '" -RunnerPid ' + $runnerPid + ' -TaskName "' + $TaskName + '"'
Start-Process -FilePath $hostExe -ArgumentList $args -WindowStyle Hidden

Write-Host "READY // qq window restart queued; launcher splash will run on reopen." -ForegroundColor Green

