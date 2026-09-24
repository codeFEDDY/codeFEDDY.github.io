$ErrorActionPreference = "Stop"

foreach ($candidate in @("clang","gcc","cl")) {
  if (Get-Command $candidate -ErrorAction SilentlyContinue) {
    Write-Host "C compiler already available: $candidate" -ForegroundColor Green
    exit 0
  }
}

if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
  throw "No C compiler is available and winget is not installed."
}

Write-Host "No C compiler found. Checking Windows Package Manager for LLVM..." -ForegroundColor Cyan
winget search --id LLVM.LLVM --exact
if ($LASTEXITCODE -ne 0) {
  throw "LLVM.LLVM was not found by winget. No compiler was installed."
}

Write-Host "Installing LLVM/Clang..." -ForegroundColor Cyan
winget install --id LLVM.LLVM --exact --source winget --accept-package-agreements --accept-source-agreements
if ($LASTEXITCODE -ne 0) {
  throw "LLVM installation failed."
}

$possible = @(
  "$env:ProgramFiles\LLVM\bin",
  "$env:LOCALAPPDATA\Programs\LLVM\bin"
)

foreach ($dir in $possible) {
  if (Test-Path $dir) {
    $env:Path += ";$dir"
  }
}

if (-not (Get-Command clang -ErrorAction SilentlyContinue)) {
  Write-Warning "LLVM installed, but clang is not visible in this process yet. The next Quillgeist Lite runner restart should pick it up."
  exit 0
}

Write-Host "C runtime ready: clang" -ForegroundColor Green
