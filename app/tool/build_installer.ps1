param(
  [Parameter(Mandatory = $true)][string]$ReleaseDirectory,
  [Parameter(Mandatory = $true)][string]$IconPath,
  [string]$AppVersion = '1.0.0-beta.1',
  [string]$Compiler,
  [string]$CrtDirectory
)
$ErrorActionPreference = 'Stop'
$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$release = (Resolve-Path -LiteralPath $ReleaseDirectory).Path
$icon = (Resolve-Path -LiteralPath $IconPath).Path
if ([IO.Path]::GetExtension($icon) -ne '.ico') { throw 'IconPath must be a Windows ICO file.' }
if ($AppVersion -notmatch '^\d+\.\d+\.\d+-beta\.\d+$') { throw 'Expected a version such as 1.0.0-beta.1.' }
foreach ($required in @('build_meow.exe', 'flutter_windows.dll', 'data\app.so')) {
  if (-not (Test-Path -LiteralPath (Join-Path $release $required))) {
    throw "Incomplete release: missing $required"
  }
}
if (-not $Compiler) { $Compiler = Join-Path $repositoryRoot 'build\tools\inno\ISCC.exe' }
if (-not (Test-Path -LiteralPath $Compiler)) { throw 'Install Inno Setup 6.5+ or provide -Compiler.' }
if (-not $CrtDirectory) {
  $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
  $visualStudio = & $vswhere -latest -prerelease -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
  if (-not $visualStudio) { throw 'Provide -CrtDirectory from the release toolchain redistributable folder.' }
  $redist = Get-ChildItem -LiteralPath (Join-Path $visualStudio 'VC\Redist\MSVC') -Directory |
    Where-Object { $_.Name -match '^\d+\.\d+\.\d+$' } |
    Sort-Object { [version]$_.Name } -Descending | Select-Object -First 1
  $crt = Get-ChildItem -LiteralPath (Join-Path $redist.FullName 'x64') -Directory -Filter 'Microsoft.VC*.CRT' | Select-Object -First 1
  if (-not $crt) { throw 'Cannot locate x64 release CRT DLLs.' }
  $CrtDirectory = $crt.FullName
}
$output = Join-Path $repositoryRoot 'app\build\installers'
$payload = Join-Path $repositoryRoot ('app\build\installer_payload_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $output, $payload | Out-Null
Get-ChildItem -LiteralPath $release | Copy-Item -Destination $payload -Recurse -Force
Copy-Item -LiteralPath $icon -Destination (Join-Path $payload 'app_icon.ico')
Get-ChildItem -LiteralPath $CrtDirectory -Filter '*.dll' | Copy-Item -Destination $payload
foreach ($required in @('msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll')) {
  if (-not (Test-Path -LiteralPath (Join-Path $payload $required))) { throw "Missing runtime: $required" }
}
$script = Join-Path $repositoryRoot 'app\installer\build_meow.iss'
& $Compiler "/DSourceDir=$payload" "/DOutputDir=$output" "/DAppVersion=$AppVersion" $script
if ($LASTEXITCODE -ne 0) { throw "Installer compiler failed: $LASTEXITCODE" }
$setup = Join-Path $output "BuildMeow-$AppVersion-windows-x64-setup.exe"
if (-not (Test-Path -LiteralPath $setup)) { throw 'Compiler did not produce the expected installer.' }
Get-FileHash -LiteralPath $setup -Algorithm SHA256 |
  ConvertTo-Json | Set-Content -LiteralPath "$setup.sha256.json" -Encoding utf8
# Include the same notices in the portable bundle as in the installed app.
Copy-Item -LiteralPath (Join-Path $repositoryRoot 'LICENSE'), (Join-Path $repositoryRoot 'THIRD_PARTY_NOTICES.md') -Destination $payload
Copy-Item -LiteralPath (Join-Path $repositoryRoot 'app\installer\beta_notes.txt') -Destination (Join-Path $payload '测试版说明.txt')
$licenseDirectory = Join-Path $payload 'licenses'
New-Item -ItemType Directory -Force -Path $licenseDirectory | Out-Null
Copy-Item -LiteralPath (Join-Path $repositoryRoot 'app\installer\INNO_LICENSE.txt') -Destination $licenseDirectory
$payloadManifest = @(Get-ChildItem -LiteralPath $payload -File -Recurse | ForEach-Object {
  [ordered]@{
    path = $_.FullName.Substring($payload.Length + 1)
    sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
  }
})
$payloadManifest | ConvertTo-Json | Set-Content -LiteralPath "$setup.payload.json" -Encoding utf8
$portable = Join-Path $output "BuildMeow-$AppVersion-windows-x64-portable.zip"
Compress-Archive -Path (Join-Path $payload '*') -DestinationPath $portable -Force
$checksums = @($setup, $portable) | ForEach-Object {
  $hash = (Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash.ToLowerInvariant()
  "$hash  $([IO.Path]::GetFileName($_))"
}
$checksums | Set-Content -LiteralPath (Join-Path $output 'SHA256SUMS.txt') -Encoding ascii
Write-Output "Installer: $setup"
Write-Output "Portable: $portable"
Write-Output "Payload: $payload"
