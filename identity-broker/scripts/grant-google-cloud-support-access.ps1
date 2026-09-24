param(
  [string]$OwnerAccount = "clint.kosh@gmail.com",
  [string]$SupportAccount = "support@codefeddy.com",
  [string]$ProjectName = "Clintware"
)

$ErrorActionPreference = "Stop"
if ($PSVersionTable.PSVersion.Major -ge 7) {
  $PSNativeCommandUseErrorActionPreference = $true
}

function Stop-IfFailed {
  param([string]$Message)
  if ($LASTEXITCODE -ne 0) { throw $Message }
}

function Require-Command {
  param([string]$Name)
  if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
    throw "$Name is required but was not found."
  }
}

Require-Command gcloud

Write-Host ""
Write-Host "=== CLINTWARE GOOGLE ACCESS REPAIR ===" -ForegroundColor Cyan
Write-Host "Expected owner : $OwnerAccount"
Write-Host "Support account: $SupportAccount"
Write-Host ""

$KnownAccounts = @(& gcloud auth list --format="value(account)")
Stop-IfFailed "Could not read gcloud authentication state."

Write-Host "Accounts currently known to gcloud:" -ForegroundColor DarkGray
if ($KnownAccounts.Count -eq 0) {
  Write-Host "  (none)" -ForegroundColor DarkGray
} else {
  $KnownAccounts | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
}

if ($KnownAccounts -notcontains $OwnerAccount) {
  Write-Host ""
  Write-Host "Authenticate the EXISTING Clintware owner account." -ForegroundColor Yellow
  Write-Host "When the browser opens, choose EXACTLY: $OwnerAccount" -ForegroundColor Yellow
  Write-Host "Do NOT choose $SupportAccount." -ForegroundColor Yellow
  Write-Host ""
  & gcloud auth login $OwnerAccount
  Stop-IfFailed "Google authentication did not complete as $OwnerAccount. Rerun the same one-liner and choose the exact owner account."
}

& gcloud config set account $OwnerAccount | Out-Null
Stop-IfFailed "Could not select $OwnerAccount in gcloud."

$ActiveAccount = (& gcloud auth list --filter="status:ACTIVE" --format="value(account)").Trim()
Stop-IfFailed "Could not determine the active Google account."

if ($ActiveAccount -ne $OwnerAccount) {
  throw "STOPPED: active account is '$ActiveAccount', expected '$OwnerAccount'."
}

Write-Host ""
Write-Host "OWNER AUTHENTICATED: $ActiveAccount" -ForegroundColor Green

$ProjectRows = @(& gcloud projects list --format="csv[no-heading](projectId,name)")
Stop-IfFailed "Could not list projects visible to $OwnerAccount."

Write-Host ""
Write-Host "Projects visible to $OwnerAccount :" -ForegroundColor Cyan
if ($ProjectRows.Count -eq 0) {
  Write-Host "  (none)" -ForegroundColor Yellow
} else {
  $ProjectRows | ForEach-Object { Write-Host "  $_" }
}

$Found = @()
foreach ($Row in $ProjectRows) {
  if (-not $Row) { continue }
  $Parts = $Row -split ",", 2
  if ($Parts.Count -lt 2) { continue }
  $Id = $Parts[0].Trim()
  $Name = $Parts[1].Trim()
  if ($Name -ieq $ProjectName -or $Id -match "(?i)clintware") {
    $Found += [PSCustomObject]@{ ProjectId = $Id; Name = $Name }
  }
}

if ($Found.Count -eq 0) {
  throw "STOPPED: no existing Clintware project is visible to $OwnerAccount. Do NOT create another project. The project list printed above is the diagnostic state."
}

if ($Found.Count -gt 1) {
  Write-Host ""
  Write-Host "More than one possible Clintware project was found:" -ForegroundColor Yellow
  $Found | Format-Table -AutoSize
  throw "STOPPED to avoid touching the wrong Google Cloud project."
}

$ProjectId = $Found[0].ProjectId
$ResolvedName = $Found[0].Name

Write-Host ""
Write-Host "CLINTWARE PROJECT FOUND" -ForegroundColor Green
Write-Host "  Name: $ResolvedName"
Write-Host "  ID:   $ProjectId"

& gcloud config set project $ProjectId | Out-Null
Stop-IfFailed "Could not select Google Cloud project $ProjectId."

Write-Host ""
Write-Host "Granting $SupportAccount access..." -ForegroundColor Cyan

$IamArgs = @(
  "projects","add-iam-policy-binding",$ProjectId,
  "--member=user:$SupportAccount",
  "--role=roles/editor",
  "--condition=None",
  "--quiet"
)
& gcloud @IamArgs
Stop-IfFailed "Failed to grant $SupportAccount Editor access to $ProjectId."

$PolicyArgs = @(
  "projects","get-iam-policy",$ProjectId,
  "--flatten=bindings[].members",
  "--filter=bindings.members:user:$SupportAccount",
  "--format=value(bindings.role,bindings.members)"
)
$Policy = & gcloud @PolicyArgs
Stop-IfFailed "Could not verify the IAM policy."

if (-not ($Policy -match [regex]::Escape($SupportAccount))) {
  throw "STOPPED: Google did not confirm $SupportAccount in the IAM policy."
}

Write-Host ""
Write-Host "IAM VERIFIED" -ForegroundColor Green
Write-Host "  $SupportAccount"
Write-Host "  roles/editor"

$Url = "https://console.cloud.google.com/auth/overview?project=$ProjectId"
Start-Process $Url

Write-Host ""
Write-Host "==================================================" -ForegroundColor Green
Write-Host " SUCCESS" -ForegroundColor Green
Write-Host "==================================================" -ForegroundColor Green
Write-Host "Owner   : $OwnerAccount"
Write-Host "Project : $ResolvedName ($ProjectId)"
Write-Host "Support : $SupportAccount"
Write-Host "Access  : Editor VERIFIED"
Write-Host ""
Write-Host "Browser opened to the EXISTING Clintware project." -ForegroundColor Cyan
Write-Host "Switch only the browser account to $SupportAccount." -ForegroundColor Yellow
Write-Host "Do not create a new project." -ForegroundColor Yellow

