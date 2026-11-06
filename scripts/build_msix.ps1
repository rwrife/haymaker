<#
.SYNOPSIS
  Builds the Haymaker Microsoft Store package (.msixbundle) and portable zips.

.DESCRIPTION
  Exports the Windows x86_64 and ARM64 Godot presets, stages each export with
  the MSIX manifest from AppStore/Windows/msix and generated tile images,
  indexes resources with makepri, packs one .msix per architecture and bundles
  them into an unsigned .msixbundle for Partner Center upload. The Store signs
  packages on ingestion; no certificate is used or required here.

.EXAMPLE
  pwsh scripts/build_msix.ps1 -Version 1.0.0
#>
param(
  # Store versions are Major.Minor.Build; the revision is always 0.
  [Parameter(Mandatory = $true)][ValidatePattern('^\d+\.\d+\.\d+$')][string]$Version,
  [string]$Godot = $env:GODOT,
  [string]$Python = $(if ($env:PYTHON) { $env:PYTHON } else { 'python' }),
  [string]$OutDir
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$GodotProject = Join-Path $Root 'godot'
if (-not $OutDir) { $OutDir = Join-Path $GodotProject 'builds\store' }
$PackageVersion = "$Version.0"

function Find-Tool([string]$Name) {
  $command = Get-Command $Name -ErrorAction SilentlyContinue
  if ($command) { return $command.Source }
  $kits = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\bin'
  $hostArch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }
  $found = Get-ChildItem $kits -Directory -Filter '10.*' -ErrorAction SilentlyContinue |
    Sort-Object { [version]$_.Name } -Descending |
    ForEach-Object { Join-Path $_.FullName "$hostArch\$Name" } |
    Where-Object { Test-Path $_ } |
    Select-Object -First 1
  if (-not $found) { throw "$Name not found. Install the Windows 10/11 SDK." }
  return $found
}

function Invoke-Checked([string]$Exe, [string[]]$Arguments) {
  $output = & $Exe @Arguments 2>&1
  if ($LASTEXITCODE -ne 0) {
    $output | Write-Host
    throw "$(Split-Path -Leaf $Exe) failed with exit code $LASTEXITCODE"
  }
  $output | Where-Object { "$_" -match 'succeeded|WARNING|Wrote' } | Write-Host
}

if (-not $Godot) { $Godot = (Get-Command godot -ErrorAction Stop).Source }
$MakeAppx = Find-Tool 'makeappx.exe'
$MakePri = Find-Tool 'makepri.exe'

$Targets = @(
  @{ Preset = 'Windows Desktop'; Arch = 'x64'; Export = 'builds/windows/Haymaker.exe' },
  @{ Preset = 'Windows Desktop (ARM64)'; Arch = 'arm64'; Export = 'builds/windows-arm64/Haymaker.exe' }
)

$Staging = Join-Path $OutDir 'staging'
$Packages = Join-Path $Staging 'packages'
Remove-Item $OutDir -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $Packages | Out-Null

$Manifest = Get-Content (Join-Path $Root 'AppStore\Windows\msix\AppxManifest.xml') -Raw

foreach ($target in $Targets) {
  Write-Host "== Exporting $($target.Preset)"
  $exe = Join-Path $GodotProject $target.Export
  New-Item -ItemType Directory -Force (Split-Path $exe) | Out-Null
  Remove-Item $exe -Force -ErrorAction SilentlyContinue
  Invoke-Checked $Godot @('--headless', '--path', $GodotProject, '--export-release', $target.Preset, $target.Export)
  if (-not (Test-Path $exe)) { throw "Godot did not produce $exe" }

  $layout = Join-Path $Staging $target.Arch
  New-Item -ItemType Directory -Force $layout | Out-Null
  Copy-Item $exe $layout
  Invoke-Checked $Python @((Join-Path $PSScriptRoot 'build_msix_assets.py'), $layout)
  $Manifest.Replace('$VERSION$', $PackageVersion).Replace('$ARCH$', $target.Arch) |
    Set-Content (Join-Path $layout 'AppxManifest.xml') -Encoding utf8

  $priConfig = Join-Path $Staging "priconfig-$($target.Arch).xml"
  Invoke-Checked $MakePri @('createconfig', '/cf', $priConfig, '/dq', 'en-US', '/pv', '10.0.0', '/o')
  # Keep every scale in one resources.pri; split files belong to resource packs, which this package doesn't use.
  [xml]$config = Get-Content $priConfig
  $packaging = $config.SelectSingleNode('//packaging')
  if ($packaging) { [void]$packaging.ParentNode.RemoveChild($packaging) }
  $config.Save($priConfig)
  Invoke-Checked $MakePri @('new', '/pr', $layout, '/cf', $priConfig, '/mn', (Join-Path $layout 'AppxManifest.xml'), '/of', (Join-Path $layout 'resources.pri'), '/o')

  $msix = Join-Path $Packages "Haymaker_$($PackageVersion)_$($target.Arch).msix"
  Invoke-Checked $MakeAppx @('pack', '/d', $layout, '/p', $msix, '/o')

  $zip = Join-Path $OutDir "Haymaker-$Version-windows-$($target.Arch).zip"
  Compress-Archive -Path $exe -DestinationPath $zip -Force
}

$Bundle = Join-Path $OutDir "Haymaker_$($PackageVersion)_x64_arm64.msixbundle"
Write-Host "== Bundling $Bundle"
Invoke-Checked $MakeAppx @('bundle', '/d', $Packages, '/p', $Bundle, '/bv', $PackageVersion, '/o')

Write-Host ''
Write-Host 'Store package (upload in Partner Center):'
Write-Host "  $Bundle"
Write-Host 'Portable builds:'
Get-ChildItem $OutDir -Filter '*.zip' | ForEach-Object { Write-Host "  $($_.FullName)" }
