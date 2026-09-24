param(
  [switch]$SkipDeploy,
  [switch]$SkipQQInstall
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

function Write-Step([string]$Text) {
  Write-Host ("CODEFEDDY // " + $Text) -ForegroundColor Cyan
}

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { throw "GitHub CLI is required." }
if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw "Git is required." }

Write-Step "upgrading qq watchdog before CodeFEDDY provisioning"
$repairUrl = "https://raw.githubusercontent.com/codeFEDDY/codeFEDDY.github.io/main/quillgeist-lite/tasks/repair-local-service.ps1"
$repairPath = Join-Path $env:TEMP ("qq-repair-" + [Guid]::NewGuid().ToString("n") + ".ps1")
try {
  Invoke-WebRequest -Uri $repairUrl -OutFile $repairPath -UseBasicParsing
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $repairPath -SkipRunnerRestart
  if ($LASTEXITCODE -ne 0) { throw "qq watchdog upgrade failed with exit code $LASTEXITCODE." }
  Write-Step "qq watchdog upgraded to event-driven wake recovery"
}
finally {
  Remove-Item $repairPath -Force -ErrorAction SilentlyContinue
}

Write-Step "resolving local codeFEDDY GitHub identity"
$codeFeddyToken = ""
try { $codeFeddyToken = (gh auth token --hostname github.com --user codeFEDDY 2>$null).Trim() } catch {}
if (-not $codeFeddyToken) { throw "Local GitHub CLI has no authenticated codeFEDDY token." }

$env:GH_TOKEN=$codeFeddyToken
$login=(gh api user --jq .login).Trim()
if ($LASTEXITCODE -ne 0 -or $login.ToLowerInvariant() -ne "codefeddy") {
  throw "Resolved GitHub token is not the codeFEDDY identity. Current identity: $login"
}
$push=(gh api repos/codeFEDDY/codeFEDDY.github.io --jq '.permissions.push').Trim()
if ($push.ToLowerInvariant() -ne "true") { throw "codeFEDDY token does not have push access to codeFEDDY/codeFEDDY.github.io." }
Write-Step "GitHub push authority verified"

$work=Join-Path $env:TEMP ("codefeddy-bootstrap-" + [Guid]::NewGuid().ToString("n"))
$sourceZip=Join-Path $work "source.zip"
$sourceDir=Join-Path $work "source"
$target=Join-Path $work "codefeddy"
New-Item -ItemType Directory -Force -Path $work,$sourceDir | Out-Null

function Replace-TextTree {
  param([string]$Root)
  $extensions = @(".js",".mjs",".json",".jsonc",".md",".ps1",".py",".yml",".yaml",".html",".css",".txt",".c",".cs")
  Get-ChildItem -Path $Root -Recurse -File | Where-Object { $extensions -contains $_.Extension.ToLowerInvariant() } | ForEach-Object {
    $path=$_.FullName
    $text=Get-Content $path -Raw
    $next=$text
    $next=$next.Replace("https://mcp.codefeddy.com","https://mcp.codefeddy.com")
    $next=$next.Replace("wss://mcp.codefeddy.com","wss://mcp.codefeddy.com")
    $next=$next.Replace("https://auth.codefeddy.com","https://auth.codefeddy.com")
    $next=$next.Replace("mcp.codefeddy.com","mcp.codefeddy.com")
    $next=$next.Replace("auth.codefeddy.com","auth.codefeddy.com")
    $next=$next.Replace("codefeddy.com","codefeddy.com")
    $next=$next.Replace("codeFEDDY/codeFEDDY.github.io","codeFEDDY/codeFEDDY.github.io")
    $next=$next.Replace("codeFEDDY.github.io","codeFEDDY.github.io")
    $next=$next.Replace('"owner":"codeFEDDY"','"owner":"codeFEDDY"')
    $next=$next.Replace('"identity":"codefeddy"','"identity":"codefeddy"')
    $next=$next.Replace("CodeFEDDY Control Plane","CodeFEDDY Control Plane")
    $next=$next.Replace("codefeddy-control-plane","codefeddy-control-plane")
    $next=$next.Replace("CodeFEDDY Identity Broker","CodeFEDDY Identity Broker")
    $next=$next.Replace("codefeddy-identity-broker","codefeddy-identity-broker")
    $next=$next.Replace("CodeFEDDY qq","CodeFEDDY qq")
    $next=$next.Replace("CODEFEDDY QQ","CODEFEDDY QQ")
    $next=$next.Replace("CodeFEDDY\\QQ","CodeFEDDY\\QQ")
    $next=$next.Replace("CodeFEDDYQQ","CodeFEDDYQQ")
    $next=$next.Replace("Expected GitHub identity codeFEDDY","Expected GitHub identity codeFEDDY")
    $next=$next.Replace('"codeFEDDY"','"codeFEDDY"')
    if ($next -ne $text) { Set-Content -Path $path -Value $next -Encoding UTF8 }
  }
}

