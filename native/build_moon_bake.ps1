# Build regolith_moon_bake GDExtension for Windows (MSVC + godot-cpp).
#
# The project runs a `precision=double` Godot (tools/build_godot_double.ps1),
# so the extension has to match: a single-precision library loaded into a
# double engine is an ABI mismatch. `native\godot-cpp` carries the double
# bindings, and the single-precision ones are not there to link against at all.
param([ValidateSet("double", "single")][string]$Precision = "double")

$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $PSScriptRoot
$ErebusCpp = if ($env:EREBUS_CPP) { $env:EREBUS_CPP } else { "Y:\Erebus\thirdparty\godot-cpp" }
$GodotCppLink = Join-Path $Root "native\godot-cpp"
$LibSuffix = if ($Precision -eq "double") { "double.x86_64" } else { "x86_64" }
$Lib = Join-Path $GodotCppLink "bin\libgodot-cpp.windows.template_debug.$LibSuffix.lib"

if (-not (Test-Path $Lib)) {
	Write-Error "Missing godot-cpp bindings for precision=$Precision (expected $Lib)"
}

if (-not (Test-Path $GodotCppLink)) {
	cmd /c "mklink /J `"$GodotCppLink`" `"$ErebusCpp`"" | Out-Null
	Write-Host "Linked native\godot-cpp -> $ErebusCpp"
}

$VsWhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path $VsWhere)) {
	Write-Error "vswhere not found — install Visual Studio 2022 Build Tools with C++ workload"
}
$VsPath = & $VsWhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $VsPath) {
	Write-Error "MSVC x64 tools not found — install VS 2022 Build Tools (Desktop development with C++)"
}
$VcVars = Join-Path $VsPath "VC\Auxiliary\Build\vcvars64.bat"
if (-not (Test-Path $VcVars)) {
	Write-Error "vcvars64.bat missing at $VcVars"
}

$Jobs = [Environment]::ProcessorCount
$BakeDir = Join-Path $Root "native\regolith_moon_bake"
$PrecisionArg = if ($Precision -eq "double") { "precision=double" } else { "" }
$Cmd = @"
call "$VcVars" >nul && cd /d "$BakeDir" && python -m SCons platform=windows target=template_debug arch=x86_64 $PrecisionArg build_library=no generate_bindings=no -j$Jobs
"@

Write-Host "Building with MSVC from $VsPath (precision=$Precision) ..."
cmd /c $Cmd
if ($LASTEXITCODE -ne 0) {
	exit $LASTEXITCODE
}

$OutSuffix = if ($Precision -eq "double") { "double.x86_64" } else { "x86_64" }
$Out = Join-Path $Root "addons\regolith_moon_bake\bin\libregolith_moon_bake.windows.template_debug.$OutSuffix.dll"
Write-Host "Built: $Out"
