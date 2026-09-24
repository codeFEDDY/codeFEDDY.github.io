param(
  [string]$Endpoint = "wss://mcp.codefeddy.com/api/v1/quillgeist-lite/stream",
  [string]$RegistryUrl = "https://raw.githubusercontent.com/codeFEDDY/codeFEDDY.github.io/main/quillgeist-lite/tasks.json"
)

$ErrorActionPreference = "Stop"

$HomeDir = Join-Path $env:LOCALAPPDATA "Clintware\QuillgeistLite"
$CacheDir = Join-Path $HomeDir "cache"
$LogPath = Join-Path $HomeDir "runner.log"
$StatePath = Join-Path $HomeDir "state.json"
$RepoRaw = "https://raw.githubusercontent.com/codeFEDDY/codeFEDDY.github.io/main"

New-Item -ItemType Directory -Force -Path $HomeDir,$CacheDir | Out-Null

$script:RunnerSocket = $null
$script:RunnerDiagSeq = 0
$script:PendingDiagnostics = @()
$script:QQPromptVisible = $false
$script:QQInputBuffer = New-Object Text.StringBuilder
$script:QQReceiveBuffer = New-Object byte[] 65536
$script:QQReceiveStream = New-Object IO.MemoryStream
$script:QQReceiveTask = $null
$script:PendingQuestions = @{}
$script:LastQuestionPoll = [DateTime]::MinValue

function Queue-RunnerDiagnostic {
  param(
    [string]$Level,
    [string]$Message,
    [string]$Phase = "runner"
  )

  $script:RunnerDiagSeq++
  $entry = @{
    type = "runner_log"
    seq = $script:RunnerDiagSeq
    level = $Level
    phase = $Phase
    line = [string]$Message
    timestamp = (Get-Date).ToUniversalTime().ToString("o")
  }

  if ($script:RunnerSocket -and $script:RunnerSocket.State -eq [Net.WebSockets.WebSocketState]::Open) {
    try {
      Send-Json $script:RunnerSocket $entry
      return
    } catch {}
  }

  $script:PendingDiagnostics += ,$entry
}

function Flush-RunnerDiagnostics {
  if (-not $script:RunnerSocket -or $script:RunnerSocket.State -ne [Net.WebSockets.WebSocketState]::Open) { return }

  $pending = $script:PendingDiagnostics
  $script:PendingDiagnostics = @()

  foreach ($entry in $pending) {
    try {
      Send-Json $script:RunnerSocket $entry
    } catch {
      $script:PendingDiagnostics.Add($entry)
      break
    }
  }
}

function Test-QQAdministrator {
  try {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  } catch {
    return $false
  }
}

function Suspend-QQPrompt {
  if (-not $script:QQPromptVisible) { return }
  try {
    $width = [Math]::Max(20,[Console]::BufferWidth - 1)
    Write-Host (([string][char]13) + (" " * $width) + ([string][char]13)) -NoNewline
  } catch {
    Write-Host ""
  }
  $script:QQPromptVisible = $false
}

function Show-QQPrompt {
  if ($script:QQPromptVisible) { return }
  $mode = if (Test-QQAdministrator) { "admin" } else { "user" }
  Write-Host "qq" -ForegroundColor Cyan -NoNewline
  Write-Host ("(" + $mode + ")") -ForegroundColor White -NoNewline
  Write-Host "> " -ForegroundColor Cyan -NoNewline
  $existing = $script:QQInputBuffer.ToString()
  if ($existing) { Write-Host $existing -ForegroundColor White -NoNewline }
  $script:QQPromptVisible = $true
}

function Read-QQConsoleLine {
  try {
    if ([Console]::IsInputRedirected) { return [pscustomobject]@{Ready=$false;Line=$null} }
  } catch {
    return [pscustomobject]@{Ready=$false;Line=$null}
  }

  try {
    while ([Console]::KeyAvailable) {
      $key = [Console]::ReadKey($true)

      if ($key.Key -eq [ConsoleKey]::Enter) {
        $line = $script:QQInputBuffer.ToString()
        $null = $script:QQInputBuffer.Clear()
        Write-Host ""
        $script:QQPromptVisible = $false
        return [pscustomobject]@{Ready=$true;Line=$line}
      }

      if ($key.Key -eq [ConsoleKey]::Backspace) {
        if ($script:QQInputBuffer.Length -gt 0) {
          $script:QQInputBuffer.Remove($script:QQInputBuffer.Length-1,1) | Out-Null
          Write-Host (([string][char]8) + " " + ([string][char]8)) -NoNewline
        }
        continue
      }

      if ($key.Key -eq [ConsoleKey]::Escape) {
        Suspend-QQPrompt
        $null = $script:QQInputBuffer.Clear()
        Show-QQPrompt
        continue
      }

      if (($key.Modifiers -band [ConsoleModifiers]::Control) -and $key.Key -eq [ConsoleKey]::C) {
        Suspend-QQPrompt
        $null = $script:QQInputBuffer.Clear()
        Write-Host "^C" -ForegroundColor DarkYellow
        Show-QQPrompt
        continue
      }

      if (-not [char]::IsControl($key.KeyChar)) {
        $null = $script:QQInputBuffer.Append($key.KeyChar)
        Write-Host ([string]$key.KeyChar) -ForegroundColor White -NoNewline
      }
    }
  } catch {}

  return [pscustomobject]@{Ready=$false;Line=$null}
}

