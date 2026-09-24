[CmdletBinding()]
param(
    [string]$Repo = "codeFEDDY/codeFEDDY.github.io",
    [string]$WorkerName = "codefeddy-control-plane",
    [string]$ZoneName = "codefeddy.com",
    [string]$CloudflareTokenName = "Clintware MCP Control Plane",
    [string]$CloudflareAccountId = $env:CLOUDFLARE_ACCOUNT_ID,
    [switch]$SkipGitHubSecrets,
    [switch]$SkipWorkerSecrets
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$CfApi = "https://api.cloudflare.com/client/v4"

function Write-Step([string]$Message) {
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function ConvertFrom-Secure([Security.SecureString]$Secure) {
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
}

function Invoke-Cf {
    param(
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][string]$Method,
        [Parameter(Mandatory)][string]$Path,
        $Body = $null
    )
    $headers = @{ Authorization = "Bearer $Token"; Accept = "application/json" }
    $args = @{
        Uri = "$CfApi$Path"
        Method = $Method
        Headers = $headers
        ContentType = "application/json"
    }
    if ($null -ne $Body) { $args.Body = ($Body | ConvertTo-Json -Depth 20 -Compress) }
    $r = Invoke-RestMethod @args
    if (-not $r.success) {
        $msg = ($r.errors | ForEach-Object { $_.message }) -join "; "
        throw "Cloudflare API failed: $msg"
    }
    return $r.result
}

function Find-PermissionGroup {
    param(
        [Parameter(Mandatory)]$Groups,
        [Parameter(Mandatory)][string[]]$Names,
        [Parameter(Mandatory)][string]$Scope,
        [switch]$Optional
    )
    foreach ($name in $Names) {
        $match = @($Groups | Where-Object {
            $_.name -eq $name -and (@($_.scopes) -contains $Scope)
        }) | Select-Object -First 1
        if ($match) { return $match }
    }
    if ($Optional) {
        Write-Warning "Optional Cloudflare permission unavailable: $($Names -join ' / ')"
        return $null
    }
    throw "Required Cloudflare permission unavailable: $($Names -join ' / ') [$Scope]"
}

function Require-Command([string]$Name, [string]$InstallHint) {
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "$Name is required. $InstallHint"
    }
}

Write-Host "CodeFEDDY Control Plane bootstrap" -ForegroundColor Green
Write-Host "This script never prints the Cloudflare or GitHub credential values."

# ---------------------------------------------------------------------------
# 1. Obtain the one-time Cloudflare token-factory credential.
# ---------------------------------------------------------------------------
$bootstrapToken = $env:CLOUDFLARE_BOOTSTRAP_TOKEN
if ([string]::IsNullOrWhiteSpace($bootstrapToken)) {
    Write-Step "Cloudflare bootstrap credential"
    Write-Host "Paste the ONE-TIME Cloudflare 'Create Additional Tokens' token."
    Write-Host "Input is hidden and is kept only in this PowerShell process."
    $bootstrapToken = ConvertFrom-Secure (Read-Host "Bootstrap token" -AsSecureString)
}

Write-Step "Checking token-factory access"
$groups = Invoke-Cf -Token $bootstrapToken -Method GET -Path "/user/tokens/permission_groups"
if (-not $groups) { throw "Cloudflare returned no API-token permission groups." }

# Cloudflare currently exposes both Edit-style and Write-style labels in some
# token contexts. Resolve the live permission IDs instead of hard-coding IDs.
$accountScope = "com.cloudflare.api.account"
$zoneScope = "com.cloudflare.api.account.zone"

$accountSpecs = @(
    @{ Names=@("Account Settings Read"); Optional=$false },
    @{ Names=@("Workers Scripts Write","Workers Scripts Edit"); Optional=$false },
    @{ Names=@("Workers KV Storage Write","Workers KV Storage Edit"); Optional=$true },
    @{ Names=@("Workers R2 Storage Write","Workers R2 Storage Edit"); Optional=$true },
    @{ Names=@("Workers CI Write","Workers CI Edit"); Optional=$true },
    @{ Names=@("D1 Write","D1 Edit"); Optional=$true },
    @{ Names=@("Pages Write","Pages Edit"); Optional=$true },
    @{ Names=@("Queues Write","Queues Edit"); Optional=$true },
    @{ Names=@("Workers AI Write","Workers AI Edit"); Optional=$true },
    @{ Names=@("Vectorize Write","Vectorize Edit"); Optional=$true },
    @{ Names=@("Email Routing Addresses Write","Email Routing Addresses Edit"); Optional=$false }
)

$zoneSpecs = @(
    @{ Names=@("Zone Read"); Optional=$false },
    @{ Names=@("DNS Write","DNS Edit"); Optional=$false },
    @{ Names=@("Workers Routes Write","Workers Routes Edit"); Optional=$false },
    @{ Names=@("Zone Settings Write","Zone Settings Edit"); Optional=$false },
    @{ Names=@("Email Routing Rules Write","Email Routing Rules Edit"); Optional=$false },
    @{ Names=@("Cache Purge"); Optional=$true }
)

