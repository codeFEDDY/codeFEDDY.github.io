$ErrorActionPreference = "Stop"

Write-Host "CODEFEDDY ACCESS CHECK"
Write-Host "----------------------"

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
  throw "GitHub CLI (gh) is not installed."
}

$accounts = @()
try {
  $auth = gh auth status --hostname github.com 2>&1 | Out-String
  foreach ($line in ($auth -split "`r?`n")) {
    if ($line -match '(?i)Logged in to github\.com account\s+([^\s]+)') {
      $accounts += $Matches[1]
    }
  }
} catch {}

$hasCodeFeddy = $false
try {
  $token = (gh auth token --hostname github.com --user codeFEDDY 2>$null).Trim()
  if ($token) { $hasCodeFeddy = $true }
} catch {}

if (-not $hasCodeFeddy) {
  Write-Host "GITHUB_CODEFEDDY=NOT_AUTHENTICATED"
  throw "The local GitHub CLI does not have a usable codeFEDDY account token."
}

$env:GH_TOKEN = $token
try {
  $perm = gh api repos/codeFEDDY/codeFEDDY.github.io --jq '.permissions.push' 2>$null
  if ($LASTEXITCODE -ne 0) { throw "GitHub repository permission probe failed." }
  $canPush = ([string]$perm).Trim().ToLowerInvariant() -eq "true"
  Write-Host ("GITHUB_CODEFEDDY_PUSH=" + $(if($canPush){"YES"}else{"NO"}))
  if (-not $canPush) { throw "codeFEDDY authentication exists but does not have push access to codeFEDDY/codeFEDDY.github.io." }
}
finally {
  Remove-Item Env:GH_TOKEN -ErrorAction SilentlyContinue
  $token = $null
}

$wrangler = Get-Command wrangler -ErrorAction SilentlyContinue
if (-not $wrangler) {
  $npx = Get-Command npx -ErrorAction SilentlyContinue
  if (-not $npx) {
    Write-Host "CLOUDFLARE_WRANGLER=UNAVAILABLE"
    exit 0
  }
  & $npx.Source wrangler whoami 2>&1 | ForEach-Object {
    $line = [string]$_
    if ($line -match '(?i)(token|key|secret)') { return }
    Write-Host $line
  }
  if ($LASTEXITCODE -eq 0) { Write-Host "CLOUDFLARE_WRANGLER=AUTHENTICATED" }
  else { Write-Host "CLOUDFLARE_WRANGLER=NOT_AUTHENTICATED" }
} else {
  & $wrangler.Source whoami 2>&1 | ForEach-Object {
    $line = [string]$_
    if ($line -match '(?i)(token|key|secret)') { return }
    Write-Host $line
  }
  if ($LASTEXITCODE -eq 0) { Write-Host "CLOUDFLARE_WRANGLER=AUTHENTICATED" }
  else { Write-Host "CLOUDFLARE_WRANGLER=NOT_AUTHENTICATED" }
}

Write-Host "ACCESS_CHECK_COMPLETE"