function Initialize-ClintwareTerminal {
  try {
    [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
    [Console]::BackgroundColor = [ConsoleColor]::Black
    [Console]::ForegroundColor = [ConsoleColor]::White
  } catch {}

  try {
    $raw = $Host.UI.RawUI
    $raw.BackgroundColor = "Black"
    $raw.ForegroundColor = "White"
    $mode = if (Test-QQAdministrator) { "ADMIN" } else { "USER" }
    $raw.WindowTitle = "CodeFEDDY qq [$mode]"

    $targetWidth = [Math]::Min(118,[Math]::Max(92,$raw.MaxPhysicalWindowSize.Width))
    if ($raw.BufferSize.Width -lt $targetWidth) {
      $buffer = $raw.BufferSize
      $buffer.Width = $targetWidth
      $raw.BufferSize = $buffer
    }

    if ($raw.WindowSize.Width -lt $targetWidth) {
      $window = $raw.WindowSize
      $window.Width = [Math]::Min($targetWidth,$raw.MaxPhysicalWindowSize.Width)
      $raw.WindowSize = $window
    }
  } catch {}

  try { Clear-Host } catch {}
}

function Write-ClintwareCentered {
  param(
    [string]$Text,
    [ConsoleColor]$Color = [ConsoleColor]::White
  )

  $width = 100
  try { $width = [Console]::WindowWidth } catch {}
  $pad = [Math]::Max(0,[int](($width - $Text.Length) / 2))
  Write-Host ((" " * $pad) + $Text) -ForegroundColor $Color
}

function Write-ClintwareSplitLine {
  param(
    [string]$Left,
    [string]$Center,
    [string]$Right,
    [ConsoleColor]$CenterColor = [ConsoleColor]::White
  )

  $raw = $Left + $Center + $Right
  $width = 100
  try { $width = [Console]::WindowWidth } catch {}
  $pad = [Math]::Max(0,[int](($width - $raw.Length) / 2))

  Write-Host (" " * $pad) -NoNewline
  Write-Host $Left -ForegroundColor Cyan -NoNewline
  Write-Host $Center -ForegroundColor $CenterColor -NoNewline
  Write-Host $Right -ForegroundColor Cyan
}

function Show-QuillgeistSplash {
  Initialize-ClintwareTerminal

  try { [Console]::CursorVisible = $false } catch {}
  try { Clear-Host } catch {}

  # The compact Clintware eclipse is deliberately the first visible content.
  # Keep it small enough to sit above the welcome text on ordinary terminal sizes.
  Write-Host ""
  Write-ClintwareCentered "        · · · · · · ·        " DarkCyan
  Write-ClintwareCentered "     · ·             · ·     " Cyan
  Write-ClintwareCentered "   ·      CLINTWARE™      ·   " White
  Write-ClintwareCentered "   ·       EST. 2026       ·   " DarkGray
  Write-ClintwareCentered "     · ·             · ·     " Cyan
  Write-ClintwareCentered "        · · · · · · ·        " DarkCyan
  Write-Host ""
  Write-ClintwareCentered "Q U I L L G E I S T   L I T E" White
  Write-ClintwareCentered "GO FURTHEST. ™" Cyan
  Write-Host ""
  Write-ClintwareCentered "LOCAL EXECUTION  //  CONTROL PLANE LINK" DarkCyan
  Write-ClintwareCentered "POWERSHELL  |  PYTHON  |  C" DarkCyan
  Write-Host ""

  try { [Console]::CursorVisible = $true } catch {}
}

function Write-Log {
  param([string]$Message,[string]$Level="INFO")

  Suspend-QQPrompt
  $stamp = (Get-Date).ToString("s")
  $line = "{0} [{1}] {2}" -f $stamp,$Level,$Message
  Add-Content -Path $LogPath -Value $line

  $labelColor = "Cyan"
  $messageColor = "Cyan"

  switch ($Level.ToUpperInvariant()) {
    "OK" {
      $labelColor = "White"
      $messageColor = "White"
    }
    "WARN" {
      $labelColor = "DarkYellow"
      $messageColor = "DarkYellow"
    }
    "ERROR" {
      $labelColor = "Red"
      $messageColor = "Red"
    }
    default {
      $labelColor = "Cyan"
      $messageColor = "Cyan"
    }
  }

  Write-Host $stamp -ForegroundColor DarkGray -NoNewline
  Write-Host (" [{0}] " -f $Level) -ForegroundColor $labelColor -NoNewline
  Write-Host $Message -ForegroundColor $messageColor

  try { Queue-RunnerDiagnostic $Level $Message "runner" } catch {}
  Show-QQPrompt
}

$mutex = New-Object System.Threading.Mutex($false, "Local\CodeFEDDYQQV2")
if (-not $mutex.WaitOne(0,$false)) {
  Write-Log "Another current-generation Quillgeist Lite runner is already active." "WARN"
  exit 0
}

function Get-Completed {
  if (-not (Test-Path $StatePath)) { return @{} }
  try {
    $s = Get-Content $StatePath -Raw | ConvertFrom-Json
    $map = @{}
    foreach ($p in $s.PSObject.Properties) { $map[$p.Name] = $p.Value }
    return $map
  } catch {
    return @{}
  }
}

function Save-Completed {
  param([hashtable]$Map)
  $copy = @{}
  $keys = @($Map.Keys)
  if ($keys.Count -gt 200) { $keys = $keys[($keys.Count-200)..($keys.Count-1)] }
  foreach ($k in $keys) { $copy[$k] = $Map[$k] }
  $copy | ConvertTo-Json -Depth 10 | Set-Content -Path $StatePath -Encoding UTF8
}

function Get-GitHubToken {
  if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    throw "GitHub CLI (gh) is required. Run the Quillgeist Lite installer again."
  }

  gh auth status 2>$null | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "GitHub CLI is not authenticated." }

  $login = (gh api user --jq .login).Trim()
  if ($LASTEXITCODE -ne 0 -or $login.ToLowerInvariant() -ne "codeFEDDY") {
    throw "Expected GitHub identity codeFEDDY. Current identity: $login"
  }

  $token = (gh auth token).Trim()
  if (-not $token) { throw "GitHub CLI did not return an authentication token." }
  return $token
}

