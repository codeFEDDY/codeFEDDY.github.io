param(
  [Parameter(Mandatory=$true)]
  [string]$Alias
)

$ErrorActionPreference = "Stop"
$normalized = ($Alias.Trim().ToUpperInvariant() -replace '[^A-Z0-9]','_')
if (-not $normalized) { throw "Alias must contain at least one letter or number." }
$secretName = "GITHUB_TOKEN_$normalized"

Write-Host "Adding GitHub identity '$Alias' as Cloudflare Worker secret '$secretName'."
Write-Host "The token value will not be written to disk."
$secure = Read-Host "Paste the fine-grained GitHub token" -AsSecureString
$bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
try {
  $token = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
  if (-not $token) { throw "Token cannot be empty." }
  $token | npx wrangler secret put $secretName --config control-plane/wrangler.jsonc
} finally {
  if ($bstr -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
  Remove-Variable token -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "Configured $secretName."
Write-Host "Set repo.identity to '$($Alias.Trim().ToLowerInvariant())' in each product manifest that should use this account."
Write-Host "Verify with: Invoke-RestMethod https://mcp.codefeddy.com/health | ConvertTo-Json -Depth 8"

