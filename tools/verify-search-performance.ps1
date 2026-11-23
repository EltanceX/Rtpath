[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Serial,
    [ValidatePattern('^[A-Za-z0-9-]+\.txt$')][string]$ReportName = 'phase2-performance.txt'
)

$ErrorActionPreference = 'Stop'
if (-not $env:ANDROID_HOME -or -not $env:JAVA_HOME) {
    throw 'Load tools/enter-android-env.ps1 first.'
}

$rtpathRoot = Split-Path -Parent $PSScriptRoot
$rtpathAdb = Join-Path $env:ANDROID_HOME 'platform-tools/adb.exe'
$rtpathAapt = Join-Path $env:ANDROID_HOME 'build-tools/36.0.0/aapt.exe'
$rtpathApk = Join-Path $rtpathRoot 'build/app/outputs/apk/profile/app-profile.apk'
$rtpathPackage = 'io.github.eltancex.rtpath.testhost'
$rtpathRunner = "$rtpathPackage/io.github.eltancex.rtpath.scan.SearchBenchmark"
$rtpathArtifacts = Join-Path $rtpathRoot '.local/artifacts'
$rtpathReport = Join-Path $rtpathArtifacts $ReportName
$rtpathTarget = Join-Path $rtpathRoot 'lib/main.dart'

Push-Location (Join-Path $rtpathRoot 'android')
try {
    ./gradlew.bat :app:assembleProfile --console=plain -q '-PrtpathTestHost=true' `
        '-Ptarget-platform=android-arm64' "-Ptarget=$rtpathTarget" `
        '-Pbase-application-name=android.app.Application'
    if ($LASTEXITCODE -ne 0) { throw 'Could not build the profile test host APK.' }
} finally {
    Pop-Location
}

$rtpathBadging = & $rtpathAapt dump badging $rtpathApk
if ($LASTEXITCODE -ne 0 -or -not ($rtpathBadging | Select-String -SimpleMatch "package: name='$rtpathPackage' ")) {
    throw 'The APK does not have the expected test host package name.'
}
& (Join-Path $PSScriptRoot 'install-android-apk.ps1') -Serial $Serial -Apk $rtpathApk -UseRoot

[IO.Directory]::CreateDirectory($rtpathArtifacts) | Out-Null
& $rtpathAdb -s $Serial shell am instrument -w -r $rtpathRunner | Tee-Object -FilePath $rtpathReport
if ($LASTEXITCODE -ne 0 -or -not (Select-String -LiteralPath $rtpathReport -Pattern '^INSTRUMENTATION_CODE: -1$')) {
    throw "Search benchmark failed. See $rtpathReport."
}
