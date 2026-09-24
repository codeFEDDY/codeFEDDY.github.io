$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$RepoRaw = "https://raw.githubusercontent.com/codeFEDDY/codeFEDDY.github.io/main"
$PluginName = "clintware-eclipse-logo"
$PluginRoot = Join-Path $env:APPDATA "GIMP\3.0\plug-ins"
$PluginDir = Join-Path $PluginRoot $PluginName
$PluginFile = Join-Path $PluginDir ($PluginName + ".py")
$BatchFile = Join-Path $PluginDir "batch_render.py"

function Write-Step([string]$Message) {
    Write-Output ("[gimp-logo] " + $Message)
}

function Resolve-GimpExecutable {
    $names = @("gimp-3.0.exe","gimp-console-3.0.exe","gimp.exe")
    foreach ($name in $names) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if ($cmd) { return $cmd.Source }
    }

    $candidates = @(
        "$env:ProgramFiles\GIMP 3\bin\gimp-3.0.exe",
        "$env:ProgramFiles\GIMP 3\bin\gimp-console-3.0.exe",
        "$env:ProgramFiles\GIMP 3\bin\gimp.exe",
        "$env:LOCALAPPDATA\Programs\GIMP 3\bin\gimp-3.0.exe"
    )
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path $candidate)) { return $candidate }
    }

    $roots = @(
        $env:ProgramFiles,
        [Environment]::GetFolderPath("ProgramFilesX86"),
        $env:LOCALAPPDATA
    )
    foreach ($root in $roots) {
        if (-not $root -or -not (Test-Path $root)) { continue }
        $found = Get-ChildItem -Path $root -Filter "gimp-3.0.exe" -File -Recurse -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($found) { return $found.FullName }
    }
    return $null
}

$gimp = Resolve-GimpExecutable
if (-not $gimp) {
    throw "GIMP 3 was not found. Install GIMP 3, then rerun the approved gimp-clintware-eclipse task."
}
Write-Step ("GIMP=" + $gimp)

New-Item -ItemType Directory -Force -Path $PluginDir | Out-Null

$pluginUrl = "$RepoRaw/projects/plugin-forge/presets/$PluginName/$PluginName.py"
$batchUrl = "$RepoRaw/projects/plugin-forge/presets/$PluginName/batch_render.py"

Write-Step "Downloading reviewed deterministic renderer from Clintware repo."
Invoke-WebRequest -Uri $pluginUrl -OutFile $PluginFile -UseBasicParsing
Invoke-WebRequest -Uri $batchUrl -OutFile $BatchFile -UseBasicParsing

if (-not (Test-Path $PluginFile) -or -not (Test-Path $BatchFile)) {
    throw "Renderer installation did not produce the expected files."
}

$pluginText = Get-Content -Raw -Path $PluginFile
if ($pluginText -notmatch 'PROCEDURE_NAME\s*=\s*"plug-in-clintware-eclipse-logo"') {
    throw "Downloaded renderer failed procedure identity validation."
}
if ($pluginText -match 'requests\.|urllib\.|openai|image[_-]?gen') {
    throw "Renderer validation rejected unexpected network/generative references."
}

$batchText = Get-Content -Raw -Path $BatchFile
if ($batchText -notmatch 'CLINTWARE_RENDER_OK') {
    throw "Batch renderer validation marker missing."
}

Write-Step ("Installed plugin=" + $PluginFile)
Write-Step "Launching GIMP and rendering a fresh 1600x1369 logo."

$batchNormalized = $BatchFile.Replace("\", "/")
$expression = "exec(open(r'$batchNormalized', encoding='utf-8').read())"

$proc = Start-Process -FilePath $gimp -ArgumentList @(
    "--console-messages",
    "--batch-interpreter=python-fu-eval",
    "-b",
    $expression
) -PassThru

Start-Sleep -Seconds 4
if ($proc.HasExited -and $proc.ExitCode -ne 0) {
    throw ("GIMP exited during startup with code " + $proc.ExitCode)
}

$pictureDir = Join-Path ([Environment]::GetFolderPath("MyPictures")) "Clintware"
Write-Step ("GIMP launched PID=" + $proc.Id)
Write-Step ("Expected XCF=" + (Join-Path $pictureDir "clintware-eclipse-deterministic.xcf"))
Write-Step ("Expected PNG=" + (Join-Path $pictureDir "clintware-eclipse-deterministic.png"))
Write-Step "The rendered document should now be visible in GIMP with editable layers."
exit 0