$accountGroups = @()
foreach ($spec in $accountSpecs) {
    $g = Find-PermissionGroup -Groups $groups -Names $spec.Names -Scope $accountScope -Optional:([bool]$spec.Optional)
    if ($g) { $accountGroups += @{ id = $g.id } }
}

$zoneGroups = @()
foreach ($spec in $zoneSpecs) {
    $g = Find-PermissionGroup -Groups $groups -Names $spec.Names -Scope $zoneScope -Optional:([bool]$spec.Optional)
    if ($g) { $zoneGroups += @{ id = $g.id } }
}

# ---------------------------------------------------------------------------
# 2. Create a reusable Clintware infrastructure token programmatically.
#    This is intentionally broad within the user's Cloudflare resources, but
#    it still excludes billing, memberships and token-administration powers.
# ---------------------------------------------------------------------------
Write-Step "Creating $CloudflareTokenName"
$policies = @(
    @{
        effect = "allow"
        resources = @{ "com.cloudflare.api.account.*" = "*" }
        permission_groups = $accountGroups
    },
    @{
        effect = "allow"
        resources = @{ "com.cloudflare.api.account.zone.*" = "*" }
        permission_groups = $zoneGroups
    }
)

$created = Invoke-Cf -Token $bootstrapToken -Method POST -Path "/user/tokens" -Body @{
    name = $CloudflareTokenName
    policies = $policies
}

$controlToken = [string]$created.value
if ([string]::IsNullOrWhiteSpace($controlToken)) {
    throw "Cloudflare created a token but did not return its value. Stop here rather than creating another token blindly."
}

# Bootstrap credential is no longer needed in this process.
$bootstrapToken = $null
Remove-Item Env:CLOUDFLARE_BOOTSTRAP_TOKEN -ErrorAction SilentlyContinue

Write-Step "Verifying new Cloudflare token"
$verify = Invoke-Cf -Token $controlToken -Method GET -Path "/user/tokens/verify"
if ($verify.status -ne "active") { throw "New Cloudflare token is not active." }
Write-Host "Cloudflare token: ACTIVE" -ForegroundColor Green

# Resolve account and zone using the newly created token.
$accounts = @(Invoke-Cf -Token $controlToken -Method GET -Path "/accounts?per_page=50")
if ([string]::IsNullOrWhiteSpace($CloudflareAccountId)) {
    if ($accounts.Count -eq 1) {
        $CloudflareAccountId = [string]$accounts[0].id
    } else {
        $matching = @($accounts | Where-Object { $_.name -match "Clintware|Clint|Kosh" })
        if ($matching.Count -eq 1) {
            $CloudflareAccountId = [string]$matching[0].id
        } else {
            Write-Host "Available Cloudflare accounts:"
            $accounts | ForEach-Object { Write-Host "  $($_.name)  $($_.id)" }
            throw "More than one account is available. Re-run with -CloudflareAccountId <id>."
        }
    }
}
Write-Host "Cloudflare account resolved." -ForegroundColor Green

$zones = @(Invoke-Cf -Token $controlToken -Method GET -Path "/zones?name=$([uri]::EscapeDataString($ZoneName))&account.id=$CloudflareAccountId")
if ($zones.Count -lt 1) { throw "Zone '$ZoneName' was not found in the resolved account." }
$zoneId = [string]$zones[0].id
Write-Host "Zone $ZoneName resolved." -ForegroundColor Green

# Prove the permissions that previously failed.
Write-Step "Testing DNS and Email Routing permissions"
$null = Invoke-Cf -Token $controlToken -Method GET -Path "/zones/$zoneId/dns_records?per_page=1"
$null = Invoke-Cf -Token $controlToken -Method GET -Path "/zones/$zoneId/email/routing/rules?per_page=1"
$null = Invoke-Cf -Token $controlToken -Method GET -Path "/accounts/$CloudflareAccountId/email/routing/addresses?per_page=1"
Write-Host "DNS access: OK" -ForegroundColor Green
Write-Host "Email Routing Rules access: OK" -ForegroundColor Green
Write-Host "Email Routing Addresses access: OK" -ForegroundColor Green

# ---------------------------------------------------------------------------
# 3. Use the existing GitHub CLI authorization as the GitHub control-plane
#    credential. A GitHub App can replace it later without changing the MCP API.
# ---------------------------------------------------------------------------
$githubToken = $env:GITHUB_CONTROL_PLANE_TOKEN
if ([string]::IsNullOrWhiteSpace($githubToken)) {
    if (Get-Command gh -ErrorAction SilentlyContinue) {
        try { $githubToken = (gh auth token 2>$null).Trim() } catch { $githubToken = "" }
    }
}

