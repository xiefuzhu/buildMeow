# Run from app/. Only native tester crashes are retried, not assertion failures.
param([int]$Retries = 3)
$ErrorActionPreference = 'Continue'
$testLogDirectory = Join-Path (Get-Location) 'build\test_logs'
New-Item -ItemType Directory -Force -Path $testLogDirectory | Out-Null
$failures = @()
$recovered = @()
$total = 0
foreach ($file in (Get-ChildItem test -Filter *_test.dart | Sort-Object Name)) {
  $passed = $false
  for ($attempt = 1; $attempt -le ($Retries + 1); $attempt++) {
    $output = & flutter test --no-pub "test/$($file.Name)" --reporter=expanded 2>&1 | Out-String
    $testExitCode = $LASTEXITCODE
    $testLogPath = Join-Path $testLogDirectory "$($file.BaseName)-attempt-$attempt.log"
    ("Exit code: $testExitCode" + [Environment]::NewLine + $output) | Set-Content -LiteralPath $testLogPath -Encoding utf8
    if ($testExitCode -eq 0 -and $output -match 'All tests passed') {
      $passed = $true
      $testCountMatches = [regex]::Matches($output, '\+(\d+)')
      if ($testCountMatches.Count -gt 0) { $total += [int]$testCountMatches[$testCountMatches.Count - 1].Groups[1].Value }
      if ($attempt -gt 1) { $recovered += $file.Name }
      Write-Host "PASS $($file.Name) (attempt $attempt)"
      break
    }
    $nativeCrash = $output -match 'c0000005|c000041d|access violation|shell subprocess crashed|flutter_tester.*crash|TestDeviceException|did not complete|Connection closed before test suite loaded'
    if ($output -match 'Expected:|TestFailure') { $nativeCrash = $false }
    Write-Host "FAILED attempt $attempt - $($file.Name); log: $testLogPath"
    if (-not $nativeCrash) {
      Write-Host ($output -split '\r?\n' | Select-Object -Last 20 | Out-String)
      break
    }
  }
  if (-not $passed) { $failures += $file.Name }
}
Write-Host "Passed cases: $total. Logs: $testLogDirectory"
if ($recovered.Count -gt 0) {
  Write-Host "Native crashes recovered after retry (still unresolved): $($recovered -join ', ')"
}
if ($failures.Count -gt 0) {
  Write-Host "Failed files: $($failures -join ', ')"
  exit 1
}
Write-Host 'every test file passed'