try {
  Write-Step "downloading reviewed control-plane source"
  Invoke-WebRequest -Uri "https://github.com/codeFEDDY/codeFEDDY.github.io/archive/refs/heads/main.zip" -OutFile $sourceZip -UseBasicParsing
  Expand-Archive -Path $sourceZip -DestinationPath $sourceDir -Force
  $src=(Get-ChildItem $sourceDir -Directory | Select-Object -First 1).FullName
  if (-not $src) { throw "Could not locate extracted source." }

  Write-Step "cloning canonical CodeFEDDY repository"
  $auth=[Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("x-access-token:$codeFeddyToken"))
  git -c "http.extraHeader=Authorization: Basic $auth" clone --depth 1 https://github.com/codeFEDDY/codeFEDDY.github.io.git $target
  if ($LASTEXITCODE -ne 0) { throw "Clone failed." }

  Write-Step "installing CodeFEDDY-owned control plane and qq source"
  foreach ($name in @("control-plane","identity-broker","quillgeist-lite")) {
    $dest=Join-Path $target $name
    if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
    Copy-Item (Join-Path $src $name) $dest -Recurse -Force
  }

  $wf=Join-Path $target ".github\workflows"
  New-Item -ItemType Directory -Force -Path $wf | Out-Null
  $workflowMap=@{
    "deploy-control-plane.yml"="deploy-codefeddy-control-plane.yml"
    "deploy-identity-broker.yml"="deploy-codefeddy-identity-broker.yml"
    "quillgeist-lite-dispatch.yml"="codefeddy-qq-dispatch.yml"
    "validate-quillgeist-lite.yml"="validate-codefeddy-qq.yml"
  }
  foreach ($k in $workflowMap.Keys) {
    Copy-Item (Join-Path $src ".github\workflows\$k") (Join-Path $wf $workflowMap[$k]) -Force
  }

  Replace-TextTree $target

  Write-Step "enforcing CodeFEDDY-only active product registry"
  $indexPath=Join-Path $target "control-plane\src\index.js"
  $index=Get-Content $indexPath -Raw
  $index=[regex]::Replace(
    $index,
    'const DEFAULT_PRODUCTS=\{[^;]+\};',
    'const DEFAULT_PRODUCTS={codefeddy:DEFAULT_CODEFEDDY,"quillgeist-lite":DEFAULT_QUILLGEIST_LITE};',
    [Text.RegularExpressions.RegexOptions]::Singleline
  )
  $index=$index.Replace(
    'repo:{identity:"codefeddy",owner:"codeFEDDY",name:"codeFEDDY.github.io",default_branch:"main",read:true,write_prefixes:[""],delete_prefixes:[""],allowed_workflows:[]},',
    'repo:{identity:"codefeddy",owner:"codeFEDDY",name:"codeFEDDY.github.io",default_branch:"main",read:true,write_prefixes:[""],delete_prefixes:[""],allowed_workflows:["deploy-codefeddy-control-plane.yml","deploy-codefeddy-identity-broker.yml","codefeddy-qq-dispatch.yml"]},'
  )
  $index=$index.Replace(
    'dns:{allowed_names:[]},',
    'dns:{allowed_names:["mcp.codefeddy.com","auth.codefeddy.com"]},'
  )
  $index=$index.Replace(
    'capabilities:["repo.read:codeFEDDY.github.io","repo.write:*","repo.delete:*","repo.branch:create","repo.branch:read","repo.commit:status","analytics.write:codefeddy","analytics.read:codefeddy"],',
    'capabilities:["repo.read:codeFEDDY.github.io","repo.write:*","repo.delete:*","repo.branch:create","repo.branch:read","repo.commit:status","repo.workflow:dispatch","repo.workflow:status","deployment.read","deployment.execute:codefeddy","dns.ensure:mcp.codefeddy.com","dns.ensure:auth.codefeddy.com","analytics.write:codefeddy","analytics.read:codefeddy","research.invoke","ai.invoke","flow.read:codefeddy","flow.write:codefeddy","flow.run:codefeddy","jira.read:codefeddy","jira.write:codefeddy","confluence.read:codefeddy","confluence.write:codefeddy"],'
  )
  Set-Content -Path $indexPath -Value $index -Encoding UTF8

  Write-Step "resetting active manifests to CodeFEDDY only"
  $manifestDir=Join-Path $target "control-plane\manifests"
  if (Test-Path $manifestDir) { Remove-Item (Join-Path $manifestDir "*") -Recurse -Force -ErrorAction SilentlyContinue }
  New-Item -ItemType Directory -Force -Path $manifestDir | Out-Null
  @'
{
  "product": "codefeddy",
  "environment": "production",
  "version": 2,
  "repo": {
    "identity": "codefeddy",
    "owner": "codeFEDDY",
    "name": "codeFEDDY.github.io",
    "default_branch": "main",
    "read": true,
    "write_prefixes": [""],
    "delete_prefixes": [""],
    "allowed_workflows": ["deploy-codefeddy-control-plane.yml","deploy-codefeddy-identity-broker.yml","codefeddy-qq-dispatch.yml"]
  },
  "dns": {"allowed_names":["mcp.codefeddy.com","auth.codefeddy.com"]},
  "capabilities": [
    "repo.read:codeFEDDY.github.io","repo.write:*","repo.delete:*","repo.branch:create","repo.branch:read","repo.commit:status",
    "repo.workflow:dispatch","repo.workflow:status","deployment.read","deployment.execute:codefeddy",
    "dns.ensure:mcp.codefeddy.com","dns.ensure:auth.codefeddy.com",
    "analytics.write:codefeddy","analytics.read:codefeddy","research.invoke","ai.invoke",
    "flow.read:codefeddy","flow.write:codefeddy","flow.run:codefeddy",
    "jira.read:codefeddy","jira.write:codefeddy","confluence.read:codefeddy","confluence.write:codefeddy"
  ],
  "deny": ["secrets.read","secrets.export","billing.manage","infrastructure.admin:*"],
  "protected_paths": [".github/workflows/",".github/actions/","control-plane/security/","control-plane/policy/"],
  "telemetry_namespace": "codefeddy",
  "created_at": "2026-09-23T00:00:00.000Z"
}
'@ | Set-Content (Join-Path $manifestDir "codefeddy.json") -Encoding UTF8

  @'
{
  "product": "quillgeist-lite",
  "environment": "production",
  "version": 1,
  "repo": {
    "identity": "codefeddy",
    "owner": "codeFEDDY",
    "name": "codeFEDDY.github.io",
    "default_branch": "main",
    "read": true,
    "write_prefixes": ["quillgeist-lite/","control-plane/","identity-broker/"],
    "delete_prefixes": [],
    "allowed_workflows": ["deploy-codefeddy-control-plane.yml","codefeddy-qq-dispatch.yml"]
  },
  "dns": {"allowed_names":["mcp.codefeddy.com"]},
  "capabilities": [
    "repo.read:codeFEDDY.github.io","repo.write:quillgeist-lite/**","repo.write:control-plane/**","repo.write:identity-broker/**",
    "repo.branch:create","repo.branch:read","repo.commit:status","repo.workflow:dispatch","repo.workflow:status",
    "deployment.read","deployment.execute:quillgeist-lite","analytics.write:quillgeist-lite","analytics.read:quillgeist-lite",
    "local.read:quillgeist-lite","local.run:quillgeist-lite"
  ],
  "deny":["secrets.read","secrets.export","billing.manage","repo.delete","infrastructure.admin:*","local.shell:raw"],
  "protected_paths":[".github/workflows/",".github/actions/","control-plane/security/","control-plane/policy/"],
  "telemetry_namespace":"quillgeist-lite",
  "created_at":"2026-09-23T00:00:00.000Z"
}
'@ | Set-Content (Join-Path $manifestDir "quillgeist-lite.json") -Encoding UTF8

  Write-Step "removing Clintware-only active workflow checks"
  $cpWorkflow=Join-Path $wf "deploy-codefeddy-control-plane.yml"
  $w=Get-Content $cpWorkflow -Raw
  $w=[regex]::Replace($w,'(?ms)^      - name: Verify research activation and ProofOS end-to-end.*?(?=^      - name: Report adapter configuration)','')
  Set-Content $cpWorkflow $w -Encoding UTF8

  Write-Step "adding CodeFEDDY control-plane documentation"
  $docDir=Join-Path $target "docs"
  New-Item -ItemType Directory -Force -Path $docDir | Out-Null
  @'
# CodeFEDDY Control Plane

Canonical infrastructure boundary for CODE FEDDY.

- Website repository: codeFEDDY/codeFEDDY.github.io
- Primary site: https://codefeddy.com
- MCP/control plane: https://mcp.codefeddy.com
- Identity broker target: https://auth.codefeddy.com
- Local runner: CodeFEDDY qq under quillgeist-lite/

The CodeFEDDY control plane is modeled on the proven Clintware architecture but has its own repository, domains, Worker, credentials, manifests, telemetry namespace, local runner, and deployment workflows.

## Identity boundary

No CodeFEDDY page or production application is hosted from a Clintware repository. Clintware may be used only as a temporary migration/dispatch transport while the CodeFEDDY runner is being bootstrapped.

## Security

Provider credentials remain server-side. MCP clients receive scoped, revocable capability credentials. The local runner uses an outbound event-driven channel and an allowlisted task registry rather than arbitrary remote shell execution.
'@ | Set-Content (Join-Path $docDir "CONTROL-PLANE.md") -Encoding UTF8

  Write-Step "checking JavaScript syntax"
  Push-Location (Join-Path $target "control-plane")
  try {
    if (Get-Command node -ErrorAction SilentlyContinue) {
      node --check src/index.js
      if ($LASTEXITCODE -ne 0) { throw "control-plane syntax check failed" }
      node --check src/entry.js
      if ($LASTEXITCODE -ne 0) { throw "entry syntax check failed" }
    }
  } finally { Pop-Location }

  Write-Step "committing CodeFEDDY-owned infrastructure"
  Push-Location $target
  try {
    git config user.name "CODE FEDDY Automation"
    git config user.email "actions@codefeddy.com"
    git add control-plane identity-broker quillgeist-lite .github/workflows/deploy-codefeddy-control-plane.yml .github/workflows/deploy-codefeddy-identity-broker.yml .github/workflows/codefeddy-qq-dispatch.yml .github/workflows/validate-codefeddy-qq.yml docs/CONTROL-PLANE.md
    $changes=(git status --porcelain)
    if ($changes) {
      git commit -m "Add CodeFEDDY control plane and dedicated qq"
      if ($LASTEXITCODE -ne 0) { throw "Commit failed." }
      git -c "http.extraHeader=Authorization: Basic $auth" push origin main
      if ($LASTEXITCODE -ne 0) { throw "Push failed." }
    } else {
      Write-Host "No repository changes required."
    }
  } finally { Pop-Location }

  if (-not $SkipDeploy) {
    Write-Step "deploying mcp.codefeddy.com from CodeFEDDY source"
    $cp=Join-Path $target "control-plane"
    Push-Location $cp
    try {
      if (-not (Test-Path "node_modules")) {
        npm install --ignore-scripts --no-audit --no-fund
        if ($LASTEXITCODE -ne 0) { throw "npm install failed" }
      }
      if (Get-Command npx -ErrorAction SilentlyContinue) {
        npx wrangler deploy --config wrangler.jsonc
      } else {
        throw "npx/wrangler is unavailable."
      }
      if ($LASTEXITCODE -ne 0) { throw "CodeFEDDY control-plane deployment failed." }

      $mcpBytes=New-Object byte[] 48
      [Security.Cryptography.RandomNumberGenerator]::Fill($mcpBytes)
      $mcpToken=[Convert]::ToBase64String($mcpBytes).TrimEnd("=").Replace("+","-").Replace("/","_")
      $adminBytes=New-Object byte[] 48
      [Security.Cryptography.RandomNumberGenerator]::Fill($adminBytes)
      $adminToken=[Convert]::ToBase64String($adminBytes).TrimEnd("=").Replace("+","-").Replace("/","_")

      $secretValues=@{
        CONTROL_PLANE_MCP_TOKEN=$mcpToken
        CONTROL_PLANE_ADMIN_TOKEN=$adminToken
        GITHUB_TOKEN_CODEFEDDY=$codeFeddyToken
        GITHUB_CONTROL_PLANE_TOKEN=$codeFeddyToken
      }
      foreach ($name in $secretValues.Keys) {
        $secretValues[$name] | npx wrangler secret put $name --config wrangler.jsonc | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Failed to configure Worker secret $name" }
      }

      foreach ($name in @("EXA_API_KEY","ATLASSIAN_CLIENT_ID","ATLASSIAN_CLIENT_SECRET","JIRA_TOKEN_ENCRYPTION_KEY","CLOUDFLARE_CONTROL_PLANE_TOKEN","CLOUDFLARE_ZONE_ID")) {
        $value=[Environment]::GetEnvironmentVariable($name)
        if ($value) {
          $value | npx wrangler secret put $name --config wrangler.jsonc | Out-Null
        }
      }

      $localSecretDir=Join-Path $env:LOCALAPPDATA "CodeFEDDY\QQ"
      New-Item -ItemType Directory -Force -Path $localSecretDir | Out-Null
      @{
        endpoint="https://mcp.codefeddy.com"
        mcp_token=$mcpToken
        admin_token=$adminToken
        created_at=(Get-Date).ToUniversalTime().ToString("o")
      } | ConvertTo-Json | Set-Content (Join-Path $localSecretDir "control-plane.local.json") -Encoding UTF8
      Write-Step "control-plane secrets configured and retained locally"
    } finally { Pop-Location }

    $health=$null
    for ($i=1;$i -le 24;$i++) {
      try {
        $health=Invoke-RestMethod -Uri "https://mcp.codefeddy.com/health" -TimeoutSec 10
        if ($health.ok) { break }
      } catch {}
      Start-Sleep -Seconds 5
    }
    if (-not $health -or -not $health.ok) { throw "mcp.codefeddy.com health verification failed." }
    Write-Step ("live control plane verified: " + $health.service)
  }

  if (-not $SkipQQInstall) {
    Write-Step "installing separate CodeFEDDY qq"
    $env:GH_TOKEN=$codeFeddyToken
    $installUrl="https://raw.githubusercontent.com/codeFEDDY/codeFEDDY.github.io/main/quillgeist-lite/install.ps1"
    $installPath=Join-Path $work "install-codefeddy-qq.ps1"
    Invoke-WebRequest -Uri $installUrl -OutFile $installPath -UseBasicParsing
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installPath
    if ($LASTEXITCODE -ne 0) { throw "CodeFEDDY qq installer failed with exit code $LASTEXITCODE." }
    Write-Step "CodeFEDDY qq installation completed"
  }

  Write-Step "COMPLETE"
}
finally {
  Remove-Item Env:GH_TOKEN -ErrorAction SilentlyContinue
  $codeFeddyToken=$null
  if (Test-Path $work) { Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue }
}

