param(
  [string]$Repo = "codeFEDDY/codeFEDDY.github.io"
)

$ErrorActionPreference = "Stop"
if ($PSVersionTable.PSVersion.Major -ge 7) {
  $PSNativeCommandUseErrorActionPreference = $true
}

$SetupUrl  = "https://raw.githubusercontent.com/codeFEDDY/codeFEDDY.github.io/main/newsletter/scripts/setup-gmail-oauth.ps1"
$SetupPath = Join-Path $env:TEMP "clintware-google-oauth.ps1"

Write-Host ""
Write-Host "=== FINISH CLINTWARE GOOGLE OAUTH ===" -ForegroundColor Cyan
Write-Host "Clintware only. CodeFEDDY is not touched." -ForegroundColor Yellow
Write-Host ""

Invoke-WebRequest -Uri $SetupUrl -OutFile $SetupPath -UseBasicParsing
if (-not (Test-Path $SetupPath)) { throw "Could not download the Clintware OAuth helper." }

$Scopes = @(
  "https://www.googleapis.com/auth/gmail.send",
  "https://www.googleapis.com/auth/calendar.freebusy",
  "https://www.googleapis.com/auth/calendar.events"
)

$Args = @("-NoProfile","-ExecutionPolicy","Bypass","-File",$SetupPath,"-Repo",$Repo,"-Scopes") + $Scopes
& powershell.exe @Args
if ($LASTEXITCODE -ne 0) { throw "Clintware Google OAuth bootstrap failed." }

Write-Host ""
Write-Host "Checking saved GitHub secrets..." -ForegroundColor Cyan
gh secret list --repo $Repo | Select-String "GOOGLE_OAUTH_CLIENT_ID|GOOGLE_OAUTH_CLIENT_SECRET|GOOGLE_DELEGATED_REFRESH_TOKEN"

Write-Host ""
Write-Host "Checking Clintware Mail..." -ForegroundColor Cyan
try {
  $Mail = Invoke-RestMethod "https://mail.codefeddy.com/health"
  $Mail | ConvertTo-Json -Depth 6
} catch {
  Write-Host ("Could not read mail.codefeddy.com health yet: " + $_.Exception.Message) -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Checking ClintCal..." -ForegroundColor Cyan
try {
  $Meet = Invoke-RestMethod "https://meet.codefeddy.com/health"
  $Meet | ConvertTo-Json -Depth 6
} catch {
  Write-Host ("Could not read meet.codefeddy.com health yet: " + $_.Exception.Message) -ForegroundColor Yellow
}

Write-Host ""
Write-Host "==========================================" -ForegroundColor Green
Write-Host " CLINTWARE GOOGLE OAUTH FINISH COMPLETE" -ForegroundColor Green
Write-Host "==========================================" -ForegroundColor Green

