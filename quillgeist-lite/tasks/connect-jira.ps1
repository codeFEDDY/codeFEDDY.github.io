$ErrorActionPreference = "Stop"

$ControlPlane = "https://mcp.codefeddy.com"
$Repo = "codeFEDDY/codeFEDDY.github.io"
$DeployWorkflow = "deploy-control-plane.yml"

function Get-GitHubCli {
  $gh = Get-Command gh.exe -ErrorAction SilentlyContinue
  if (-not $gh) { $gh = Get-Command gh -ErrorAction SilentlyContinue }
  if (-not $gh) {
    throw "GitHub CLI (gh) is required because qq uses your existing Clintware GitHub identity for Jira setup."
  }
  return $gh
}

function Get-GitHubToken {
  param([object]$Gh)
  $token = (& $Gh.Source auth token 2>$null | Out-String).Trim()
  if (-not $token) { throw "GitHub CLI is not authenticated. Run: gh auth login" }
  return $token
}

function Get-ControlPlaneHealth {
  try {
    return Invoke-RestMethod -Method Get -Uri "$ControlPlane/health" -TimeoutSec 20
  } catch {
    return $null
  }
}

function Test-JiraConfigured {
  param([object]$Health)
  if (-not $Health) { return $false }
  if ($Health.jira -and $null -ne $Health.jira.configured) {
    return [bool]$Health.jira.configured
  }
  if ($Health.adapters -and $null -ne $Health.adapters.jira_oauth_configured) {
    return [bool]$Health.adapters.jira_oauth_configured
  }
  return $false
}

function Get-RepositorySecretNames {
  param([object]$Gh)
  $raw = (& $Gh.Source secret list --repo $Repo --app actions --json name 2>$null | Out-String).Trim()
  if ($LASTEXITCODE -ne 0) {
    throw "qq could not list repository Actions secret names. Confirm your GitHub login can administer secrets for $Repo."
  }
  if (-not $raw) { return @() }
  $rows = $raw | ConvertFrom-Json
  return @($rows | ForEach-Object { [string]$_.name })
}

function Set-RepositorySecretText {
  param(
    [object]$Gh,
    [string]$Name,
    [string]$Value
  )
  if (-not $Value) { throw "$Name cannot be empty." }
  $Value | & $Gh.Source secret set $Name --repo $Repo --app actions
  if ($LASTEXITCODE -ne 0) { throw "Failed to store GitHub Actions secret $Name." }
}

function Set-RepositorySecretSecure {
  param(
    [object]$Gh,
    [string]$Name,
    [Security.SecureString]$Value
  )
  if (-not $Value) { throw "$Name cannot be empty." }
  $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Value)
  try {
    $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
    if (-not $plain) { throw "$Name cannot be empty." }
    $plain | & $Gh.Source secret set $Name --repo $Repo --app actions
    if ($LASTEXITCODE -ne 0) { throw "Failed to store GitHub Actions secret $Name." }
  } finally {
    if ($ptr -ne [IntPtr]::Zero) {
      [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
    }
    $plain = $null
  }
}

function New-JiraEncryptionKey {
  $bytes = New-Object byte[] 48
  $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
  try {
    $rng.GetBytes($bytes)
  } finally {
    $rng.Dispose()
  }
  return [Convert]::ToBase64String($bytes)
}

function Start-ControlPlaneDeploy {
  param([object]$Gh)
  Write-Host ""
  Write-Host "Deploying Jira credentials into the CodeFEDDY Control Plane..." -ForegroundColor Cyan
  & $Gh.Source workflow run $DeployWorkflow --repo $Repo
  if ($LASTEXITCODE -ne 0) {
    throw "Could not start the CodeFEDDY Control Plane deployment workflow."
  }
}

function Wait-JiraConfigured {
  param(
    [object]$Gh,
    [int]$Seconds = 360
  )

  $deadline = (Get-Date).AddSeconds($Seconds)
  do {
    Start-Sleep -Seconds 5
    $health = Get-ControlPlaneHealth
    if (Test-JiraConfigured $health) {
      Write-Host "JIRA PROVIDER CONFIGURED" -ForegroundColor Green
      return $health
    }
  } while ((Get-Date) -lt $deadline)

  $latest = ""
  try {
    $latest = (& $Gh.Source run list --repo $Repo --workflow $DeployWorkflow --limit 1 --json url,status,conclusion --jq '.[0] | "\(.status) \(.conclusion // "") \(.url)"' 2>$null | Out-String).Trim()
  } catch {}

  if ($latest) {
    throw "Jira credentials did not become active before timeout. Latest deployment: $latest"
  }
  throw "Jira credentials did not become active before timeout. Check the Deploy CodeFEDDY Control Plane workflow."
}

