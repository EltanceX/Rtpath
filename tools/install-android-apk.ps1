[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Serial,
    [Parameter(Mandatory)][string]$Apk,
    [switch]$UseRoot
)

$ErrorActionPreference = 'Stop'
if (-not $env:ANDROID_HOME) { throw 'Load tools/enter-android-env.ps1 first.' }
$rtpathAdb = Join-Path $env:ANDROID_HOME 'platform-tools/adb.exe'
if (-not (Test-Path -LiteralPath $rtpathAdb -PathType Leaf)) { throw "ADB not found: $rtpathAdb" }
$rtpathApk = Get-Item -LiteralPath $Apk
if ($rtpathApk.PSIsContainer -or $rtpathApk.Extension -ne '.apk') {
    throw 'Specify a built APK file.'
}

if (-not $UseRoot) {
    & $rtpathAdb -s $Serial install -r $rtpathApk.FullName
    if ($LASTEXITCODE -ne 0) { throw 'ADB installation failed.' }
    return
}

# Only the controlled device-side filename is interpolated into the shell command.
$rtpathStagedApk = '/data/local/tmp/rtpath-install-' + [Guid]::NewGuid().ToString('N') + '.apk'
try {
    & $rtpathAdb -s $Serial push $rtpathApk.FullName $rtpathStagedApk
    if ($LASTEXITCODE -ne 0) { throw 'Could not stage the APK on the device.' }

    $rtpathOutput = & $rtpathAdb -s $Serial shell "su -c 'pm install -r $rtpathStagedApk'"
    $rtpathInstallExit = $LASTEXITCODE
    $rtpathOutput | Write-Output
    if ($rtpathInstallExit -ne 0 -or ($rtpathOutput -join [char]10) -notmatch '(?m)^Success\s*$') {
        throw 'Root installation failed.'
    }
} finally {
    & $rtpathAdb -s $Serial shell rm -f $rtpathStagedApk
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Could not clean the staged APK at $rtpathStagedApk"
    }
}
