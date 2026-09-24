$ErrorActionPreference = "Continue"

Write-Host ""
Write-Host "=== CODEFEDDY QQ DOCTOR ===" -ForegroundColor Cyan

$rows = @()
foreach ($name in @("powershell","pwsh","gh","git","gcloud","python","python3","node","clang","gcc","cl")) {
  $cmd = Get-Command $name -ErrorAction SilentlyContinue
  $rows += [PSCustomObject]@{
    Tool = $name
    Found = [bool]$cmd
    Path = if ($cmd) { $cmd.Source } else { "" }
  }
}
$rows | Format-Table -AutoSize

if (Get-Command gh -ErrorAction SilentlyContinue) {
  Write-Host ""
  Write-Host "GitHub authentication:" -ForegroundColor Cyan
  gh auth status
}

if (Get-Command gcloud -ErrorAction SilentlyContinue) {
  Write-Host ""
  Write-Host "Google Cloud accounts:" -ForegroundColor Cyan
  gcloud auth list --format="table(account,status)"
}

Write-Host ""
Write-Host "Runtime summary:" -ForegroundColor Cyan
Write-Host ("  PowerShell: " + [bool](Get-Command powershell -ErrorAction SilentlyContinue))
Write-Host ("  Python:     " + [bool]((Get-Command python -ErrorAction SilentlyContinue) -or (Get-Command python3 -ErrorAction SilentlyContinue)))
Write-Host ("  C compiler: " + [bool]((Get-Command clang -ErrorAction SilentlyContinue) -or (Get-Command gcc -ErrorAction SilentlyContinue) -or (Get-Command cl -ErrorAction SilentlyContinue)))
Write-Host ""
Write-Host "Quillgeist Lite doctor complete." -ForegroundColor Green

