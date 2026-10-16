<#
.SYNOPSIS
  Runs one PowerShell command script and records its console and exit metadata.

.DESCRIPTION
  The exit marker is written to ConsolePath with ".exit.json" appended.
  TEMP and TMP point to a unique directory under ConsolePath's existing
  parent while the child starts; the wrapper restores its process values.
  The directory is per-run scratch, not a security boundary. Progress and
  host UI are not redirectable PowerShell streams, and this wrapper does
  not attest native process identity or child cleanup.

.PARAMETER ScriptPath
  PowerShell script file to parse and then run with pwsh -NoProfile -File.

.PARAMETER ConsolePath
  New output file for redirected PowerShell streams 1 through 6. Its parent
  directory must already exist and the file must not already exist.

.PARAMETER Arguments
  String-array arguments forwarded to the child. An omitted or empty array
  is a genuine zero-argument vector; individual empty strings are preserved.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [string] $ScriptPath,
  [Parameter(Mandatory)]
  [string] $ConsolePath,
  [AllowEmptyCollection()]
  [string[]] $Arguments = @()
)

$ErrorActionPreference = "Stop"

$scriptFullPath = [IO.Path]::GetFullPath($ScriptPath)
$consoleFullPath = [IO.Path]::GetFullPath($ConsolePath)
$consoleDirectory = [IO.Path]::GetDirectoryName($consoleFullPath)
$markerPath = "$consoleFullPath.exit.json"

if (-not (Test-Path -LiteralPath $scriptFullPath -PathType Leaf)) {
  throw "ScriptPath is not an existing file: $scriptFullPath"
}
if (-not (Test-Path -LiteralPath $consoleDirectory -PathType Container)) {
  throw "ConsolePath parent directory does not exist: $consoleDirectory"
}
if (Test-Path -LiteralPath $consoleFullPath) {
  throw "ConsolePath already exists: $consoleFullPath"
}
if (Test-Path -LiteralPath $markerPath) {
  throw "Exit marker already exists: $markerPath"
}

$tokens = $null
$parseErrors = $null
[void][Management.Automation.Language.Parser]::ParseFile(
  $scriptFullPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) {
  $messages = @($parseErrors | ForEach-Object { $_.Message }) -join "; "
  throw "Script failed PowerShell parsing: $messages"
}

$scriptSha256 = (Get-FileHash -LiteralPath $scriptFullPath -Algorithm SHA256).Hash.ToLowerInvariant()
$privateTempPath = Join-Path $consoleDirectory (
  ".agent-command-temp-" + [guid]::NewGuid().ToString("N"))
if (Test-Path -LiteralPath $privateTempPath) {
  throw "Private TEMP/TMP path already exists: $privateTempPath"
}
[void][IO.Directory]::CreateDirectory($privateTempPath)
if (-not (Test-Path -LiteralPath $privateTempPath -PathType Container)) {
  throw "Could not create private TEMP/TMP directory: $privateTempPath"
}

$pwshPath = (Get-Process -Id $PID).Path
$startedUtc = [DateTime]::UtcNow.ToString(
  "o", [Globalization.CultureInfo]::InvariantCulture)
$oldTemp = [Environment]::GetEnvironmentVariable("TEMP", "Process")
$oldTmp = [Environment]::GetEnvironmentVariable("TMP", "Process")
$childExitCode = $null
try {
  [Environment]::SetEnvironmentVariable("TEMP", $privateTempPath, "Process")
  [Environment]::SetEnvironmentVariable("TMP", $privateTempPath, "Process")
  & $pwshPath -NoProfile -File $scriptFullPath @Arguments *>&1 |
    Out-File -LiteralPath $consoleFullPath -NoClobber -Encoding utf8
  $childExitCode = $LASTEXITCODE
  if ($null -eq $childExitCode) {
    throw "The PowerShell child did not provide a native exit code"
  }
} finally {
  [Environment]::SetEnvironmentVariable("TEMP", $oldTemp, "Process")
  [Environment]::SetEnvironmentVariable("TMP", $oldTmp, "Process")
}

$endedUtc = [DateTime]::UtcNow.ToString(
  "o", [Globalization.CultureInfo]::InvariantCulture)
$consoleSha256 = (Get-FileHash -LiteralPath $consoleFullPath -Algorithm SHA256).Hash.ToLowerInvariant()
$marker = [pscustomobject]@{
  exitCode = [int]$childExitCode
  startedUtc = $startedUtc
  endedUtc = $endedUtc
  scriptSha256 = $scriptSha256
  consoleSha256 = $consoleSha256
}
$marker | ConvertTo-Json -Depth 3 |
  Out-File -LiteralPath $markerPath -NoClobber -Encoding utf8

if ($childExitCode -ne 0) {
  throw "PowerShell child exited with code $childExitCode; see $consoleFullPath"
}
