# Run from any directory. Set ZIG to select a Zig 0.16.0 executable.
[CmdletBinding()]
param([string]$ZigPath = $env:ZIG)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($ZigPath)) { $ZigPath = 'zig' }
$zigExe = (Get-Command -Name $ZigPath -CommandType Application -ErrorAction Stop).Source
$zigVersion = & $zigExe version
if ($LASTEXITCODE -ne 0 -or $zigVersion.Trim() -ne '0.16.0') {
    throw 'Validation requires Zig 0.16.0. Set ZIG or pass -ZigPath to its executable.'
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$logRoot = Join-Path $repoRoot 'zig-out/validation/windows'
New-Item -ItemType Directory -Path $logRoot -Force | Out-Null

function Invoke-ZigCheck {
    param([string]$Name, [string[]]$Arguments)
    Write-Host "Running $Name"
    $logPath = Join-Path $logRoot "$Name.log"
    $savedPreference = $ErrorActionPreference
    try {
        # Windows PowerShell treats native stderr as ErrorRecords. Preserve
        # warnings in the log and decide success using the native exit code.
        $ErrorActionPreference = 'Continue'
        & $zigExe @Arguments 2>&1 | ForEach-Object { "$_" } | Tee-Object -FilePath $logPath
        $checkExit = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $savedPreference
    }
    if ($checkExit -ne 0) { throw "$Name failed (exit $checkExit). See $logPath" }
}

Push-Location -LiteralPath $repoRoot
try {
    foreach ($mode in @('Debug', 'ReleaseSafe')) {
        Invoke-ZigCheck "$mode-build" @('build', '-Dfrontend=both', "-Doptimize=$mode", '--summary', 'all')
        Invoke-ZigCheck "$mode-core" @('build', 'test', "-Doptimize=$mode", '--summary', 'all')
        Invoke-ZigCheck "$mode-gui" @('build', 'test-gui', "-Doptimize=$mode", '--summary', 'all')
    }
    Write-Host "Validation passed. Logs: $logRoot"
} finally {
    Pop-Location
}
