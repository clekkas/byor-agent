# Start the agent first. Set BASE to override http://localhost:8088.
$ErrorActionPreference = 'Stop'
$base = if ($env:BASE) { $env:BASE } else { 'http://localhost:8088' }
& python (Join-Path $PSScriptRoot 'test_local.py') --base $base
exit $LASTEXITCODE
