@echo off
setlocal

where python.exe >nul 2>nul || (
   echo ERROR: python.exe was not found in PATH.
   exit /b 1
)

python.exe "%~dp0stress-test.py" %*
exit /b %errorlevel%
