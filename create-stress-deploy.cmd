@echo off
setlocal

pushd "%~dp0" >nul || (
   echo ERROR: Cannot open the FuguHub working directory.
   exit /b 1
)

where python.exe >nul 2>nul || (
   echo ERROR: python.exe was not found in PATH.
   popd >nul
   exit /b 1
)

call create-core-deploy.cmd
if errorlevel 1 goto :failed

if exist "deploy-stress" rmdir /s /q "deploy-stress"
mkdir "deploy-stress\themes" || goto :failed

copy /y "deploy-core\cms.zip" "deploy-stress\cms.zip" >nul || goto :failed
copy /y "deploy-core\themes\default.zip" "deploy-stress\themes\default.zip" >nul || goto :failed
copy /y "deploy-core\themes\embedded-dashboard.zip" "deploy-stress\themes\embedded-dashboard.zip" >nul || goto :failed

python.exe "stress\build_seed.py" --runtime "deploy-stress" --manifest "stress\urls.txt"
if errorlevel 1 goto :failed

echo.
echo Stress deployment created:
echo   deploy-stress\cms.zip
echo   deploy-stress\themes\default.zip
echo   deploy-stress\themes\embedded-dashboard.zip
echo   deploy-stress\data\cms.sqlite.db
echo   deploy-stress\stress-urls.txt
echo.
echo Start from deploy-stress with:
echo   mako -l::cms.zip
popd >nul
exit /b 0

:failed
echo ERROR: Stress deployment creation failed.
if exist "deploy-stress" rmdir /s /q "deploy-stress"
popd >nul
exit /b 1
