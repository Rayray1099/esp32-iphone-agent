param([string]$IdfPath = 'E:/tools/esp-idf-v5.5.2', [string]$Port, [switch]$Flash)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
python (Join-Path $PSScriptRoot 'bootstrap.py')
if ($LASTEXITCODE) { throw 'Dependency setup failed' }
python (Join-Path $PSScriptRoot 'bundle_web.py')
if ($LASTEXITCODE) { throw 'Web bundle failed' }
. (Join-Path $IdfPath 'export.ps1')
Push-Location (Join-Path $projectRoot 'hardware/idf')
try {
    idf.py build
    if ($LASTEXITCODE) { throw 'Firmware build failed' }
    if ($Flash) {
        if (!$Port) { throw 'Specify -Port COMx to flash the selected board' }
        idf.py -p $Port flash
        if ($LASTEXITCODE) { throw 'Flash failed' }
    }
} finally { Pop-Location }
