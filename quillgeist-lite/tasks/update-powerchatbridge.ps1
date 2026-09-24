$ErrorActionPreference = "Stop"

$ModuleRoot = Join-Path ([Environment]::GetFolderPath("MyDocuments")) "PowerShell\Modules\PowerChatBridge\0.1.0"
$Repo = "clintkosh/PowerChatBridge"
$TempRoot = Join-Path $env:TEMP ("PowerChatBridge-update-" + [Guid]::NewGuid().ToString("n"))
$BridgePattern = "(?i)PowerChatBridge.*server[\\/]BridgeServer\.ps1"

function Get-BridgeWorkspaceFromCommandLine {
  param([string]$CommandLine)
  if (-not $CommandLine) { return $null }

  $match = [regex]::Match($CommandLine,'(?i)(?:^|\s)-Workspace\s+(?:"([^"]+)"|''([^'']+)''|(\S+))')
  if (-not $match.Success) { return $null }

  foreach ($index in 1..3) {
    if ($match.Groups[$index].Success -and $match.Groups[$index].Value) {
      return [Environment]::ExpandEnvironmentVariables($match.Groups[$index].Value)
    }
  }
  return $null
}

if (-not (Test-Path $ModuleRoot)) {
  Write-Host "POWERCHATBRIDGE_NOT_INSTALLED // no managed module copy found at $ModuleRoot" -ForegroundColor DarkYellow
  exit 0
}

if (-not (Get-Command gh.exe -ErrorAction SilentlyContinue)) {
  throw "GitHub CLI is required to update the private PowerChatBridge module."
}

$login = (& gh api user --jq .login 2>$null | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $login.ToLowerInvariant() -ne "codeFEDDY") {
  throw "PowerChatBridge updater requires the existing clintkosh GitHub CLI identity."
}

$active = @()
try {
  $active = @(
    Get-CimInstance Win32_Process |
      Where-Object { [string]$_.CommandLine -match $BridgePattern } |
      ForEach-Object {
        $workspace = Get-BridgeWorkspaceFromCommandLine ([string]$_.CommandLine)
        if ($workspace) {
          [pscustomobject]@{
            Pid = [int]$_.ProcessId
            Workspace = [System.IO.Path]::GetFullPath($workspace)
          }
        }
      }
  )
} catch {
  Write-Host ("WARN // could not enumerate active PowerChatBridge processes: " + $_.Exception.Message) -ForegroundColor DarkYellow
}

Write-Host ("POWERCHATBRIDGE // refreshing private module; active bridges detected: " + $active.Count) -ForegroundColor Cyan

try {
  & gh repo clone $Repo $TempRoot -- --depth 1
  if ($LASTEXITCODE -ne 0 -or -not (Test-Path $TempRoot)) {
    throw "Could not clone the private PowerChatBridge repository."
  }

  $bridgeSource = Join-Path $TempRoot "server\BridgeServer.ps1"
  $streamSource = Join-Path $TempRoot "server\ClintwareStream.ps1"
  foreach ($file in @($bridgeSource,$streamSource)) {
    if (-not (Test-Path $file)) { throw "PowerChatBridge source missing: $file" }
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $file),[ref]$tokens,[ref]$errors) | Out-Null
    if ($errors.Count -gt 0) {
      throw "PowerChatBridge source failed PowerShell parse validation: $file"
    }
  }

  foreach ($row in $active) {
    try {
      Stop-Process -Id $row.Pid -Force -ErrorAction Stop
      Write-Host ("STOPPED // PowerChatBridge PID " + $row.Pid) -ForegroundColor DarkCyan
    } catch {
      Write-Host ("WARN // bridge PID " + $row.Pid + " could not be stopped: " + $_.Exception.Message) -ForegroundColor DarkYellow
    }
  }

  $items = @(
    "PowerChatBridge.psd1",
    "Start-PowerChatBridge.ps1",
    "Uninstall-PowerChatBridge.ps1",
    "Publish-PrivateRepo.ps1",
    "README.md",
    "LICENSE",
    "SECURITY.md",
    "src",
    "server",
    "browser-extension",
    "prompts",
    "docs"
  )

  foreach ($item in $items) {
    $source = Join-Path $TempRoot $item
    if (-not (Test-Path $source)) { throw "PowerChatBridge package item missing: $item" }
    Copy-Item -LiteralPath $source -Destination $ModuleRoot -Recurse -Force
  }

  $manifest = Join-Path $ModuleRoot "PowerChatBridge.psd1"
  Import-Module $manifest -Force

  $restarted = 0
  foreach ($workspace in @($active.Workspace | Sort-Object -Unique)) {
    try {
      $health = Start-PCBServer -Workspace $workspace -Restart
      if ($health -and $health.ok) {
        $restarted++
        Write-Host ("READY // PowerChatBridge restarted for " + $workspace) -ForegroundColor Green
      } else {
        Write-Host ("WARN // PowerChatBridge restart did not return healthy state for " + $workspace) -ForegroundColor DarkYellow
      }
    } catch {
      Write-Host ("WARN // could not restart PowerChatBridge for " + $workspace + ": " + $_.Exception.Message) -ForegroundColor DarkYellow
    }
  }

  Write-Host ("POWERCHATBRIDGE_UPDATED // module refreshed; bridges restarted: " + $restarted + "/" + @($active.Workspace | Sort-Object -Unique).Count) -ForegroundColor Green
}
finally {
  Remove-Item $TempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