function Get-Registry {
  $registry = Invoke-RestMethod -Uri $RegistryUrl -Headers @{"Cache-Control"="no-cache"}
  if (-not $registry.tasks) { throw "Quillgeist Lite task registry is invalid." }
  return $registry
}

function Send-Json {
  param(
    [System.Net.WebSockets.ClientWebSocket]$Socket,
    [object]$Value
  )

  $json = $Value | ConvertTo-Json -Depth 12 -Compress
  $bytes = [Text.Encoding]::UTF8.GetBytes($json)
  $seg = [System.ArraySegment[byte]]::new([byte[]]$bytes,0,$bytes.Length)
  $null = $Socket.SendAsync(
    $seg,
    [Net.WebSockets.WebSocketMessageType]::Text,
    $true,
    [Threading.CancellationToken]::None
  ).GetAwaiter().GetResult()
}

function Reset-QQReceiveState {
  try { $script:QQReceiveStream.SetLength(0) } catch {}
  $script:QQReceiveTask = $null
}

function Poll-ReceiveJson {
  param([System.Net.WebSockets.ClientWebSocket]$Socket)

  if ($null -eq $script:QQReceiveTask) {
    $seg = [System.ArraySegment[byte]]::new([byte[]]$script:QQReceiveBuffer,0,$script:QQReceiveBuffer.Length)
    $script:QQReceiveTask = $Socket.ReceiveAsync(
      $seg,
      [Threading.CancellationToken]::None
    )
  }

  if (-not $script:QQReceiveTask.IsCompleted) {
    return [pscustomobject]@{State="pending";Message=$null}
  }

  $r = $script:QQReceiveTask.GetAwaiter().GetResult()
  $script:QQReceiveTask = $null

  if ($r.MessageType -eq [Net.WebSockets.WebSocketMessageType]::Close) {
    Reset-QQReceiveState
    return [pscustomobject]@{State="closed";Message=$null}
  }

  $script:QQReceiveStream.Write($script:QQReceiveBuffer,0,$r.Count)
  if ($script:QQReceiveStream.Length -gt 1048576) {
    Reset-QQReceiveState
    throw "Incoming Quillgeist Lite message exceeded 1 MB."
  }

  if (-not $r.EndOfMessage) {
    return [pscustomobject]@{State="pending";Message=$null}
  }

  $text = [Text.Encoding]::UTF8.GetString($script:QQReceiveStream.ToArray())
  $script:QQReceiveStream.SetLength(0)
  return [pscustomobject]@{State="message";Message=($text | ConvertFrom-Json)}
}

function Find-Task {
  param([object]$Registry,[string]$TaskId)
  foreach ($p in $Registry.tasks.PSObject.Properties) {
    if ($p.Name -eq $TaskId) { return $p.Value }
  }
  return $null
}

function Redact-LogLine {
  param([string]$Line)
  if ($null -eq $Line) { return "" }

  $s = [string]$Line
  $patterns = @(
    '(?i)(client_secret|refresh_token|access_token|authorization|api[_-]?key|password)\s*[:=]\s*([^\s,;]+)',
    'gh[pousr]_[A-Za-z0-9_]{20,}',
    'github_pat_[A-Za-z0-9_]{20,}',
    'ya29\.[A-Za-z0-9._-]+'
  )

  foreach ($pattern in $patterns) {
    $s = [regex]::Replace($s,$pattern,'$1=[REDACTED]')
  }

  if ($s.Length -gt 4000) { $s = $s.Substring(0,4000) + " ...[truncated]" }
  return $s
}

