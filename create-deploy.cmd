@echo off
setlocal

set "DEPLOY_DIR=deploy"
set "INCLUDE_PLUGINS=1"
if /i "%~1"=="core" (
   set "DEPLOY_DIR=deploy-core"
   set "INCLUDE_PLUGINS=0"
) else if not "%~1"=="" (
   echo ERROR: Unsupported deployment mode: %~1
   exit /b 1
)

pushd "%~dp0" >nul || (
   echo ERROR: Cannot open the FuguHub working directory.
   exit /b 1
)

if exist "%DEPLOY_DIR%" rmdir /s /q "%DEPLOY_DIR%"
mkdir "%DEPLOY_DIR%\themes" || goto :failed

powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command ^
 "$ErrorActionPreference='Stop';" ^
 "Add-Type -AssemblyName System.IO.Compression;" ^
 "Add-Type -AssemblyName System.IO.Compression.FileSystem;" ^
 "$root=(Get-Location).Path;" ^
 "$includePlugins='%INCLUDE_PLUGINS%' -eq '1';" ^
 "$cmsZip=Join-Path $root '%DEPLOY_DIR%\cms.zip';" ^
 "$domainsZip=Join-Path $root '%DEPLOY_DIR%\CmsDomains.zip';" ^
 "$themeZip=Join-Path $root '%DEPLOY_DIR%\themes\default.zip';" ^
 "$dashboardZip=Join-Path $root '%DEPLOY_DIR%\themes\embedded-dashboard.zip';" ^
 "function New-PortableZip($source,$target){" ^
 "$source=(Resolve-Path $source).Path.TrimEnd('\');" ^
 "$stream=[IO.File]::Create($target);" ^
 "$zip=New-Object IO.Compression.ZipArchive($stream,[IO.Compression.ZipArchiveMode]::Create,$false);" ^
 "try{foreach($folder in @(Get-ChildItem -LiteralPath $source -Recurse -Directory)){" ^
 "$name=$folder.FullName.Substring($source.Length).TrimStart('\').Replace('\','/')+'/';" ^
 "$entry=$zip.CreateEntry($name,[IO.Compression.CompressionLevel]::Optimal);$entry.ExternalAttributes=16" ^
 "};foreach($item in @(Get-ChildItem -LiteralPath $source -Recurse -File)){" ^
 "$name=$item.FullName.Substring($source.Length).TrimStart('\').Replace('\','/');" ^
 "$entry=$zip.CreateEntry($name,[IO.Compression.CompressionLevel]::Optimal);" ^
 "$input=$item.OpenRead();$output=$entry.Open();try{$input.CopyTo($output)}finally{$output.Dispose();$input.Dispose()}" ^
 "}}finally{$zip.Dispose();$stream.Dispose()}};" ^
 "New-PortableZip (Join-Path $root 'cms') $cmsZip;" ^
 "if($includePlugins){$archive=[IO.Compression.ZipFile]::Open($cmsZip,[IO.Compression.ZipArchiveMode]::Update);" ^
 "try{$plugins=Join-Path $root 'plugins';$entry=$archive.CreateEntry('plugins/');$entry.ExternalAttributes=16;" ^
 "foreach($folder in @(Get-ChildItem -LiteralPath $plugins -Recurse -Directory)){" ^
 "$name='plugins/'+$folder.FullName.Substring($plugins.Length).TrimStart('\').Replace('\','/')+'/';" ^
 "$entry=$archive.CreateEntry($name);$entry.ExternalAttributes=16};" ^
 "foreach($item in @(Get-ChildItem -LiteralPath $plugins -Recurse -File)){" ^
 "$name='plugins/'+$item.FullName.Substring($plugins.Length).TrimStart('\').Replace('\','/');" ^
 "$entry=$archive.CreateEntry($name,[IO.Compression.CompressionLevel]::Optimal);" ^
 "$input=$item.OpenRead();$output=$entry.Open();try{$input.CopyTo($output)}finally{$output.Dispose();$input.Dispose()}" ^
 "}}finally{$archive.Dispose()}};" ^
 "if($includePlugins){New-PortableZip (Join-Path $root 'CmsDomains') $domainsZip};" ^
 "New-PortableZip (Join-Path $root 'themes\default') $themeZip;" ^
 "New-PortableZip (Join-Path $root 'themes\embedded-dashboard') $dashboardZip;" ^
 "$archive=[IO.Compression.ZipFile]::OpenRead($cmsZip);" ^
 "try{$names=@($archive.Entries.FullName);if($names -notcontains '.preload' -or $names -notcontains '.appinfo' -or $names -notcontains '.lua/admin.lua' -or $names -notcontains 'lib/.lua/fastmcp/engine.lua'){throw ('cms.zip has an invalid root layout: '+($names-join ', '))};if($includePlugins -and ($names -notcontains 'plugins/identity-access/.preload' -or $names -notcontains 'plugins/file-services/.preload' -or $names -notcontains 'plugins/large-file-mailer/.preload')){throw 'cms.zip is missing bundled plugins'};if(-not $includePlugins -and @($names|Where-Object{$_ -like 'plugins/*'}).Count -ne 0){throw 'core cms.zip unexpectedly contains plugins'}}finally{$archive.Dispose()};" ^
 "if($includePlugins){$archive=[IO.Compression.ZipFile]::OpenRead($domainsZip);" ^
 "try{$names=@($archive.Entries.FullName);if($names -notcontains '.preload'){throw 'CmsDomains.zip has an invalid root layout'}}finally{$archive.Dispose()}};" ^
 "$archive=[IO.Compression.ZipFile]::OpenRead($themeZip);" ^
 "try{$names=@($archive.Entries.FullName);if($names -notcontains 'theme.json' -or $names -notcontains 'templates/layout.lsp'){throw 'default.zip has an invalid root layout'}}finally{$archive.Dispose()};" ^
 "$archive=[IO.Compression.ZipFile]::OpenRead($dashboardZip);" ^
 "try{$names=@($archive.Entries.FullName);if($names -notcontains 'theme.json' -or $names -notcontains 'templates/layout.lsp'){throw 'embedded-dashboard.zip has an invalid root layout'}}finally{$archive.Dispose()}"

if errorlevel 1 goto :failed

echo Deployment created:
echo   %DEPLOY_DIR%\cms.zip
if "%INCLUDE_PLUGINS%"=="1" echo   %DEPLOY_DIR%\CmsDomains.zip
echo   %DEPLOY_DIR%\themes\default.zip
echo   %DEPLOY_DIR%\themes\embedded-dashboard.zip
popd >nul
exit /b 0

:failed
echo ERROR: Deployment creation failed.
if exist "%DEPLOY_DIR%" rmdir /s /q "%DEPLOY_DIR%"
popd >nul
pause
exit /b 1
