# PowerShell equivalent of run-local.sh - use this if you're on Windows.
#
#   .\run-local.ps1
#   $env:MODEL=1; .\run-local.ps1     # model mode
#
# If execution policy blocks it:
#   powershell -ExecutionPolicy Bypass -File .\run-local.ps1

$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

$py = if (Get-Command py -ErrorAction SilentlyContinue) { "py" }
      elseif (Get-Command python -ErrorAction SilentlyContinue) { "python" }
      else { throw "No Python found. Install Python 3.10+ from python.org or the Store." }

Write-Host "==> Using $(& $py --version)"

$activate = ".venv\Scripts\Activate.ps1"
if (-not (Test-Path $activate)) {
    if (Test-Path ".venv") {
        Write-Host "==> Found an incomplete .venv, removing it"
        Remove-Item -Recurse -Force ".venv"
    }
    Write-Host "==> Creating .venv"
    & $py -m venv .venv
    if (-not (Test-Path $activate)) { throw "venv creation failed" }
}

Write-Host "==> Activating $activate"
. $activate

Write-Host "==> Installing dependencies"
python -m pip install --quiet --upgrade pip
python -m pip install --quiet -r requirements.txt

if ($env:MODEL -eq "1") {
    if (-not $env:AZURE_OPENAI_ENDPOINT) { throw "Set AZURE_OPENAI_ENDPOINT" }
    if (-not $env:AZURE_AI_MODEL_DEPLOYMENT_NAME) { throw "Set AZURE_AI_MODEL_DEPLOYMENT_NAME" }
    Write-Host "==> MODEL mode -> $env:AZURE_AI_MODEL_DEPLOYMENT_NAME @ $env:AZURE_OPENAI_ENDPOINT"
} else {
    Remove-Item Env:AZURE_AI_MODEL_DEPLOYMENT_NAME -ErrorAction SilentlyContinue
    Remove-Item Env:AZURE_OPENAI_ENDPOINT -ErrorAction SilentlyContinue
    Write-Host "==> ECHO mode (no model call)"
}

$port = if ($env:PORT) { $env:PORT } else { "8088" }
Write-Host "==> http://localhost:$port   docs: http://localhost:$port/docs   (Ctrl+C to stop)"
python -m uvicorn app:app --host 0.0.0.0 --port $port --reload
