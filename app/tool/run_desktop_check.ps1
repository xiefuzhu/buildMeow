# Run from app/. Uses the real Windows app without flutter_tester's transport.
$ErrorActionPreference = 'Stop'
$appDirectory = (Get-Location).Path
if (-not (Test-Path -LiteralPath (Join-Path $appDirectory 'pubspec.yaml'))) {
  throw 'Run this script from the app directory.'
}
& flutter build windows --debug --no-pub -t tool/verify_desktop.dart
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
$qaDirectory = Join-Path $appDirectory 'build\qa'
New-Item -ItemType Directory -Force -Path $qaDirectory | Out-Null
$previousRunDirectory = Join-Path $qaDirectory ('desktop_previous_' + [DateTime]::UtcNow.Ticks)
New-Item -ItemType Directory -Force -Path $previousRunDirectory | Out-Null
Get-ChildItem -LiteralPath $qaDirectory -File -Filter 'native_*' | Copy-Item -Destination $previousRunDirectory
$env:BUILD_MEOW_NATIVE_QA = '1'
$reportPath = Join-Path $qaDirectory 'native_report.json'
if (Test-Path -LiteralPath $reportPath) { Remove-Item -LiteralPath $reportPath }
$binaryPath = Join-Path $appDirectory 'build\windows\x64\runner\Debug\build_meow.exe'
$probe = Start-Process -FilePath $binaryPath -WorkingDirectory $appDirectory -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $qaDirectory 'native_stdout.log') -RedirectStandardError (Join-Path $qaDirectory 'native_stderr.log')
$finished = $false
foreach ($waitRound in 1..4) {
  if ($probe.WaitForExit(30000)) { $finished = $true; break }
}
if (-not $finished) {
  Stop-Process -Id $probe.Id
  throw 'Native verification timed out; see build/qa/native_stdout.log.'
}
if (-not (Test-Path -LiteralPath $reportPath)) { throw "The app exited before writing a verification report (exit $($probe.ExitCode)). See $qaDirectory/native_stderr.log." }
if ($probe.ExitCode -ne 0) { throw "Native process exited abnormally after its report: $($probe.ExitCode)" }
$report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
if (-not $report.passed) { throw (Get-Content -LiteralPath $reportPath -Raw) }
$bridgeErrors = Select-String -LiteralPath (Join-Path $qaDirectory 'native_stderr.log') -Pattern 'Failed to update ui::AXTree|accessibility_bridge.*ERROR'
if ($bridgeErrors) { throw 'Native accessibility bridge rejected updates; see native_stderr.log. Framework success alone is insufficient.' }
Write-Host 'PASS: both modes, semantics, maximize/restore, screen-coordinate drag, complete blueprint.'
Write-Host "Report: $reportPath"
if (-not $report.desktopFeatures.realGlobalKeys) {
  Write-Host 'LIMITATION: SendInput was unavailable. System registration, conflict handling and native message dispatch passed; physical global key delivery still needs manual verification.'
}

$savedPhase = $env:BUILD_MEOW_PREF_PHASE
$savedPreferenceDirectory = $env:BUILD_MEOW_PREFS_QA_DIR
try {
  $env:BUILD_MEOW_PREFS_QA_DIR = Join-Path $qaDirectory ("preferences_restart_" + [DateTime]::UtcNow.Ticks)
  foreach ($phase in @('write', 'read')) {
    $env:BUILD_MEOW_PREF_PHASE = $phase
    $phaseReportPath = Join-Path $qaDirectory "native_preferences_$phase.json"
    if (Test-Path -LiteralPath $phaseReportPath) { Remove-Item -LiteralPath $phaseReportPath }
    $phaseProbe = Start-Process -FilePath $binaryPath -WorkingDirectory $appDirectory -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $qaDirectory "preferences_$phase.log") -RedirectStandardError (Join-Path $qaDirectory "preferences_${phase}_stderr.log")
    if (-not $phaseProbe.WaitForExit(30000)) { Stop-Process -Id $phaseProbe.Id; throw "Preferences $phase check timed out" }
    if (-not (Test-Path -LiteralPath $phaseReportPath)) { throw "Preferences $phase check did not produce a report" }
    if ($phaseProbe.ExitCode -ne 0) { throw "Preferences $phase process exited abnormally: $($phaseProbe.ExitCode)" }
    $phaseReport = Get-Content -LiteralPath $phaseReportPath -Raw | ConvertFrom-Json
    if (-not $phaseReport.passed) { throw "Preferences $phase check failed" }
  }
  Write-Host 'PASS: generation settings, theme, export options and directory survive two separate native processes.'
} finally {
  $env:BUILD_MEOW_PREF_PHASE = $savedPhase
  $env:BUILD_MEOW_PREFS_QA_DIR = $savedPreferenceDirectory
}