if ([string]::IsNullOrWhiteSpace($githubToken)) {
    Write-Warning "No GitHub CLI credential found. Cloudflare is ready, but GitHub runtime setup was skipped."
    Write-Host "Run: gh auth login --web"
    Write-Host "Then re-run this script; it will reuse the Cloudflare token only if supplied as CLOUDFLARE_CONTROL_PLANE_TOKEN."
} else {
    Write-Step "Checking GitHub credential"
    $oldGh = $env:GH_TOKEN
    try {
        $env:GH_TOKEN = $githubToken
        gh api user --silent
        Write-Host "GitHub authentication: OK" -ForegroundColor Green
    } finally {
        if ($null -eq $oldGh) { Remove-Item Env:GH_TOKEN -ErrorAction SilentlyContinue } else { $env:GH_TOKEN = $oldGh }
    }
}

# ---------------------------------------------------------------------------
# 4. Install infrastructure credentials into codefeddy-control-plane.
# ---------------------------------------------------------------------------
if (-not $SkipWorkerSecrets) {
    Require-Command "npx" "Install Node.js 22+ and retry."
    Write-Step "Installing encrypted Worker secrets"
    $oldCfToken = $env:CLOUDFLARE_API_TOKEN
    $oldCfAccount = $env:CLOUDFLARE_ACCOUNT_ID
    try {
        $env:CLOUDFLARE_API_TOKEN = $controlToken
        $env:CLOUDFLARE_ACCOUNT_ID = $CloudflareAccountId

        $controlToken | npx --yes wrangler@4.129.0 secret put CLOUDFLARE_CONTROL_PLANE_TOKEN --name $WorkerName | Out-Host
        if ($LASTEXITCODE -ne 0) { throw "Failed to install CLOUDFLARE_CONTROL_PLANE_TOKEN into Worker." }

        if (-not [string]::IsNullOrWhiteSpace($githubToken)) {
            $githubToken | npx --yes wrangler@4.129.0 secret put GITHUB_CONTROL_PLANE_TOKEN --name $WorkerName | Out-Host
            if ($LASTEXITCODE -ne 0) { throw "Failed to install GITHUB_CONTROL_PLANE_TOKEN into Worker." }
        }
    } finally {
        if ($null -eq $oldCfToken) { Remove-Item Env:CLOUDFLARE_API_TOKEN -ErrorAction SilentlyContinue } else { $env:CLOUDFLARE_API_TOKEN = $oldCfToken }
        if ($null -eq $oldCfAccount) { Remove-Item Env:CLOUDFLARE_ACCOUNT_ID -ErrorAction SilentlyContinue } else { $env:CLOUDFLARE_ACCOUNT_ID = $oldCfAccount }
    }
}

# ---------------------------------------------------------------------------
# 5. Update deployment secrets in GitHub so future Actions use this credential.
# ---------------------------------------------------------------------------
if (-not $SkipGitHubSecrets -and -not [string]::IsNullOrWhiteSpace($githubToken)) {
    Require-Command "gh" "Install GitHub CLI and retry."
    Write-Step "Updating GitHub Actions deployment secrets"
    $oldGh = $env:GH_TOKEN
    try {
        $env:GH_TOKEN = $githubToken
        $controlToken | gh secret set CLOUDFLARE_API_TOKEN --repo $Repo
        if ($LASTEXITCODE -ne 0) { throw "Failed to set CLOUDFLARE_API_TOKEN in GitHub Actions." }
        $CloudflareAccountId | gh secret set CLOUDFLARE_ACCOUNT_ID --repo $Repo
        if ($LASTEXITCODE -ne 0) { throw "Failed to set CLOUDFLARE_ACCOUNT_ID in GitHub Actions." }
    } finally {
        if ($null -eq $oldGh) { Remove-Item Env:GH_TOKEN -ErrorAction SilentlyContinue } else { $env:GH_TOKEN = $oldGh }
    }
    Write-Host "GitHub Actions secrets: UPDATED" -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# 6. Smoke test the public control plane.
# ---------------------------------------------------------------------------
Write-Step "Testing mcp.codefeddy.com"
try {
    $health = Invoke-RestMethod -Uri "https://mcp.codefeddy.com/health" -Method GET -TimeoutSec 20
    Write-Host "mcp.codefeddy.com health: OK" -ForegroundColor Green
} catch {
    Write-Warning "Credentials were installed, but the public health endpoint did not return successfully: $($_.Exception.Message)"
}

Write-Host "`nBOOTSTRAP COMPLETE" -ForegroundColor Green
Write-Host "Cloudflare infrastructure credential is active and was not printed."
Write-Host "The temporary token-factory credential can now be revoked."
Write-Host "Recommended next step: let the control plane issue scoped MCP client tokens per project instead of sharing this infrastructure token."

# Minimize lifetime of credential variables.
$controlToken = $null
$githubToken = $null

