[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Serial,
    [switch]$Shared,
    [switch]$Root
)

$ErrorActionPreference = 'Stop'
if (-not $env:ANDROID_HOME -or -not $env:JAVA_HOME) {
    throw 'Load tools/enter-android-env.ps1 first.'
}

$rtpathRoot = Split-Path -Parent $PSScriptRoot
$rtpathAdb = Join-Path $env:ANDROID_HOME 'platform-tools/adb.exe'
$rtpathAapt = Join-Path $env:ANDROID_HOME 'build-tools/36.0.0/aapt.exe'
$rtpathPackage = 'io.github.eltancex.rtpath.testhost'
$rtpathActivity = "$rtpathPackage/io.github.eltancex.rtpath.MainActivity"
$rtpathTarget = 'integration_test/scan_test.dart'
$rtpathApk = Join-Path $rtpathRoot 'build/app/outputs/apk/debug/app-debug.apk'
$rtpathRun = [guid]::NewGuid().ToString('N')
$rtpathFixture = if ($Root) { '/data/local/tmp/rtpath-root-' + [guid]::NewGuid().ToString('N') } else { '' }

function Invoke-RtPathTestRun([string]$ExpectedLog) {
    & $rtpathAdb -s $Serial shell am force-stop $rtpathPackage
    if ($LASTEXITCODE -ne 0) { throw 'Could not stop the test host.' }
    $rtpathLaunch = & $rtpathAdb -s $Serial shell am start -W -n $rtpathActivity
    if ($LASTEXITCODE -ne 0 -or $rtpathLaunch -notcontains 'Status: ok') {
        throw "Could not start the test host. $($rtpathLaunch -join ' ')"
    }

    $rtpathAppPid = (& $rtpathAdb -s $Serial shell pidof $rtpathPackage) -join ''
    if ($LASTEXITCODE -ne 0 -or $rtpathAppPid.Trim() -notmatch '^\d+$') {
        throw 'Could not identify the test host process.'
    }

    $rtpathStartTime = [Diagnostics.Stopwatch]::StartNew()
    do {
        $rtpathLogs = & $rtpathAdb -s $Serial logcat -d "--pid=$($rtpathAppPid.Trim())" -s flutter:I
        $rtpathVm = [regex]::Match(($rtpathLogs -join [char]10),
            'The Dart VM service is listening on http://127\.0\.0\.1:(?<port>\d+)(?<path>/\S+)')
        if ($rtpathVm.Success) { break }
        Start-Sleep -Milliseconds 250
    } while ($rtpathStartTime.Elapsed.TotalSeconds -lt 8)
    if (-not $rtpathVm.Success) { throw 'Could not discover the test host Dart VM Service.' }

    $rtpathPort = (& $rtpathAdb -s $Serial forward tcp:0 "tcp:$($rtpathVm.Groups['port'].Value)") -join ''
    if ($LASTEXITCODE -ne 0 -or $rtpathPort.Trim() -notmatch '^\d+$') {
        throw 'Could not forward the test host Dart VM Service.'
    }
    $rtpathPort = $rtpathPort.Trim()
    try {
        $rtpathUri = "http://127.0.0.1:${rtpathPort}$($rtpathVm.Groups['path'].Value)"
        flutter drive -d $Serial --target $rtpathTarget --driver test_driver/integration_test.dart `
            --use-existing-app $rtpathUri --timeout 150
        if ($LASTEXITCODE -ne 0) { throw 'Flutter integration test failed.' }
        $rtpathChecks = & $rtpathAdb -s $Serial logcat -d "--pid=$($rtpathAppPid.Trim())" -s flutter:I |
            Select-String 'RtPath phase [123]|Android \d+ \(API '
        $rtpathChecks | Write-Output
        if (-not ($rtpathChecks | Select-String -SimpleMatch $ExpectedLog)) {
            throw "Expected test result missing ($ExpectedLog)."
        }
    } finally {
        & $rtpathAdb -s $Serial forward --remove "tcp:$rtpathPort"
    }
}

Push-Location $rtpathRoot
try {
    $rtpathDefines = @(
        "RTPATH_TEST_SHARED=$($Shared.IsPresent.ToString().ToLowerInvariant())"
        "RTPATH_ROOT_FIXTURE=$rtpathFixture"
        "RTPATH_TEST_RUN=$rtpathRun"
        'INTEGRATION_TEST_SHOULD_REPORT_RESULTS_TO_NATIVE=false'
    ) | ForEach-Object { [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($_)) }

    Push-Location android
    try {
        ./gradlew.bat :app:assembleDebug --console=plain -q '-PrtpathTestHost=true' `
            '-Ptarget-platform=android-arm64,android-x64' "-Ptarget=$(Join-Path $rtpathRoot $rtpathTarget)" `
            '-Pbase-application-name=android.app.Application' "-Pdart-defines=$($rtpathDefines -join ',')"
        if ($LASTEXITCODE -ne 0) { throw 'Could not build the test host APK.' }
    } finally {
        Pop-Location
    }
    $rtpathBadging = & $rtpathAapt dump badging $rtpathApk
    if ($LASTEXITCODE -ne 0 -or -not ($rtpathBadging | Select-String -SimpleMatch "package: name='$rtpathPackage' ")) {
        throw 'The APK does not have the expected test host package name.'
    }
    & (Join-Path $PSScriptRoot 'install-android-apk.ps1') -Serial $Serial -Apk $rtpathApk -UseRoot

    if ($Root) {
        $rtpathFixtureCommand = "mkdir -m 700 $rtpathFixture && touch $rtpathFixture/Protected-项目.txt || exit 1; i=0; while [ `$i -lt 24000 ]; do : > $rtpathFixture/item-`$i || exit 1; i=`$((i+1)); done"
        & $rtpathAdb -s $Serial shell "su -c '$rtpathFixtureCommand'"
        if ($LASTEXITCODE -ne 0) { throw 'Could not prepare the protected Root test fixture.' }
    }
    if ($Shared) {
        & $rtpathAdb -s $Serial shell appops set $rtpathPackage MANAGE_EXTERNAL_STORAGE allow
        if ($LASTEXITCODE -ne 0) { throw 'Could not grant shared storage access to the test host.' }
    }
    try {
        Invoke-RtPathTestRun 'baseline, concurrent query, cancellation, republish and UI verified'
    } finally {
        if ($Shared) {
            & $rtpathAdb -s $Serial shell appops set $rtpathPackage MANAGE_EXTERNAL_STORAGE default
            if ($LASTEXITCODE -ne 0) { throw 'Could not reset the test host shared storage grant.' }
        }
    }
    Invoke-RtPathTestRun 'persisted generation verified after process restart'
} finally {
    if ($Root) {
        & $rtpathAdb -s $Serial shell "su -c 'rm -rf $rtpathFixture'"
    }
    Pop-Location
}
