param([Parameter(Mandatory = $true)][string]$Setup)
$ErrorActionPreference = 'Stop'
$appDirectory = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$setupPath = (Resolve-Path -LiteralPath $Setup).Path
$registryKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\{B5E4F136-E54A-4C44-B649-65CBB884A79D}_is1'
if (Test-Path -LiteralPath $registryKey) { throw 'A beta is already installed; do not replace the user installation for QA.' }
$qaRoot = Join-Path $appDirectory 'build\qa'
$qa = [IO.Path]::GetFullPath((Join-Path $qaRoot ('installer_' + [guid]::NewGuid().ToString('N'))))
if (-not $qa.StartsWith($qaRoot + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'QA path escaped workspace.' }
$target = Join-Path $qa '安装目录'
$group = 'BuildMeow Installer QA ' + [guid]::NewGuid().ToString('N')
$startMenu = Join-Path ([Environment]::GetFolderPath('Programs')) $group
$shortcut = Join-Path $startMenu '建喵！测试版.lnk'
$keep = Join-Path $qa 'export_keep.txt'
$configuration = Join-Path $env:APPDATA 'com.buildmeow\建喵!\preferences.json'
$hadConfiguration = Test-Path -LiteralPath $configuration
New-Item -ItemType Directory -Force -Path $qa | Out-Null
'export must survive uninstall' | Set-Content -LiteralPath $keep -Encoding utf8
$report = [ordered]@{ passed = $false; target = $target; group = $group }

function Run-Setup([string]$logName) {
  $arguments = @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SP-', '/TASKS=',
    ('/DIR="' + $target + '"'), ('/GROUP="' + $group + '"'), ('/LOG="' + (Join-Path $qa $logName) + '"'))
  $installation = Start-Process -FilePath $setupPath -ArgumentList $arguments -WindowStyle Hidden -PassThru
  if (-not $installation.WaitForExit(60000)) { throw 'Installer QA timed out; inspect the setup log.' }
  if ($installation.ExitCode -ne 0) { throw "Setup exited with code $($installation.ExitCode)" }
}

try {
  Run-Setup 'install.log'
  $manifest = Get-Content -LiteralPath "$setupPath.payload.json" -Raw | ConvertFrom-Json
  foreach ($entry in $manifest) {
    $installedFile = Join-Path $target $entry.path
    if (-not (Test-Path -LiteralPath $installedFile) -or (Get-FileHash -LiteralPath $installedFile).Hash -ne $entry.sha256) {
      throw "Installed payload differs: $($entry.path)"
    }
  }
  $report.payloadFiles = $manifest.Count
  $report.payloadHashes = $true
  foreach ($required in @('build_meow.exe','data\app.so','msvcp140.dll','vcruntime140.dll','app_icon.ico','LICENSE','THIRD_PARTY_NOTICES.md')) {
    if (-not (Test-Path -LiteralPath (Join-Path $target $required))) { throw "Missing installed file: $required" }
  }
  $installed = Get-ItemProperty -LiteralPath $registryKey
  if ($installed.DisplayVersion -ne '1.0.0-beta.1') { throw 'Incorrect uninstall version.' }
  $link = (New-Object -ComObject WScript.Shell).CreateShortcut($shortcut)
  $executable = Join-Path $target 'build_meow.exe'
  if ($link.TargetPath -ne $executable -or $link.WorkingDirectory -ne $target) { throw 'Incorrect shortcut target or working directory.' }
  $report.install = $true
  $report.shortcut = $true
  $before = (Get-FileHash -LiteralPath $executable).Hash
  Run-Setup 'reinstall.log'
  if ((Get-FileHash -LiteralPath $executable).Hash -ne $before) { throw 'Reinstall altered the executable.' }
  $report.reinstall = $true

  # Close only the process started by this test, with the ordinary WM_CLOSE path.
  Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class InstallerQaWindow {
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);
}
'@
  $application = Start-Process -FilePath $executable -WorkingDirectory $target -WindowStyle Hidden -PassThru
  $deadline = [DateTime]::UtcNow.AddSeconds(20)
  do {
    Start-Sleep -Milliseconds 250
    $application.Refresh()
  } while (-not $application.HasExited -and $application.MainWindowHandle -eq [IntPtr]::Zero -and [DateTime]::UtcNow -lt $deadline)
  if ($application.HasExited -or $application.MainWindowHandle -eq [IntPtr]::Zero) { throw 'The installed application did not open its window.' }
  Start-Sleep -Seconds 2
  $application.Refresh()
  if ($application.HasExited) { throw 'The installed application exited unexpectedly.' }
  $report.startup = $true
  [void][InstallerQaWindow]::PostMessage($application.MainWindowHandle, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)
  if (-not $application.WaitForExit(20000)) { throw 'Application did not close normally; retain QA installation for diagnosis.' }
  $report.normalClose = $true

  $uninstaller = Start-Process -FilePath (Join-Path $target 'unins000.exe') -ArgumentList '/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART',('/LOG="' + (Join-Path $qa 'uninstall.log') + '"') -WindowStyle Hidden -PassThru
  if (-not $uninstaller.WaitForExit(60000) -or $uninstaller.ExitCode -ne 0) { throw 'Uninstall failed; retain QA files.' }
  if ((Test-Path -LiteralPath $executable) -or (Test-Path -LiteralPath $registryKey) -or (Test-Path -LiteralPath $shortcut)) { throw 'Uninstall left executable, registry entry or shortcut.' }
  if (-not (Test-Path -LiteralPath $keep)) { throw 'Uninstall removed external export file.' }
  if ($hadConfiguration -and -not (Test-Path -LiteralPath $configuration)) { throw 'Uninstall removed the user configuration.' }
  $report.uninstall = $true
  $report.exportsPreserved = $true
  $report.existingConfigurationPreserved = $hadConfiguration
  $report.passed = $true
} finally {
  $report | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $qa 'report.json') -Encoding utf8
  Write-Output "Report: $(Join-Path $qa 'report.json')"
}
Write-Output 'PASS: install, reinstall, shortcut, installed-app startup, normal close, uninstall and data retention.'