function Emit-TaskLine {
  param(
    [System.Net.WebSockets.ClientWebSocket]$Socket,
    [object]$Job,
    [ref]$Sequence,
    [System.Collections.Generic.List[string]]$Captured,
    [string]$Line,
    [string]$Phase
  )

  $safe = Redact-LogLine $Line
  if (-not $safe) { return }

  $Sequence.Value++
  $Captured.Add("[$Phase] $safe")

  $displayColor = "White"
  if ($safe -match '(?i)\\b(error|failed|fatal|exception|denied)\\b') {
    $displayColor = "Red"
  }
  elseif ($safe -match '(?i)\\b(warn|warning|retry|degraded)\\b') {
    $displayColor = "DarkYellow"
  }
  elseif ($safe -match '(?i)\\b(ok|passed|success|ready|connected|complete|completed)\\b') {
    $displayColor = "Cyan"
  }
  elseif ($Phase -eq "compile") {
    $displayColor = "DarkCyan"
  }

  Suspend-QQPrompt
  Write-Host $safe -ForegroundColor $displayColor
  Show-QQPrompt

  if ($Socket -and $Socket.State -eq [Net.WebSockets.WebSocketState]::Open) {
    Send-Json $Socket @{
      type = "log"
      job_id = [string]$Job.job_id
      task_id = [string]$Job.task_id
      seq = $Sequence.Value
      phase = $Phase
      line = $safe
      timestamp = (Get-Date).ToUniversalTime().ToString("o")
    }
  }
}

function Invoke-ExternalStreaming {
  param(
    [string]$FilePath,
    [string[]]$Arguments,
    [System.Net.WebSockets.ClientWebSocket]$Socket,
    [object]$Job,
    [ref]$Sequence,
    [System.Collections.Generic.List[string]]$Captured,
    [string]$Phase
  )

  $global:LASTEXITCODE = 0
  & $FilePath @Arguments *>&1 | ForEach-Object {
    Emit-TaskLine $Socket $Job $Sequence $Captured ([string]$_) $Phase
  }

  $code = $LASTEXITCODE
  if ($null -eq $code) { $code = 0 }
  return [int]$code
}

function Get-TaskArguments {
  param([object]$Task,[object]$Job,[string]$Runtime)

  $allowed = @($Task.parameters)
  $args = New-Object System.Collections.Generic.List[string]

  if ($Job.args) {
    foreach ($p in $Job.args.PSObject.Properties) {
      if ($allowed -notcontains $p.Name) {
        throw "Argument '$($p.Name)' is not allowed for task '$($Job.task_id)'."
      }

      if ($Runtime -eq "powershell") {
        $args.Add("-" + $p.Name)
        $args.Add([string]$p.Value)
      } else {
        $args.Add("--" + $p.Name)
        $args.Add([string]$p.Value)
      }
    }
  }

  return $args.ToArray()
}

function Resolve-Python {
  foreach ($candidate in @("python","python3","py")) {
    $cmd = Get-Command $candidate -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
  }
  throw "Python runtime not found. Register/run an approved Python-runtime setup task, then retry."
}

function Resolve-CCompiler {
  foreach ($candidate in @("clang","gcc","cl")) {
    $cmd = Get-Command $candidate -ErrorAction SilentlyContinue
    if ($cmd) { return @{Name=$candidate;Path=$cmd.Source} }
  }
  throw "C compiler not found. Run the approved ensure-c-runtime task, then retry the C task."
}

function Get-QQLocalTokens {
  param([string]$Text)
  $tokens = New-Object System.Collections.Generic.List[string]
  foreach ($m in [regex]::Matches([string]$Text,'(?:"([^"]*)"|''([^'']*)''|(\S+))')) {
    if ($m.Groups[1].Success) { $tokens.Add($m.Groups[1].Value) }
    elseif ($m.Groups[2].Success) { $tokens.Add($m.Groups[2].Value) }
    else { $tokens.Add($m.Groups[3].Value) }
  }
  return $tokens.ToArray()
}

function Show-QQHelp {
  Suspend-QQPrompt
  Write-Host ""
  Write-Host "QQ LOCAL CONSOLE" -ForegroundColor White
  Write-Host "  help                         Show this command reference." -ForegroundColor Cyan
  Write-Host "  status                       Show local runner, service, and admin state." -ForegroundColor Cyan
  Write-Host "  tasks                        List reviewed qq tasks." -ForegroundColor Cyan
  Write-Host "  <natural language>           Relay a question/instruction to Clintware for an LLM response." -ForegroundColor Cyan
  Write-Host "  ask <text>                   Explicitly relay a question/instruction." -ForegroundColor Cyan
  Write-Host "  run <task> [Name=Value ...]  Run an allowlisted task locally." -ForegroundColor Cyan
  Write-Host "  jira                         Connect/reconnect Jira." -ForegroundColor Cyan
  Write-Host "  doctor                       Run Clintware local diagnostics." -ForegroundColor Cyan
  Write-Host "  update                       Update qq from Clintware source." -ForegroundColor Cyan
  Write-Host "  admin                        Upgrade/reopen qq as the supervised admin console." -ForegroundColor Cyan
  Write-Host "  reconnect                    Reconnect the Control Plane channel." -ForegroundColor Cyan
  Write-Host "  clear                        Clear the terminal." -ForegroundColor Cyan
  Write-Host "  ! <PowerShell>               Local-only admin shell escape." -ForegroundColor DarkYellow
  Write-Host ""
  Write-Host "Natural-language input is relayed through the CodeFEDDY Control Plane. Remote MCP callers still cannot send arbitrary shell commands; the ! escape exists only for text physically entered in this local console." -ForegroundColor DarkGray
  Write-Host ""
  Show-QQPrompt
}

