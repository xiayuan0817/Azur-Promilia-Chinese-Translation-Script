@echo off
setlocal EnableExtensions DisableDelayedExpansion
chcp 65001 >nul
cd /d "%~dp0"
set "HINT="
if /i "%~1"=="update" (
    "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\Update-Localization.ps1"
    if errorlevel 43 call exit /b %%errorlevel%%
    if errorlevel 42 goto AUTO
    call exit /b %%errorlevel%%
)
if /i "%~1"=="check-update" (
    "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\Update-Localization.ps1" -CheckOnly
    call exit /b %%errorlevel%%
)
set "HINT=%~1"
if not defined HINT goto AUTO
if "%HINT:~-1%"=="\" set "HINT=%HINT%."
:WITH_HINT
(
    "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\Manage-Localization.ps1" -Hint "%HINT%"
    if errorlevel 42 if not errorlevel 43 goto RELOAD
    call set "RESULT=%%ERRORLEVEL%%"
    goto FINISH
)
:RELOAD
(
    cls
    if defined HINT goto WITH_HINT
    goto AUTO
)
:FINISH
(
    echo.
    echo 按任意键继续……
    pause >nul
    call exit /b %%RESULT%%
)
:AUTO
(
    "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\Manage-Localization.ps1"
    if errorlevel 42 if not errorlevel 43 goto RELOAD
    call set "RESULT=%%ERRORLEVEL%%"
    goto FINISH
)

