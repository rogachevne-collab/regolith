# Windows launcher for stock Godot (mirrors run.sh).
$ErrorActionPreference = "Stop"

$Root = $PSScriptRoot

function Pick-Godot {
	if ($env:GODOT -and (Test-Path $env:GODOT)) {
		return $env:GODOT
	}
	$candidates = @(
		"Y:\Godot\Godot_v4.7.1-stable_win64_console.exe",
		"Y:\Godot\Godot_v4.7.1-stable_win64.exe"
	)
	foreach ($c in $candidates) {
		if (Test-Path $c) { return $c }
	}
	$fromPath = Get-Command godot -ErrorAction SilentlyContinue
	if ($fromPath) { return $fromPath.Source }
	return $null
}

$GodotBin = Pick-Godot
if (-not $GodotBin) {
	Write-Error "Godot 4.7.1 not found. Put it in Y:\Godot\ or set GODOT=C:\path\to\Godot.exe"
}

$VoxelExt = Join-Path $Root "addons\zylann.voxel\voxel.gdextension"
if (-not (Test-Path $VoxelExt)) {
	Write-Error "Missing GDExtension plugin at addons/zylann.voxel/. See README bootstrap."
}

$VoxelDll = Join-Path $Root "addons\zylann.voxel\bin\libvoxel.windows.editor.x86_64.dll"
if (-not (Test-Path $VoxelDll)) {
	Write-Error "Missing Windows Voxel Tools DLL. Run README bootstrap (download GodotVoxelExtension.zip)."
}

Write-Host "Using: $(& $GodotBin --version)"
Set-Location $Root
& $GodotBin --path $Root @args
exit $LASTEXITCODE
