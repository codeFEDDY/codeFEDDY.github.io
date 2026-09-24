param(
  [string]$Repo = "codeFEDDY/codeFEDDY.github.io"
)

$ErrorActionPreference = "Stop"
if ($PSVersionTable.PSVersion.Major -ge 7) {
  $PSNativeCommandUseErrorActionPreference = $true
}

$ExpectedGoogleClientId = "378690450945-nnb0d9st2d9s5lj2alt7q1hdm3pfige7.apps.googleusercontent.com"

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
  throw "GitHub CLI (gh) is required."
}

gh auth status 2>$null
if ($LASTEXITCODE -ne 0) {
  gh auth login --hostname github.com --git-protocol https --web
  if ($LASTEXITCODE -ne 0) { throw "GitHub authentication failed." }
}

Write-Host ""
Write-Host "=== CLINTWARE GOOGLE SIGN-IN: NO CLIENT SECRET ===" -ForegroundColor Cyan
Write-Host "Google client: $ExpectedGoogleClientId" -ForegroundColor Green
Write-Host "Mode: signed OIDC ID token + form_post" -ForegroundColor Green
Write-Host "Google OAuth client secret: NOT REQUIRED" -ForegroundColor Yellow
Write-Host ""

Write-Host "Starting Identity Broker deployment..." -ForegroundColor Cyan
gh workflow run deploy-identity-broker.yml --repo $Repo --ref main
if ($LASTEXITCODE -ne 0) { throw "Could not start deployment." }

Start-Sleep -Seconds 5
$RunsJson = gh run list --repo $Repo --workflow deploy-identity-broker.yml --limit 1 --json databaseId,status,conclusion,headSha
if ($LASTEXITCODE -ne 0) { throw "Could not list Identity Broker workflow runs." }

$Runs = $RunsJson | ConvertFrom-Json
if (-not $Runs -or -not $Runs[0].databaseId) { throw "Could not determine deployment run ID." }

$RunId = [string]$Runs[0].databaseId
Write-Host "Watching workflow run $RunId..." -ForegroundColor Cyan

gh run watch $RunId --repo $Repo --exit-status
if ($LASTEXITCODE -ne 0) { throw "Identity Broker deployment failed." }

Write-Host ""
Write-Host "Checking live identity broker..." -ForegroundColor Cyan
$Health = Invoke-RestMethod "https://auth.codefeddy.com/health"

if (-not $Health.ok) { throw "Identity Broker health check failed." }
if (-not $Health.configured) { throw "Identity Broker is not fully configured." }
if (-not $Health.google_configured) { throw "Google sign-in is not configured." }
if ($Health.google_secret_required -ne $false) { throw "Live broker still expects a Google client secret." }
if ($Health.google_mode -ne "oidc-id-token-form-post") { throw "Unexpected Google sign-in mode: $($Health.google_mode)" }
if ($Health.google_client_id -ne $ExpectedGoogleClientId) {
  throw "Unexpected live Google client ID: $($Health.google_client_id)"
}

Write-Host ""
Write-Host "============================================" -ForegroundColor Green
Write-Host " CLINTWARE GOOGLE SIGN-IN IS LIVE" -ForegroundColor Green
Write-Host "============================================" -ForegroundColor Green
Write-Host "Google Client ID : $($Health.google_client_id)"
Write-Host "Google secret    : NOT REQUIRED"
Write-Host "Identity mode    : $($Health.google_mode)"
Write-Host ""
Write-Host "Test N7:" -ForegroundColor Cyan
Write-Host "https://n7.codefeddy.com/operator"
Write-Host ""
Write-Host "MCP admin:" -ForegroundColor Cyan
Write-Host "https://mcp.codefeddy.com/admin"