function Ensure-JiraProviderConfiguration {
  param([object]$Gh)

  $health = Get-ControlPlaneHealth
  if (Test-JiraConfigured $health) {
    Write-Host "Jira provider configuration is already active in the Control Plane." -ForegroundColor Green
    return $health
  }

  Write-Host ""
  Write-Host "Jira provider credentials are not active yet." -ForegroundColor Yellow
  Write-Host "qq will store them directly as GitHub Actions secrets. They are not sent through ChatGPT or written to disk." -ForegroundColor DarkGray

  $names = Get-RepositorySecretNames $Gh
  $changed = $false

  if ($names -notcontains "ATLASSIAN_CLIENT_ID") {
    Write-Host ""
    $clientId = (Read-Host "Atlassian OAuth Client ID").Trim()
    if (-not $clientId) { throw "Atlassian OAuth Client ID is required." }
    Set-RepositorySecretText $Gh "ATLASSIAN_CLIENT_ID" $clientId
    $clientId = $null
    $changed = $true
  } else {
    Write-Host "ATLASSIAN_CLIENT_ID already exists in GitHub Actions secrets." -ForegroundColor DarkGray
  }

  if ($names -notcontains "ATLASSIAN_CLIENT_SECRET") {
    Write-Host ""
    $clientSecret = Read-Host "Atlassian OAuth Client Secret" -AsSecureString
    Set-RepositorySecretSecure $Gh "ATLASSIAN_CLIENT_SECRET" $clientSecret
    $clientSecret = $null
    $changed = $true
  } else {
    Write-Host "ATLASSIAN_CLIENT_SECRET already exists in GitHub Actions secrets." -ForegroundColor DarkGray
  }

  if ($names -notcontains "JIRA_TOKEN_ENCRYPTION_KEY") {
    $key = New-JiraEncryptionKey
    try {
      Set-RepositorySecretText $Gh "JIRA_TOKEN_ENCRYPTION_KEY" $key
    } finally {
      $key = $null
    }
    Write-Host "Generated and stored a dedicated Jira grant-encryption key." -ForegroundColor DarkGray
    $changed = $true
  } else {
    Write-Host "JIRA_TOKEN_ENCRYPTION_KEY already exists in GitHub Actions secrets." -ForegroundColor DarkGray
  }

  if ($changed) {
    Write-Host "Required Jira secret names are now present." -ForegroundColor Green
  } else {
    Write-Host "Required Jira secret names already exist; the Control Plane only needs a sync deployment." -ForegroundColor Yellow
  }

  Start-ControlPlaneDeploy $Gh
  return Wait-JiraConfigured $Gh
}

$gh = Get-GitHubCli
$token = Get-GitHubToken $gh

$null = Ensure-JiraProviderConfiguration $gh

$headers = @{ Authorization = "Bearer $token" }

Write-Host ""
Write-Host "Requesting a scoped Jira authorization link from the CodeFEDDY Control Plane..." -ForegroundColor Cyan
$start = Invoke-RestMethod -Method Post -Uri "$ControlPlane/api/v1/jira/oauth/start" -Headers $headers -ContentType "application/json" -Body "{}"

if (-not $start.ok -or -not $start.authorize_url) {
  throw "The Control Plane could not start Jira authorization. Check /health and the Atlassian OAuth application configuration."
}

Write-Host ""
Write-Host "Opening Atlassian authorization in your default browser." -ForegroundColor White
Write-Host "Approve the Jira site you want Clintware to use." -ForegroundColor Cyan
Write-Host "qq never receives the Jira access token, refresh token, or client secret." -ForegroundColor DarkGray
Start-Process $start.authorize_url

$deadline = (Get-Date).AddMinutes(5)
do {
  Start-Sleep -Seconds 2
  try {
    $status = Invoke-RestMethod -Method Get -Uri "$ControlPlane/api/v1/jira/status" -Headers $headers
    if ($status.connected) {
      Write-Host ""
      Write-Host "JIRA CONNECTED" -ForegroundColor Green
      if ($status.sites) {
        foreach ($site in $status.sites) {
          Write-Host ("  {0}  [{1}]" -f $site.name, $site.id) -ForegroundColor Cyan
          Write-Host ("  {0}" -f $site.url) -ForegroundColor DarkGray
        }
      }
      Write-Host ""
      Write-Host "Clintware MCP Jira read/write capabilities are ready." -ForegroundColor Green
      exit 0
    }
  } catch {
    # The browser authorization or callback may still be in progress.
  }
} while ((Get-Date) -lt $deadline)

throw "Jira was not connected within five minutes. Run qq connect-jira again after confirming the Atlassian app callback URL and Jira API scopes."