function Show-QQStatus {
  Suspend-QQPrompt
  $admin = Test-QQAdministrator
  $socketState = if ($script:RunnerSocket) { [string]$script:RunnerSocket.State } else { "Disconnected" }
  $service = Get-Service -Name "CodeFEDDYQQHealth" -ErrorAction SilentlyContinue

  Write-Host ""
  Write-Host "QQ STATUS" -ForegroundColor White
  Write-Host ("  Privilege     : " + $(if($admin){"ADMIN"}else{"STANDARD"})) -ForegroundColor $(if($admin){"Cyan"}else{"DarkYellow"})
  Write-Host ("  Control Plane : " + $socketState) -ForegroundColor Cyan
  Write-Host ("  Health service: " + $(if($service){$service.Status}else{"not installed"})) -ForegroundColor Cyan
  Write-Host ("  Machine       : " + $env:COMPUTERNAME) -ForegroundColor DarkGray
  Write-Host ("  PowerShell    : " + $PSVersionTable.PSVersion.ToString() + " / " + $PSVersionTable.PSEdition) -ForegroundColor DarkGray
  Write-Host ("  User          : " + [Security.Principal.WindowsIdentity]::GetCurrent().Name) -ForegroundColor DarkGray
  Write-Host ""
  Show-QQPrompt
}

function Invoke-QQLocalTask {
  param(
    [string]$TaskId,
    [hashtable]$Arguments = @{}
  )

  $registry = Get-Registry
  if (-not (Find-Task $registry $TaskId)) {
    Suspend-QQPrompt
    Write-Host ("Unknown qq task: " + $TaskId) -ForegroundColor Red
    Show-QQPrompt
    return
  }

  $job = [pscustomobject]@{
    job_id = "local-" + [Guid]::NewGuid().ToString("n")
    task_id = $TaskId
    args = [pscustomobject]$Arguments
    objective = "Local qq console"
  }

  Suspend-QQPrompt
  Write-Host ("LOCAL TASK // " + $TaskId) -ForegroundColor Cyan
  try {
    $result = Invoke-AllowlistedTask $job $null
    $level = if ($result.status -eq "passed") { "OK" } else { "ERROR" }
    Write-Log ("Local task {0} finished with status {1}" -f $TaskId,$result.status) $level
    if ($result.output) {
      Suspend-QQPrompt
      Write-Host "--- RESULT ---" -ForegroundColor DarkCyan
      Write-Host ([string]$result.output) -ForegroundColor White
    }
  } catch {
    Write-Log ("Local task failed: " + $_.Exception.Message) "ERROR"
  }
  Show-QQPrompt
}

function Invoke-QQLocalShell {
  param([string]$Command)

  if (-not $Command) {
    Suspend-QQPrompt
    Write-Host "Usage: ! <PowerShell command>" -ForegroundColor DarkYellow
    Show-QQPrompt
    return
  }

  Suspend-QQPrompt
  $mode = if (Test-QQAdministrator) { "ADMIN" } else { "STANDARD" }
  Write-Host ("LOCAL " + $mode + " POWERSHELL // " + $Command) -ForegroundColor DarkYellow

  $ps = Get-Command pwsh -ErrorAction SilentlyContinue
  if (-not $ps) { $ps = Get-Command powershell -ErrorAction Stop }

  try {
    & $ps.Source -NoProfile -ExecutionPolicy Bypass -Command $Command *>&1 | ForEach-Object {
      Write-Host (Redact-LogLine ([string]$_)) -ForegroundColor White
    }
    if ($LASTEXITCODE -ne 0) {
      Write-Host ("Exit code: " + $LASTEXITCODE) -ForegroundColor Red
    }
  } catch {
    Write-Host (Redact-LogLine $_.Exception.Message) -ForegroundColor Red
  }

  Show-QQPrompt
}

