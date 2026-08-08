@echo off
call "%~dp0create-deploy.cmd" core
exit /b %errorlevel%
