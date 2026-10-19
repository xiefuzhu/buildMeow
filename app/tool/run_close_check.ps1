param([switch]$SkipBuild)
$ErrorActionPreference = 'Stop'
# Unlike the debug smoke test, this must exercise release engine destruction.
if (-not $SkipBuild) {
  & flutter build windows --release --no-pub -t tool/verify_close.dart
  if ($LASTEXITCODE -ne 0) { throw 'Close verification build failed' }
}
$appDirectory = (Get-Location).Path
$binary = Join-Path $appDirectory 'build/windows/x64/runner/Release/build_meow.exe'
$output = Join-Path $appDirectory ('build/qa/close_' + [DateTime]::UtcNow.Ticks)
New-Item -ItemType Directory -Path $output -Force | Out-Null
$savedScenario = $env:BUILD_MEOW_CLOSE_SCENARIO
$savedDirectory = $env:BUILD_MEOW_CLOSE_DIR
try {
  foreach ($scenario in @('normal', 'normal', 'floating', 'maximized', 'tray')) {
    $env:BUILD_MEOW_CLOSE_SCENARIO = $scenario
    $directory = Join-Path $output ($scenario + '_' + [DateTime]::UtcNow.Ticks)
    New-Item -ItemType Directory -Path $directory | Out-Null
    $env:BUILD_MEOW_CLOSE_DIR = $directory
    $probe = Start-Process -FilePath $binary -WorkingDirectory $appDirectory -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $directory 'stdout.log') -RedirectStandardError (Join-Path $directory 'stderr.log')
    # Retain the process handle: Windows PowerShell otherwise can lose the exit
    # code when a short-lived child exits before its Process wrapper queries it.
    $null = $probe.Handle
    if (-not $probe.WaitForExit(15000)) {
      Stop-Process -Id $probe.Id -ErrorAction SilentlyContinue
      throw "Close hung in $scenario; evidence: $directory"
    }
    if ($probe.ExitCode -ne 0) { throw "Close crashed in $scenario (exit $($probe.ExitCode)); evidence: $directory" }
    $report = Get-Content -LiteralPath (Join-Path $directory 'report.json') -Raw | ConvertFrom-Json
    if ($report.errors.Count -ne 0) { throw "Framework errors in $scenario" }
    if ($scenario -eq 'tray' -and -not $report.trayRecovered) { throw 'Tray recovery failed' }
    $settings = Get-Content -LiteralPath (Join-Path $directory 'preferences.json') -Raw | ConvertFrom-Json
    if ($settings.values.theme_mode -ne 'dark') { throw "Pending settings were lost in $scenario" }
    $bridgeErrors = Select-String -LiteralPath (Join-Path $directory 'stderr.log') -Pattern 'Failed to update ui::AXTree|accessibility_bridge.*ERROR'
    if ($bridgeErrors) { throw "Native accessibility errors in $scenario" }
    Write-Output "PASS: $scenario title-bar pointer click, pending save, clean exit (0)"
  }
  Write-Output "Evidence: $output"
} finally {
  $env:BUILD_MEOW_CLOSE_SCENARIO = $savedScenario
  $env:BUILD_MEOW_CLOSE_DIR = $savedDirectory
}