function Send-QQQuestion {
  param([string]$Text)

  $Text = ([string]$Text).Trim()
  if (-not $Text) { Show-QQPrompt; return }

  # Natural-language relay follows the same local redaction boundary as task logs.
  # Obvious credential/token assignments are replaced before text leaves Windows.
  $Text = Redact-LogLine $Text

  if (-not $script:RunnerSocket -or $script:RunnerSocket.State -ne [Net.WebSockets.WebSocketState]::Open) {
    Suspend-QQPrompt
    Write-Host "RELAY OFFLINE // Control Plane is not connected yet." -ForegroundColor DarkYellow
    Show-QQPrompt
    return
  }

  $questionId = [Guid]::NewGuid().ToString("n")
  $script:PendingQuestions[$questionId] = @{
    text = $Text
    created_at = (Get-Date).ToUniversalTime().ToString("o")
  }

  Send-Json $script:RunnerSocket @{
    type = "question"
    protocol = "clintware-quillgeist-lite-interactive/v1"
    question_id = $questionId
    runner_id = $env:COMPUTERNAME
    text = $Text
    cwd = $(try { (Get-Location).Path } catch { "" })
    shell = ("PowerShell " + $PSVersionTable.PSVersion.ToString())
    timestamp = (Get-Date).ToUniversalTime().ToString("o")
  }

  Suspend-QQPrompt
  Write-Host "RELAY" -ForegroundColor White -NoNewline
  Write-Host (" // " + $questionId.Substring(0,8) + " -> Clintware") -ForegroundColor Cyan
  Show-QQPrompt
}

function Show-QQAnswer {
  param([object]$Message)

  $questionId = [string]$Message.question_id
  $answer = [string]$Message.answer

  Suspend-QQPrompt
  Write-Host ""
  Write-Host "QUILLGEIST" -ForegroundColor White -NoNewline
  Write-Host (" // " + $(if($questionId.Length -ge 8){$questionId.Substring(0,8)}else{$questionId})) -ForegroundColor Cyan
  Write-Host $answer -ForegroundColor White
  Write-Host ""

  if ($questionId) {
    $script:PendingQuestions.Remove($questionId)
    try {
      Send-Json $script:RunnerSocket @{
        type = "answer_ack"
        question_id = $questionId
        runner_id = $env:COMPUTERNAME
        timestamp = (Get-Date).ToUniversalTime().ToString("o")
      }
    } catch {}
  }

  Show-QQPrompt
}

function Invoke-QQLocalCommand {
  param([string]$Line)

  $line = ([string]$Line).Trim()
  if (-not $line) { Show-QQPrompt; return }

  if ($line.StartsWith("!")) {
    Invoke-QQLocalShell ($line.Substring(1).Trim())
    return
  }

  $lower = $line.ToLowerInvariant()

  if ($lower.StartsWith("ask ")) {
    Send-QQQuestion ($line.Substring(4).Trim())
    return
  }

  switch ($lower) {
    "help" { Show-QQHelp; return }
    "?" { Show-QQHelp; return }
    "status" { Show-QQStatus; return }
    "tasks" {
      Suspend-QQPrompt
      $registry = Get-Registry
      Write-Host ""
      Write-Host "QQ REVIEWED TASKS" -ForegroundColor White
      foreach ($p in $registry.tasks.PSObject.Properties) {
        Write-Host ("  " + $p.Name) -ForegroundColor Cyan -NoNewline
        Write-Host ("  // " + [string]$p.Value.title) -ForegroundColor DarkGray
      }
      Write-Host ""
      Show-QQPrompt
      return
    }
    "jira" { Invoke-QQLocalTask "connect-jira"; return }
    "connect jira" { Invoke-QQLocalTask "connect-jira"; return }
    "connect-jira" { Invoke-QQLocalTask "connect-jira"; return }
    "doctor" { Invoke-QQLocalTask "clintware-doctor"; return }
    "update" { Invoke-QQLocalTask "self-update"; return }
    "update qq" { Invoke-QQLocalTask "self-update"; return }
    "admin" { Invoke-QQLocalTask "bootstrap-admin-console"; return }
    "admin qq" { Invoke-QQLocalTask "bootstrap-admin-console"; return }
    "clear" {
      try { Clear-Host } catch {}
      Show-QuillgeistSplash
      Show-QQPrompt
      return
    }
    "reconnect" {
      Write-Log "Local reconnect requested." "WARN"
      try { if ($script:RunnerSocket) { $script:RunnerSocket.Abort() } } catch {}
      return
    }
  }

  if ($lower.StartsWith("run ")) {
    $tokens = @(Get-QQLocalTokens $line.Substring(4).Trim())
    if ($tokens.Count -lt 1) {
      Suspend-QQPrompt
      Write-Host "Usage: run <task> [Name=Value ...]" -ForegroundColor DarkYellow
      Show-QQPrompt
      return
    }

    $taskId = [string]$tokens[0]
    $args = @{}
    foreach ($token in $tokens | Select-Object -Skip 1) {
      $idx = $token.IndexOf("=")
      if ($idx -le 0) {
        Suspend-QQPrompt
        Write-Host ("Invalid task argument '" + $token + "'. Use Name=Value.") -ForegroundColor Red
        Show-QQPrompt
        return
      }
      $args[$token.Substring(0,$idx)] = $token.Substring($idx+1)
    }

    Invoke-QQLocalTask $taskId $args
    return
  }

  try {
    $registry = Get-Registry
    if (Find-Task $registry $line) {
      Invoke-QQLocalTask $line
      return
    }
  } catch {}

  Send-QQQuestion $line
}

