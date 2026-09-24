param(
  [string]$Repo = "codeFEDDY/codeFEDDY.github.io"
)

$ErrorActionPreference = "Stop"
if ($PSVersionTable.PSVersion.Major -ge 7) {
  $PSNativeCommandUseErrorActionPreference = $true
}

function Require-Command {
  param([string]$Name)
  if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
    throw "$Name is required but was not found."
  }
}

function Secure-To-Plain {
  param([Security.SecureString]$Value)
  $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Value)
  try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
  finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
}

function Set-GitHubSecret {
  param([string]$Name,[string]$Value)
  if ([string]::IsNullOrWhiteSpace($Value)) { throw "$Name is empty." }
  $Value | gh secret set $Name --repo $Repo --body -
  if ($LASTEXITCODE -ne 0) { throw "Could not save GitHub secret $Name." }
}

function Get-LatestWorkflowRunId {
  param([string]$Workflow)
  $json = gh run list --repo $Repo --workflow $Workflow --limit 1 --json databaseId 2>$null
  if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($json)) {
    throw "Could not list workflow runs for $Workflow."
  }
  $rows = $json | ConvertFrom-Json
  if (-not $rows -or -not $rows[0].databaseId) {
    throw "Could not resolve the latest workflow run ID for $Workflow."
  }
  return [string]$rows[0].databaseId
}

Require-Command gh

gh auth status 2>$null
if ($LASTEXITCODE -ne 0) {
  gh auth login --hostname github.com --git-protocol https --web
  if ($LASTEXITCODE -ne 0) { throw "GitHub authentication failed." }
}

Write-Host ""
Write-Host "=== ACTIVATE CLINTWARE GOOGLE SIGN-IN ===" -ForegroundColor Cyan
Write-Host "Identity scopes only: openid + email + profile." -ForegroundColor Green
Write-Host "No Gmail/Calendar scopes, offline access, or Google refresh token are requested." -ForegroundColor Yellow
Write-Host ""
Write-Host "Use the Google Web application OAuth client from the EXISTING Clintware Google Cloud project." -ForegroundColor White
Write-Host "Authorized redirect URI must be exactly:" -ForegroundColor White
Write-Host "  https://auth.codefeddy.com/callback" -ForegroundColor Cyan
Write-Host ""

$ClientId = (Read-Host "Google OAuth Client ID").Trim()
$ClientSecretSecure = Read-Host "Google OAuth Client Secret" -AsSecureString
$ClientSecret = Secure-To-Plain $ClientSecretSecure

if ([string]::IsNullOrWhiteSpace($ClientId) -or [string]::IsNullOrWhiteSpace($ClientSecret)) {
  throw "OAuth client ID and secret are required."
}

if ($ClientId -notmatch '^[0-9]+-[A-Za-z0-9_-]+\.apps\.googleusercontent\.com$') {
  throw "Invalid Google OAuth Client ID format. It must be the Google-issued Web client ID ending in .apps.googleusercontent.com."
}

Write-Host ""
Write-Host "Checking whether Google recognizes the client ID..." -ForegroundColor Cyan
$ProbeUrl = "https://accounts.google.com/o/oauth2/v2/auth?client_id=$([uri]::EscapeDataString($ClientId))&redirect_uri=$([uri]::EscapeDataString('https://auth.codefeddy.com/callback'))&response_type=code&scope=openid%20email%20profile&state=clintware-preflight&nonce=clintware-preflight"

$ProbeFile = Join-Path $env:TEMP "clintware-google-oauth-probe.html"
try {
  & curl.exe -L -sS --max-time 20 $ProbeUrl -o $ProbeFile
  if ($LASTEXITCODE -eq 0 -and (Test-Path $ProbeFile)) {
    $ProbeBody = Get-Content $ProbeFile -Raw
    if ($ProbeBody -match 'OAuth client was not found|Error 401:\s*invalid_client|invalid_client') {
      throw "Google reports this OAuth client is not found. Create/select the Web application client in Google Auth Platform > Clients for the EXISTING Clintware project."
    }
  }
} finally {
  Remove-Item $ProbeFile -Force -ErrorAction SilentlyContinue
}

Write-Host "Google client preflight did not report invalid_client." -ForegroundColor Green
Write-Host ""
Write-Host "Saving credentials as encrypted GitHub Actions secrets..." -ForegroundColor Cyan

Set-GitHubSecret "GOOGLE_OAUTH_CLIENT_ID" $ClientId
Set-GitHubSecret "GOOGLE_OAUTH_CLIENT_SECRET" $ClientSecret

$ClientSecret = $null
$ClientSecretSecure = $null

Write-Host "Starting CodeFEDDY Identity Broker deployment..." -ForegroundColor Cyan
gh workflow run deploy-identity-broker.yml --repo $Repo --ref main
if ($LASTEXITCODE -ne 0) { throw "Could not start CodeFEDDY Identity Broker deployment." }

Start-Sleep -Seconds 4
$RunId = Get-LatestWorkflowRunId "deploy-identity-broker.yml"

Write-Host "Watching workflow run $RunId..." -ForegroundColor Cyan
gh run watch --repo $Repo $RunId --exit-status
if ($LASTEXITCODE -ne 0) { throw "CodeFEDDY Identity Broker deployment failed." }

Write-Host ""
Write-Host "Checking auth.codefeddy.com..." -ForegroundColor Cyan
$Health = Invoke-RestMethod "https://auth.codefeddy.com/health"
$Health | ConvertTo-Json -Depth 6

if (-not $Health.ok -or -not $Health.configured -or -not $Health.google_configured) {
  throw "CodeFEDDY Identity Broker deployed but Google sign-in is not reporting configured."
}

$Mail = Invoke-RestMethod "https://auth.codefeddy.com/client-config/mail"
$N7 = Invoke-RestMethod "https://auth.codefeddy.com/client-config/neuron7-case"
$Admin = Invoke-RestMethod "https://auth.codefeddy.com/client-config/control-plane-admin"

if ($Mail.client_id -ne $N7.client_id -or $Mail.client_id -ne $Admin.client_id) {
  throw "First-party products are not using one central Clintware OAuth client."
}

if ($Mail.client_id -ne "https://auth.codefeddy.com/client/clintware-web") {
  throw "Unexpected Clintware first-party client ID: $($Mail.client_id)"
}

Write-Host ""
Write-Host "==========================================" -ForegroundColor Green
Write-Host " CLINTWARE GOOGLE SIGN-IN IS ACTIVE" -ForegroundColor Green
Write-Host "==========================================" -ForegroundColor Green
Write-Host "Authority : https://auth.codefeddy.com"
Write-Host "N7 login  : https://n7.codefeddy.com/operator"
Write-Host "MCP admin : https://mcp.codefeddy.com/admin"
Write-Host ""
Write-Host "The Google upstream client is separate from Clintware's internal first-party client ID." -ForegroundColor Yellow
Write-Host "Gmail/Calendar delegated access remains separate." -ForegroundColor Yellow

