# Build regolith_moon_bake GDExtension for Windows (MSVC + Erebus godot-cpp).
$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $PSScriptRoot
$ErebusCpp = if ($env:EREBUS_CPP) { $env:EREBUS_CPP } else { "Y:\Erebus\thirdparty\godot-cpp" }
$GodotCppLink = Join-Path $Root "native\godot-cpp"
$Lib = Join-Path $ErebusCpp "bin\libgodot-cpp.windows.template_debug.x86_64.lib"

if (-not (Test-Path $Lib)) {
	Write-Error "Missing Erebus godot-cpp at $ErebusCpp (expected $Lib)"
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
$Cmd = @"
call "$VcVars" >nul && cd /d "$BakeDir" && python -m SCons platform=windows target=template_debug arch=x86_64 build_library=no generate_bindings=no -j$Jobs
"@

Write-Host "Building with MSVC from $VsPath ..."
cmd /c $Cmd
if ($LASTEXITCODE -ne 0) {
	exit $LASTEXITCODE
}

$Out = Join-Path $Root "addons\regolith_moon_bake\bin\libregolith_moon_bake.windows.template_debug.x86_64.dll"
Write-Host "Built: $Out"
