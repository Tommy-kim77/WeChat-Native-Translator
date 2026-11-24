param([Parameter(Mandatory=$true)][string]$EnginePath)
$ErrorActionPreference = 'Stop'
$engine = (Resolve-Path -LiteralPath $EnginePath).Path
$expected = '820ac63a769dd673958e56bd835ff5b6fffb5764269e0cb60b097869e1654a31'
if ((Get-FileHash -LiteralPath $engine).Hash -ne $expected) { throw 'Engine hash mismatch' }
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$release = Join-Path $PSScriptRoot 'Releases\v0.1.36'
New-Item -ItemType Directory -Force $release | Out-Null
$app = Join-Path $release 'WeChat-Native-Translator-Windows-v0.1.36-x64.exe'
$sources = Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.cs' | ForEach-Object FullName
& $compiler /nologo /target:winexe /platform:x64 /optimize+ /codepage:65001 /reference:System.dll /reference:System.Core.dll /reference:System.Drawing.dll /reference:System.Windows.Forms.dll "/reference:$(Join-Path (Split-Path $compiler) 'WPF\UIAutomationClient.dll')" "/reference:$(Join-Path (Split-Path $compiler) 'WPF\UIAutomationTypes.dll')" /reference:System.Net.Http.dll /reference:System.Security.dll /reference:System.Web.Extensions.dll "/out:$app" "/win32icon:$(Join-Path $PSScriptRoot 'AppIcon.ico')" "/resource:$(Join-Path $PSScriptRoot 'AppIcon.ico'),app.icon" "/resource:$engine,engine.wx" "/resource:$(Join-Path $PSScriptRoot 'AGENT-WECHAT-LICENSE'),engine.license" @sources
if ($LASTEXITCODE -ne 0) { throw 'Windows build failed' }
Get-Item -LiteralPath $app | Select-Object FullName,Length
