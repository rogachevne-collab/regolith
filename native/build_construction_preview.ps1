# Build regolith_construction_preview GDExtension for Windows (MSVC + godot-cpp).
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
	Write-Error "MSVC x64 tools not found"
}
$VcVars = Join-Path $VsPath "VC\Auxiliary\Build\vcvars64.bat"

$Jobs = [Environment]::ProcessorCount
$SrcDir = Join-Path $Root "native\regolith_construction_preview"
$PrecisionArg = if ($Precision -eq "double") { "precision=double" } else { "" }
$Cmd = @"
call "$VcVars" >nul && cd /d "$SrcDir" && python -m SCons platform=windows target=template_debug arch=x86_64 $PrecisionArg build_library=no generate_bindings=no -j$Jobs
"@

Write-Host "Building construction_preview with MSVC (precision=$Precision) ..."
cmd /c $Cmd
if ($LASTEXITCODE -ne 0) {
	exit $LASTEXITCODE
}

$OutSuffix = if ($Precision -eq "double") { "double.x86_64" } else { "x86_64" }
$Out = Join-Path $Root "addons\regolith_construction_preview\bin\libregolith_construction_preview.windows.template_debug.$OutSuffix.dll"
Write-Host "Built: $Out"
