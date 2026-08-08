$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot

Push-Location $repo
try {
   python tests/integration.py
   if ($LASTEXITCODE -ne 0) {
      throw "Integration tests failed with exit code $LASTEXITCODE"
   }
}
finally {
   Pop-Location
}
