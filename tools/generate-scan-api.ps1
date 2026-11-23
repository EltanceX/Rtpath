$ErrorActionPreference = 'Stop'
Push-Location (Split-Path -Parent $PSScriptRoot)
try {
    dart run pigeon --input pigeons/scan_api.dart
    if ($LASTEXITCODE -ne 0) { throw 'Pigeon generation failed.' }
    dart format lib/platform/scan_api.g.dart
    if ($LASTEXITCODE -ne 0) { throw 'Generated Dart formatting failed.' }
} finally {
    Pop-Location
}
