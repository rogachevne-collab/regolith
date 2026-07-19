# Build Godot editor from Y:\godot-engine with precision=double (large world coords).
# Prerequisite: VS 2022 C++ tools, Python 3.9+, SCons 4.4+.
# Output: Y:\godot-engine\bin\godot.windows.editor.double.x86_64.exe
$ErrorActionPreference = "Stop"

$Src = if ($env:GODOT_SRC) { $env:GODOT_SRC } else { "Y:\godot-engine" }
if (-not (Test-Path (Join-Path $Src "SConstruct"))) {
	Write-Error "Godot source not found at $Src (set GODOT_SRC or clone to Y:\godot-engine)"
}

$Jobs = [Environment]::ProcessorCount
Write-Host "Building Godot editor precision=double from $Src (-j$Jobs) ..."
Write-Host "This typically takes 20-60+ minutes on first build."

Set-Location $Src
## Skip optional Windows deps (AccessKit / D3D12 SDKs). Vulkan remains available.
python -m SCons platform=windows target=editor arch=x86_64 precision=double accesskit=no d3d12=no -j$Jobs
if ($LASTEXITCODE -ne 0) {
	exit $LASTEXITCODE
}

$Out = Join-Path $Src "bin\godot.windows.editor.double.x86_64.exe"
if (-not (Test-Path $Out)) {
	# Fallback: some builds append .console or different naming
	$Out = Get-ChildItem (Join-Path $Src "bin") -Filter "godot.windows.editor.double*.exe" |
		Where-Object { $_.Name -notmatch "console" } |
		Select-Object -First 1 -ExpandProperty FullName
}
Write-Host "Built: $Out"
Write-Host "API dump dir: Y:\godot-engine\double-api"
Write-Host "godot-cpp double: Y:\godot-cpp-double"
Write-Host "Voxel source: Y:\godot_voxel (GODOT_CPP_PATH=Y:\godot-cpp-double)"
Write-Host "After rebuild, copy *.double.*.dll over the names in addons/*/bin expected by .gdextension"
