# Export a playable Windows debug build (custom Godot precision=double).
# Prerequisites:
#   1) Godot template_debug double at Y:\godot-engine\bin\...
#      scons platform=windows target=template_debug arch=x86_64 precision=double accesskit=no d3d12=no
#   2) Voxel double editor DLL at addons/zylann.voxel/bin/libvoxel.windows.editor.double.x86_64.dll
#   3) export_presets.cfg preset "Windows Desktop"
$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $PSScriptRoot
$Godot = if ($env:GODOT) { $env:GODOT } else { "Y:\godot-engine\bin\godot.windows.editor.double.x86_64.exe" }
$Template = "Y:\godot-engine\bin\godot.windows.template_debug.double.x86_64.exe"
$OutDir = Join-Path $Root "build\windows"
$OutExe = Join-Path $OutDir "Regolith.exe"
$VoxelDll = Join-Path $Root "addons\zylann.voxel\bin\libvoxel.windows.editor.double.x86_64.dll"

if (-not (Test-Path $Godot)) {
	Write-Error "Editor not found: $Godot"
}
if (-not (Test-Path $Template)) {
	Write-Error @"
Missing double template_debug:
  $Template
Build it first (20-60+ min):
  cd Y:\godot-engine
  python -m SCons platform=windows target=template_debug arch=x86_64 precision=double accesskit=no d3d12=no
"@
}
if (-not (Test-Path $VoxelDll)) {
	Write-Error "Missing Voxel double DLL: $VoxelDll"
}

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
Write-Host "Exporting Windows debug -> $OutExe"
Write-Host "Editor:   $(& $Godot --version)"
Write-Host "Template: $Template"

# cmd.exe keeps "Windows Desktop" as one argv; PowerShell splitting would break the preset name.
# Godot prints non-fatal noise to stderr (plugins) — don't let PS Stop on it.
$prevEap = $ErrorActionPreference
$ErrorActionPreference = "Continue"
$cmd = "`"$Godot`" --headless --path `"$Root`" --export-debug `"Windows Desktop`" `"$OutExe`""
cmd /c $cmd
$exportExit = $LASTEXITCODE
$ErrorActionPreference = $prevEap
if ($exportExit -ne 0) {
	exit $exportExit
}

if (-not (Test-Path $OutExe)) {
	Write-Error "Export finished but exe missing: $OutExe"
}

Write-Host "Built: $OutExe"
Get-ChildItem $OutDir | Format-Table Name, Length, LastWriteTime