function Invoke-AllowlistedTask {
  param(
    [object]$Job,
    [System.Net.WebSockets.ClientWebSocket]$Socket
  )

  $registry = Get-Registry
  $task = Find-Task $registry ([string]$Job.task_id)

  if (-not $task) {
    throw "Task '$($Job.task_id)' is not in the local allowlist."
  }

  $runtime = ([string]$task.runtime).ToLowerInvariant()
  if (-not $runtime) { $runtime = "powershell" }
  if (@("powershell","python","c") -notcontains $runtime) {
    throw "Task runtime '$runtime' is not supported."
  }

  $scriptPath = [string]$task.script
  if ($scriptPath.Contains("..") -or $scriptPath.StartsWith("/") -or $scriptPath.StartsWith("\")) {
    throw "Task script path is invalid."
  }

  $requiredExtension = @{
    powershell = ".ps1"
    python = ".py"
    c = ".c"
  }[$runtime]

  if (-not $scriptPath.EndsWith($requiredExtension,[StringComparison]::OrdinalIgnoreCase)) {
    throw "Task '$($Job.task_id)' runtime '$runtime' requires a $requiredExtension source file."
  }

  $safeName = ([string]$Job.task_id -replace '[^A-Za-z0-9._-]','_')
  $localSource = Join-Path $CacheDir ($safeName + $requiredExtension)

  Invoke-WebRequest -Uri ($RepoRaw + "/" + $scriptPath) -OutFile $localSource -UseBasicParsing
  if (-not (Test-Path $localSource)) {
    throw "Could not download task source '$scriptPath'."
  }

  $taskArgs = Get-TaskArguments $task $Job $runtime
  Write-Log ("Running task {0} [{1}] ({2})" -f $Job.task_id,$runtime,$scriptPath)

  $started = Get-Date
  $captured = New-Object System.Collections.Generic.List[string]
  $seq = 0
  $code = 1

  if ($runtime -eq "powershell") {
    $ps = (Get-Command pwsh -ErrorAction SilentlyContinue)
    if (-not $ps) { $ps = Get-Command powershell -ErrorAction Stop }
    $invokeArgs = @("-NoProfile","-ExecutionPolicy","Bypass","-File",$localSource) + $taskArgs
    $code = Invoke-ExternalStreaming $ps.Source $invokeArgs $Socket $Job ([ref]$seq) $captured "run"
  }
  elseif ($runtime -eq "python") {
    $python = Resolve-Python
    $invokeArgs = @($localSource) + $taskArgs
    $code = Invoke-ExternalStreaming $python $invokeArgs $Socket $Job ([ref]$seq) $captured "run"
  }
  elseif ($runtime -eq "c") {
    $compiler = Resolve-CCompiler
    $exePath = Join-Path $CacheDir ($safeName + ".exe")

    if ($compiler.Name -eq "cl") {
      $compileArgs = @("/nologo","/W3","/O2","/Fe:$exePath",$localSource)
    } else {
      $compileArgs = @("-std=c11","-Wall","-Wextra","-O2",$localSource,"-o",$exePath)
    }

    $compileCode = Invoke-ExternalStreaming $compiler.Path $compileArgs $Socket $Job ([ref]$seq) $captured "compile"
    if ($compileCode -ne 0) {
      $code = $compileCode
    } else {
      $code = Invoke-ExternalStreaming $exePath $taskArgs $Socket $Job ([ref]$seq) $captured "run"
    }
  }

  $duration = [int]((Get-Date)-$started).TotalMilliseconds
  $output = ($captured -join [Environment]::NewLine)

  if ($output.Length -gt 40000) {
    $output = $output.Substring($output.Length-40000)
  }

  return @{
    type = "result"
    job_id = [string]$Job.job_id
    task_id = [string]$Job.task_id
    runtime = $runtime
    status = $(if($code -eq 0){"passed"}else{"failed"})
    exit_code = [int]$code
    duration_ms = $duration
    output = $output
    log_lines = $seq
    completed_at = (Get-Date).ToUniversalTime().ToString("o")
  }
}

$completed = Get-Completed

try {
  Show-QuillgeistSplash
} catch {
  Write-Log ("Splash error: " + $_.Exception.Message) "ERROR"
}

Write-Log "CodeFEDDY qq starting."
Write-Log ("Runtime host: PowerShell " + $PSVersionTable.PSVersion.ToString() + " / " + $PSVersionTable.PSEdition + ".")
Write-Log "Runtimes enabled: PowerShell, Python, C."
Write-Log "Interactive relay mode: local questions route through the CodeFEDDY Control Plane."

try {
  while ($true) {
    $ws = $null

    try {
      $token = Get-GitHubToken
      $ws = New-Object System.Net.WebSockets.ClientWebSocket
      $ws.Options.SetRequestHeader("Authorization","Bearer $token")
      $ws.Options.SetRequestHeader("X-Quillgeist-Runner-Id",$env:COMPUTERNAME)

      $null = $ws.ConnectAsync(
        [Uri]$Endpoint,
        [Threading.CancellationToken]::None
      ).GetAwaiter().GetResult()

      $script:RunnerSocket = $ws

      Send-Json $ws @{
        type = "hello"
        runner_id = $env:COMPUTERNAME
        version = "1.5.1"
        runtimes = @("powershell","python","c")
        capabilities = @("interactive_relay","question_poll","allowlisted_tasks","local_shell_escape")
      }

      Flush-RunnerDiagnostics
      Write-Log "Connected to CodeFEDDY Control Plane." "OK"

      Write-Log "Interactive relay channel initialized." "OK"

      Write-Host ""
      Write-Host "  " -NoNewline
      Write-Host "READY" -ForegroundColor White -NoNewline
      Write-Host " // CONTROL PLANE LINK ACTIVE" -ForegroundColor Cyan
      Write-Host ""
      Write-Host "  Interactive local console enabled. Type " -ForegroundColor DarkGray -NoNewline
      Write-Host "help" -ForegroundColor Cyan -NoNewline
      Write-Host " or use " -ForegroundColor DarkGray -NoNewline
      Write-Host "! <PowerShell>" -ForegroundColor DarkYellow -NoNewline
      Write-Host " for a local-only shell command." -ForegroundColor DarkGray
      Write-Host ""
      Show-QQPrompt

      while ($ws.State -eq [Net.WebSockets.WebSocketState]::Open) {
        $localInput = Read-QQConsoleLine
        if ($localInput.Ready) {
          Invoke-QQLocalCommand ([string]$localInput.Line)
        }

        if (((Get-Date) - $script:LastQuestionPoll).TotalSeconds -ge 5) {
          try {
            Send-Json $ws @{
              type = "question_poll"
              runner_id = $env:COMPUTERNAME
              timestamp = (Get-Date).ToUniversalTime().ToString("o")
            }
            $script:LastQuestionPoll = Get-Date
          } catch {}
        }

        $incoming = Poll-ReceiveJson $ws
        if ($incoming.State -eq "pending") {
          Start-Sleep -Milliseconds 35
          continue
        }
        if ($incoming.State -eq "closed") { break }
        $msg = $incoming.Message
        if ($null -eq $msg) {
          Start-Sleep -Milliseconds 35
          continue
        }

        if ($msg.type -eq "ping") {
          Send-Json $ws @{
            type = "pong"
            time = (Get-Date).ToUniversalTime().ToString("o")
          }
          continue
        }

        if ($msg.type -eq "question_ack") {
          Suspend-QQPrompt
          $qid = [string]$msg.question_id
          Write-Host "RELAY QUEUED" -ForegroundColor DarkCyan -NoNewline
          Write-Host (" // " + $(if($qid.Length -ge 8){$qid.Substring(0,8)}else{$qid})) -ForegroundColor DarkGray
          Show-QQPrompt
          continue
        }

        if ($msg.type -eq "answer") {
          Show-QQAnswer $msg
          continue
        }

        if ($msg.type -eq "question_status") {
          continue
        }

        if ($msg.type -ne "job" -or -not $msg.job) {
          continue
        }

        $job = $msg.job
        $jobId = [string]$job.job_id

        if ($completed.ContainsKey($jobId)) {
          Write-Log "Duplicate job $jobId ignored; returning the prior result." "WARN"
          Send-Json $ws $completed[$jobId]
          continue
        }

        Send-Json $ws @{
          type = "ack"
          job_id = $jobId
          status = "started"
          started_at = (Get-Date).ToUniversalTime().ToString("o")
        }

        try {
          $result = Invoke-AllowlistedTask $job $ws
        } catch {
          $result = @{
            type = "result"
            job_id = $jobId
            task_id = [string]$job.task_id
            status = "failed"
            exit_code = 1
            duration_ms = 0
            output = $_.Exception.Message
            completed_at = (Get-Date).ToUniversalTime().ToString("o")
          }

          Write-Log $_.Exception.Message "ERROR"
        }

        $completed[$jobId] = $result
        Save-Completed $completed
        Send-Json $ws $result

        $level = if ($result.status -eq "passed") { "OK" } else { "ERROR" }
        Write-Log ("Job {0} finished with status {1}" -f $jobId,$result.status) $level
      }
    } catch {
      Write-Log ("Connection error: " + $_.Exception.Message) "WARN"
      Queue-RunnerDiagnostic "WARN" ($_.Exception.ToString()) "connection"
      try {
        Add-Content -Path $LogPath -Value ("FULL_EXCEPTION " + $_.Exception.ToString())
      } catch {}
    } finally {
      $script:RunnerSocket = $null
      Reset-QQReceiveState
      if ($ws) {
        try { $ws.Dispose() } catch {}
      }
    }

    Write-Log "Disconnected. Reconnecting in 5 seconds..." "WARN"
    Start-Sleep -Seconds 5
  }
} finally {
  try { $mutex.ReleaseMutex() } catch {}
  $mutex.Dispose()
}

