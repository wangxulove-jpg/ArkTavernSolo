@echo off
rem ArkTavern Card Studio launcher: start the latest packaged portable exe.
rem If no exe exists, build it first with:  cd tools\card-studio && npm run dist
setlocal
set "LATEST="
for /f "delims=" %%F in ('dir /b /o-d "%~dp0tools\card-studio\release\ArkTavernCardStudio-Portable-*.exe" 2^>nul') do (
  if not defined LATEST set "LATEST=%%F"
)
if not defined LATEST (
  echo [ArkTavern Card Studio] packaged exe not found.
  echo Build it first:
  echo     cd tools\card-studio
  echo     npm run dist
  pause
  exit /b 1
)
echo Starting ArkTavern Card Studio: %LATEST%
start "" "%~dp0tools\card-studio\release\%LATEST%"
endlocal
