[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$FlutterSdk,
    [Parameter(Mandatory)]
    [string]$AndroidSdk,
    [Parameter(Mandatory)]
    [string]$Jdk
)

$rtpathFlutter = (Resolve-Path -LiteralPath $FlutterSdk -ErrorAction Stop).Path
$rtpathAndroid = (Resolve-Path -LiteralPath $AndroidSdk -ErrorAction Stop).Path
$rtpathJdk = (Resolve-Path -LiteralPath $Jdk -ErrorAction Stop).Path

foreach ($rtpathFile in @(
    (Join-Path $rtpathFlutter 'bin/flutter.bat')
    (Join-Path $rtpathAndroid 'platform-tools/adb.exe')
    (Join-Path $rtpathJdk 'bin/java.exe')
)) {
    if (-not (Test-Path -LiteralPath $rtpathFile -PathType Leaf)) {
        throw "Required executable not found: $rtpathFile"
    }
}

$env:ANDROID_HOME = $rtpathAndroid
$env:JAVA_HOME = $rtpathJdk
if ($env:ANDROID_SDK_ROOT) {
    $env:ANDROID_SDK_ROOT = $rtpathAndroid
}

$rtpathToolPaths = @(
    (Join-Path $rtpathFlutter 'bin')
    (Join-Path $rtpathAndroid 'platform-tools')
    (Join-Path $rtpathJdk 'bin')
)
$rtpathPriorPaths = $env:Path -split ';' | Where-Object { $_ -and $_ -notin $rtpathToolPaths }
$env:Path = ($rtpathToolPaths + $rtpathPriorPaths) -join ';'
