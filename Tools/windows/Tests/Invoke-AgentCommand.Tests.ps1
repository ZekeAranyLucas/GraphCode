[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..\..")).Path
$wrapperPath = Join-Path $repoRoot "Tools\windows\Invoke-AgentCommand.ps1"
$pwshPath = (Get-Process -Id $PID).Path
$root = Join-Path ([IO.Path]::GetTempPath()) (
  "graphcode-agent-command-contract-" + [guid]::NewGuid().ToString("N"))
if (Test-Path -LiteralPath $root) {
  throw "Contract scratch path already exists: $root"
}
[void][IO.Directory]::CreateDirectory($root)

function Assert-Contract([bool] $condition, [string] $message) {
  if (-not $condition) { throw "RED: $message" }
}

function New-OutputArea([string] $name) {
  $path = Join-Path $root $name
  [void][IO.Directory]::CreateDirectory($path)
  return $path
}

function Write-TestScript([string] $path, [string] $content) {
  [IO.File]::WriteAllText($path, $content, [Text.UTF8Encoding]::new($false))
}

function Invoke-Wrapper(
    [string] $scriptPath,
    [string] $consolePath,
    [AllowEmptyCollection()][string[]] $childArguments = @(),
    [switch] $OmitArguments
  ) {
  $errorMessage = $null
  try {
    if ($OmitArguments) {
      & $wrapperPath -ScriptPath $scriptPath -ConsolePath $consolePath
    } else {
      & $wrapperPath -ScriptPath $scriptPath -ConsolePath $consolePath `
        -Arguments $childArguments
    }
  } catch {
    $errorMessage = $_.Exception.Message
  }
  return [pscustomobject]@{ ErrorMessage = $errorMessage }
}

$executed = 0
$contractPassed = $false
$captureVariable = "GRAPHCODE_AGENT_COMMAND_CAPTURE"
$exitVariable = "GRAPHCODE_AGENT_COMMAND_EXIT_CODE"
$oldCapture = [Environment]::GetEnvironmentVariable($captureVariable, "Process")
$oldExit = [Environment]::GetEnvironmentVariable($exitVariable, "Process")
$oldTemp = [Environment]::GetEnvironmentVariable("TEMP", "Process")
$oldTmp = [Environment]::GetEnvironmentVariable("TMP", "Process")
$successScript = Join-Path $root "success-child.ps1"
$childSource = @'
$VerbosePreference = "Continue"
$DebugPreference = "Continue"
$InformationPreference = "Continue"
$captured = [pscustomobject]@{
  arguments = [string[]]@($args)
  temp = [string]$env:TEMP
  tmp = [string]$env:TMP
  tempExists = [IO.Directory]::Exists($env:TEMP)
}
[IO.File]::WriteAllText(
  $env:GRAPHCODE_AGENT_COMMAND_CAPTURE,
  (ConvertTo-Json -InputObject $captured -Compress -Depth 4),
  [Text.UTF8Encoding]::new($false))
Write-Output "stdout-proof"
Write-Error "stderr-proof" -ErrorAction Continue
Write-Warning "warning-proof"
Write-Verbose "verbose-proof"
Write-Debug "debug-proof"
Write-Information "information-proof"
if ($env:GRAPHCODE_AGENT_COMMAND_EXIT_CODE) {
  exit [int]$env:GRAPHCODE_AGENT_COMMAND_EXIT_CODE
}
'@

try {
  Write-TestScript $successScript $childSource

  # Argument fidelity, all redirectable streams, the private child TEMP/TMP,
  # and marker hashes are checked against artifacts produced by this run.
  $area = New-OutputArea "success"
  $consolePath = Join-Path $area "console.txt"
  $capturePath = Join-Path $area "child.json"
  [Environment]::SetEnvironmentVariable($captureVariable, $capturePath, "Process")
  [Environment]::SetEnvironmentVariable($exitVariable, $null, "Process")
  $expectedArguments = @("", 'quoted "value"', "space value", "雪☃")
  $result = Invoke-Wrapper $successScript $consolePath $expectedArguments
  Assert-Contract (-not $result.ErrorMessage) "successful child was rejected: $($result.ErrorMessage)"
  Assert-Contract ([Environment]::GetEnvironmentVariable("TEMP", "Process") -ceq $oldTemp) `
    "wrapper did not restore process TEMP"
  Assert-Contract ([Environment]::GetEnvironmentVariable("TMP", "Process") -ceq $oldTmp) `
    "wrapper did not restore process TMP"

  $captured = Get-Content -LiteralPath $capturePath -Raw | ConvertFrom-Json
  $actualArguments = @($captured.arguments)
  Assert-Contract ($actualArguments.Count -eq $expectedArguments.Count) `
    "child received a different argument count"
  for ($index = 0; $index -lt $expectedArguments.Count; $index++) {
    Assert-Contract ([string]$actualArguments[$index] -ceq $expectedArguments[$index]) `
      "child argument $index was not forwarded exactly"
  }
  Assert-Contract ([string]$captured.temp -ceq [string]$captured.tmp) `
    "child TEMP and TMP differ"
  Assert-Contract ([bool]$captured.tempExists) "child TEMP/TMP directory was not real"
  Assert-Contract (
    ([string]$captured.temp).StartsWith(
      $area, [StringComparison]::OrdinalIgnoreCase)
  ) "child TEMP/TMP was not rooted in ConsolePath's output area"

  $consoleText = Get-Content -LiteralPath $consolePath -Raw
  foreach ($streamText in @(
      "stdout-proof", "stderr-proof", "warning-proof",
      "verbose-proof", "debug-proof", "information-proof"
    )) {
    Assert-Contract ($consoleText.Contains($streamText)) `
      "console did not retain stream output '$streamText'"
  }
  $markerPath = "$consolePath.exit.json"
  $marker = Get-Content -LiteralPath $markerPath -Raw | ConvertFrom-Json -DateKind String
  $expectedScriptHash = (Get-FileHash -LiteralPath $successScript -Algorithm SHA256).Hash.ToLowerInvariant()
  $expectedConsoleHash = (Get-FileHash -LiteralPath $consolePath -Algorithm SHA256).Hash.ToLowerInvariant()
  Assert-Contract ([int]$marker.exitCode -eq 0) "success marker has the wrong exit code"
  Assert-Contract ([string]$marker.scriptSha256 -ceq $expectedScriptHash) `
    "marker script hash does not match the actual script file"
  Assert-Contract ([string]$marker.consoleSha256 -ceq $expectedConsoleHash) `
    "marker console hash does not match the actual console file"
  $started = [DateTimeOffset]::Parse(
    [string]$marker.startedUtc, [Globalization.CultureInfo]::InvariantCulture,
    [Globalization.DateTimeStyles]::None)
  $ended = [DateTimeOffset]::Parse(
    [string]$marker.endedUtc, [Globalization.CultureInfo]::InvariantCulture,
    [Globalization.DateTimeStyles]::None)
  Assert-Contract ($started.Offset -eq [TimeSpan]::Zero -and
    $ended.Offset -eq [TimeSpan]::Zero -and $started -le $ended) `
    "marker timestamps are not ordered UTC values"
  $executed++

  # Both an omitted parameter and an explicit empty array are zero arguments.
  $area = New-OutputArea "zero-arguments-omitted"
  $capturePath = Join-Path $area "child.json"
  [Environment]::SetEnvironmentVariable($captureVariable, $capturePath, "Process")
  $result = Invoke-Wrapper $successScript (Join-Path $area "console.txt") `
    -OmitArguments
  Assert-Contract (-not $result.ErrorMessage) `
    "wrapper rejected an omitted zero-argument vector: $($result.ErrorMessage)"
  $captured = Get-Content -LiteralPath $capturePath -Raw | ConvertFrom-Json
  Assert-Contract (@($captured.arguments).Count -eq 0) `
    "omitted -Arguments was not forwarded as an empty vector"

  $area = New-OutputArea "zero-arguments-explicit-empty"
  $capturePath = Join-Path $area "child.json"
  [Environment]::SetEnvironmentVariable($captureVariable, $capturePath, "Process")
  $result = Invoke-Wrapper $successScript (Join-Path $area "console.txt") `
    ([string[]]@())
  Assert-Contract (-not $result.ErrorMessage) `
    "wrapper rejected an explicit empty -Arguments array: $($result.ErrorMessage)"
  $captured = Get-Content -LiteralPath $capturePath -Raw | ConvertFrom-Json
  Assert-Contract (@($captured.arguments).Count -eq 0) `
    "explicit empty -Arguments was not forwarded as an empty vector"
  $executed++

  # Existing console output is never replaced or used to launch the child.
  $area = New-OutputArea "existing-console"
  $consolePath = Join-Path $area "console.txt"
  [IO.File]::WriteAllText($consolePath, "preserve-console")
  $capturePath = Join-Path $area "child.json"
  [Environment]::SetEnvironmentVariable($captureVariable, $capturePath, "Process")
  $result = Invoke-Wrapper $successScript $consolePath $expectedArguments
  Assert-Contract ($result.ErrorMessage -match "ConsolePath already exists") `
    "existing console path was not refused"
  Assert-Contract ((Get-Content -LiteralPath $consolePath -Raw) -ceq "preserve-console") `
    "existing console path was changed"
  Assert-Contract (-not (Test-Path -LiteralPath $capturePath)) `
    "child ran despite an existing console path"
  $executed++

  # Existing marker output is likewise refused before the child starts.
  $area = New-OutputArea "existing-marker"
  $consolePath = Join-Path $area "console.txt"
  $markerPath = "$consolePath.exit.json"
  [IO.File]::WriteAllText($markerPath, "preserve-marker")
  $capturePath = Join-Path $area "child.json"
  [Environment]::SetEnvironmentVariable($captureVariable, $capturePath, "Process")
  $result = Invoke-Wrapper $successScript $consolePath $expectedArguments
  Assert-Contract ($result.ErrorMessage -match "Exit marker already exists") `
    "existing exit marker was not refused"
  Assert-Contract ((Get-Content -LiteralPath $markerPath -Raw) -ceq "preserve-marker") `
    "existing exit marker was changed"
  Assert-Contract (-not (Test-Path -LiteralPath $consolePath)) `
    "console was created despite an existing exit marker"
  Assert-Contract (-not (Test-Path -LiteralPath $capturePath)) `
    "child ran despite an existing exit marker"
  $executed++

  # Invalid source must fail parsing before creating outputs or launching.
  $area = New-OutputArea "parse-error"
  $invalidScript = Join-Path $area "invalid-child.ps1"
  $consolePath = Join-Path $area "console.txt"
  $capturePath = Join-Path $area "child.json"
  Write-TestScript $invalidScript "if ("
  [Environment]::SetEnvironmentVariable($captureVariable, $capturePath, "Process")
  $result = Invoke-Wrapper $invalidScript $consolePath
  Assert-Contract ($result.ErrorMessage -match "failed PowerShell parsing") `
    "invalid child source did not produce an explicit parse error"
  Assert-Contract (-not (Test-Path -LiteralPath $consolePath)) `
    "console was created for a parse failure"
  Assert-Contract (-not (Test-Path -LiteralPath "$consolePath.exit.json")) `
    "exit marker was created for a parse failure"
  Assert-Contract (-not (Test-Path -LiteralPath $capturePath)) `
    "child ran despite a parse failure"
  $executed++

  # A nonzero native child exit is recorded accurately and remains an error.
  $area = New-OutputArea "nonzero-exit"
  $consolePath = Join-Path $area "console.txt"
  $capturePath = Join-Path $area "child.json"
  [Environment]::SetEnvironmentVariable($captureVariable, $capturePath, "Process")
  [Environment]::SetEnvironmentVariable($exitVariable, "7", "Process")
  $result = Invoke-Wrapper $successScript $consolePath $expectedArguments
  Assert-Contract ($result.ErrorMessage -match "child exited with code 7") `
    "nonzero child exit was not surfaced explicitly"
  $marker = Get-Content -LiteralPath "$consolePath.exit.json" -Raw |
    ConvertFrom-Json -DateKind String
  Assert-Contract ([int]$marker.exitCode -eq 7) `
    "nonzero marker does not contain the actual child exit code"
  Assert-Contract ((Get-FileHash -LiteralPath $consolePath -Algorithm SHA256).Hash.ToLowerInvariant() -ceq
    [string]$marker.consoleSha256) "nonzero marker console hash is inaccurate"
  Assert-Contract ([Environment]::GetEnvironmentVariable("TEMP", "Process") -ceq $oldTemp) `
    "wrapper did not restore TEMP after child failure"
  Assert-Contract ([Environment]::GetEnvironmentVariable("TMP", "Process") -ceq $oldTmp) `
    "wrapper did not restore TMP after child failure"
  $executed++

  Assert-Contract ($executed -eq 6) "contract inventory did not execute all six cases"
  $contractPassed = $true
  Write-Output "Invoke-AgentCommand.Tests.ps1: PASS; executed=$executed; cases=argument-stream-marker,zero-arguments,existing-console,existing-marker,parse-failure,child-nonzero"
} finally {
  [Environment]::SetEnvironmentVariable($captureVariable, $oldCapture, "Process")
  [Environment]::SetEnvironmentVariable($exitVariable, $oldExit, "Process")
  [Environment]::SetEnvironmentVariable("TEMP", $oldTemp, "Process")
  [Environment]::SetEnvironmentVariable("TMP", $oldTmp, "Process")
  if ($contractPassed) {
    Remove-Item -LiteralPath $root -Recurse -Force
  } else {
    Write-Warning "Contract scratch preserved after failure: $root"
  }
}
