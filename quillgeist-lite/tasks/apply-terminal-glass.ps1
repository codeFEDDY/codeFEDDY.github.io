param(
  [switch]$NoRestart
)

$ErrorActionPreference = "Stop"

$HomeDir = Join-Path $env:LOCALAPPDATA "Clintware\QuillgeistLite"
$RepairPath = Join-Path $HomeDir "terminal_repair.py"
$RepairUrl = "https://raw.githubusercontent.com/codeFEDDY/codeFEDDY.github.io/main/quillgeist-lite/tools/terminal_repair.py?v=2026.09.24.5"

New-Item -ItemType Directory -Force -Path $HomeDir | Out-Null

Write-Host "PYTHON // refreshing deterministic Quillgeist Lite terminal repair" -ForegroundColor Cyan
$temp = $RepairPath + ".new"
Invoke-WebRequest -Uri $RepairUrl -OutFile $temp -UseBasicParsing -Headers @{"Cache-Control"="no-cache"}
if (-not (Test-Path $temp) -or (Get-Item $temp).Length -lt 5000) {
  Remove-Item $temp -Force -ErrorAction SilentlyContinue
  throw "Python terminal repair download failed validation."
}
Move-Item $temp $RepairPath -Force

$python = Get-Command py -ErrorAction SilentlyContinue
$args = @("-3",$RepairPath)
if (-not $python) {
  $python = Get-Command python -ErrorAction SilentlyContinue
  $args = @($RepairPath)
}
if (-not $python) {
  throw "Python 3 is required for the Quillgeist Lite terminal repair."
}

& $python.Source @args
if ($LASTEXITCODE -ne 0) {
  throw "Python terminal repair failed with exit code $LASTEXITCODE."
}

Write-Host "READY // terminal profile and retro boot art verified by Python." -ForegroundColor Green

