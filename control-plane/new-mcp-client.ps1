param(
  [Parameter(Mandatory=$true)]
  [string]$Name,
  [string[]]$AllowedProducts = @("*"),
  [string]$Endpoint = "https://mcp.codefeddy.com"
)

$ErrorActionPreference = "Stop"

$adminToken = $env:CONTROL_PLANE_ADMIN_TOKEN
if (-not $adminToken) {
  $secure = Read-Host "Paste CONTROL_PLANE_ADMIN_TOKEN" -AsSecureString
  $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
  try {
    $adminToken = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
  } finally {
    if ($bstr -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
  }
}
if (-not $adminToken) { throw "Admin token cannot be empty." }

$body = @{
  name = $Name
  allowed_products = $AllowedProducts
} | ConvertTo-Json -Depth 5

$response = Invoke-RestMethod `
  -Method Post `
  -Uri "$Endpoint/api/v1/mcp/clients" `
  -Headers @{ Authorization = "Bearer $adminToken" } `
  -ContentType "application/json" `
  -Body $body

Write-Host ""
Write-Host "Created Clintware MCP client: $($response.client_id)"
Write-Host "MCP endpoint: $Endpoint/mcp"
Write-Host ""
Write-Host "CLIENT TOKEN (shown once):"
Write-Host $response.token
Write-Host ""
Write-Host "Put this token only in the MCP/API credential field for '$Name'."
Write-Host "Do not paste GitHub or Cloudflare credentials into the LLM."
Remove-Variable adminToken -ErrorAction SilentlyContinue

