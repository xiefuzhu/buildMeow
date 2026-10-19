param(
  [Parameter(Mandatory = $true)]
  [ValidatePattern('^\d+\.\d+\.\d+-beta\.\d+$')]
  [string]$AppVersion,
  [ValidateRange(1, 65535)][int]$BuildNumber = 1,
  [string]$Compiler,
  [string]$CrtDirectory
)
$ErrorActionPreference = 'Stop'
$appDirectory = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
Push-Location $appDirectory
try {
  & flutter pub get
  if ($LASTEXITCODE -ne 0) { throw "Dependency resolution failed: $LASTEXITCODE" }
  $buildName = $AppVersion -replace '-beta\.\d+$', ''
  & flutter build windows --release --no-pub --build-name $buildName --build-number $BuildNumber
  if ($LASTEXITCODE -ne 0) { throw "Windows release build failed: $LASTEXITCODE" }
  & "$PSScriptRoot/build_installer.ps1" `
    -ReleaseDirectory 'build/windows/x64/runner/Release' `
    -IconPath 'windows/runner/resources/app_icon.ico' `
    -AppVersion $AppVersion -Compiler $Compiler -CrtDirectory $CrtDirectory
} finally {
  Pop-Location
}
