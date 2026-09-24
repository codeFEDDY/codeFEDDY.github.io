param(
  [Parameter(Mandatory=$true)]
  [string]$HomeDir
)

$ErrorActionPreference = "Stop"

$BaseUrl = "https://raw.githubusercontent.com/codeFEDDY/codeFEDDY.github.io/main/quillgeist-lite"
$LogPath = Join-Path $HomeDir "auto-repair.log"
$TaskName = "CodeFEDDY qq Runner"

New-Item -ItemType Directory -Force -Path $HomeDir | Out-Null

function Write-RepairLog {
  param([string]$Message)
  $line = ((Get-Date).ToUniversalTime().ToString("o") + " " + $Message)
  Add-Content -Path $LogPath -Value $line
  Write-Host $Message
}

function Resolve-Pwsh {
  $cmd = Get-Command pwsh.exe -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  $candidate = Join-Path $env:ProgramFiles "PowerShell\7\pwsh.exe"
  if (Test-Path $candidate) { return $candidate }
  return $null
}

Write-RepairLog "AUTO_REPAIR // refreshing canonical qq runtime"

$specs = @(
  @{ Remote = "runner.ps1"; Local = "runner.ps1"; Kind = "powershell"; Required = "Show-QuillgeistSplash" },
  @{ Remote = "launcher.ps1"; Local = "launcher.ps1"; Kind = "powershell"; Required = "Set-ClintwareBaseTheme" },
  @{ Remote = "tools/boot_splash.py"; Local = "boot_splash.py"; Kind = "text"; Required = "retro DOS boot splash" },
  @{ Remote = "tasks/ensure-powershell.ps1"; Local = "ensure-powershell.ps1"; Kind = "powershell"; Required = "PWSH_READY" }
)

foreach ($spec in $specs) {
  $target = Join-Path $HomeDir $spec.Local
  $temp = $target + ".new"
  Invoke-WebRequest -Uri ($BaseUrl + "/" + $spec.Remote + "?v=" + [DateTime]::UtcNow.Ticks) -OutFile $temp -UseBasicParsing -Headers @{"Cache-Control"="no-cache"}

  if (-not (Test-Path $temp)) { throw "Auto-repair download failed: $($spec.Remote)" }
  $raw = Get-Content $temp -Raw
  if ($raw -notlike ("*" + $spec.Required + "*")) { throw "Auto-repair structural validation failed: $($spec.Remote)" }

  if ($spec.Kind -eq "powershell") {
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $temp),[ref]$tokens,[ref]$errors) | Out-Null
    if ($errors.Count -gt 0) {
      Remove-Item $temp -Force -ErrorAction SilentlyContinue
      throw "Auto-repair PowerShell parse validation failed: $($spec.Remote)"
    }
  }

  Move-Item $temp $target -Force
  Write-RepairLog ("AUTO_REPAIR // refreshed " + $spec.Local)
}

$launcher = Join-Path $HomeDir "launcher.ps1"
$pwsh = Resolve-Pwsh
$hostExe = if ($pwsh) { $pwsh } else { "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" }
$taskArgs = '-NoProfile -ExecutionPolicy Bypass -NoExit -File "' + $launcher + '"'

try {
  $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
  $action = New-ScheduledTaskAction -Execute $hostExe -Argument $taskArgs -WorkingDirectory $HomeDir
  Set-ScheduledTask -TaskName $TaskName -Action $action | Out-Null
  Enable-ScheduledTask -TaskName $TaskName | Out-Null
  Write-RepairLog ("AUTO_REPAIR // task host set to " + $hostExe)
  Write-RepairLog "AUTO_REPAIR // runner task enabled"
} catch {
  Write-RepairLog ("AUTO_REPAIR WARN // task rewrite failed: " + $_.Exception.Message)
}

try {
  $serviceName = "CodeFEDDYQQHealth"
  $svc = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
  if ($svc -and $svc.Status -ne "Running") {
    Start-Service -Name $serviceName -ErrorAction SilentlyContinue
    Write-RepairLog "SERVICE // restored health watchdog"
  }
} catch {
  Write-RepairLog ("AUTO_REPAIR WARN // health service restart failed: " + $_.Exception.Message)
}

try { Enable-ScheduledTask -TaskName $TaskName -ErrorAction Stop | Out-Null } catch {
  Write-RepairLog ("AUTO_REPAIR WARN // could not enable runner task: " + $_.Exception.Message)
}
try { Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue } catch {}
Start-Sleep -Milliseconds 700
Enable-ScheduledTask -TaskName $TaskName -ErrorAction Stop | Out-Null
Start-ScheduledTask -TaskName $TaskName -ErrorAction Stop
Write-RepairLog "AUTO_REPAIR_READY // qq restart requested"

