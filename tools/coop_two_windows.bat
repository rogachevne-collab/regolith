@echo off
REM =============================================================================
REM Coop two-window local check (host + guest on one machine).
REM
REM What it does:
REM   Opens two Godot windows for res://scenes/main.tscn.
REM   Left  = host  (--coop-autohost)
REM   Right = guest (--coop-sandbox=guest --coop-autojoin → 127.0.0.1)
REM
REM Usage:
REM   Double-click this file, or from cmd:
REM     Y:\regolith\tools\coop_two_windows.bat
REM
REM Optional env overrides (defaults match this machine):
REM   REGOLITH_GODOT   - path to Godot console binary
REM   REGOLITH_PROJECT - path to the Regolith project root
REM
REM How to stop:
REM   Close both game windows (or end the two Godot processes).
REM =============================================================================

setlocal EnableExtensions

if defined REGOLITH_GODOT (
	set "GODOT=%REGOLITH_GODOT%"
) else (
	set "GODOT=Y:\godot-engine\bin\godot.windows.editor.double.x86_64.console.exe"
)

if defined REGOLITH_PROJECT (
	set "PROJECT=%REGOLITH_PROJECT%"
) else (
	set "PROJECT=Y:\regolith"
)

if not exist "%GODOT%" (
	echo ERROR: Godot binary not found:
	echo   %GODOT%
	echo Set REGOLITH_GODOT to the console .exe, or install the double-precision build.
	exit /b 1
)

if not exist "%PROJECT%\project.godot" (
	echo ERROR: Regolith project not found:
	echo   %PROJECT%
	echo Set REGOLITH_PROJECT to the repo root containing project.godot.
	exit /b 1
)

REM Side-by-side layout for 1080p and 1440p: two 940x1000 windows.
REM Host left (20,30), guest right (980,30) — fits 1920-wide desktop.
set "HOST_RES=940x1000"
set "HOST_POS=20,30"
set "GUEST_RES=940x1000"
set "GUEST_POS=980,30"
set "SCENE=res://scenes/main.tscn"

echo Coop two windows:
echo   Godot:   %GODOT%
echo   Project: %PROJECT%
echo   Host:    left  %HOST_RES% @ %HOST_POS%  --coop-autohost
echo   Guest:   right %GUEST_RES% @ %GUEST_POS%  --coop-sandbox=guest --coop-autojoin
echo.

start "Regolith Coop Host" "%GODOT%" --path "%PROJECT%" --resolution %HOST_RES% --position %HOST_POS% %SCENE% -- --coop-autohost

REM Let the host bind INSTANCE_LOCK_PORT (47800) before the guest starts.
timeout /t 2 /nobreak >nul

start "Regolith Coop Guest" "%GODOT%" --path "%PROJECT%" --resolution %GUEST_RES% --position %GUEST_POS% %SCENE% -- --coop-sandbox=guest --coop-autojoin

echo Both windows launched. Close them when done.
endlocal
exit /b 0
