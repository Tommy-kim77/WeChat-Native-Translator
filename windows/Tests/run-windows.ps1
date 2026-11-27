$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
$output = Join-Path (Split-Path $root) '.build\windows-regression-v0.1.37'
New-Item -ItemType Directory -Force $output | Out-Null
Start-Transcript -Path (Join-Path $output 'build-test.log') -Force
try {
  $previous = Join-Path $root 'Releases\v0.1.36\WeChat-Native-Translator-Windows-v0.1.36-x64.exe'
  $assembly = [Reflection.Assembly]::Load([IO.File]::ReadAllBytes($previous))
  $resource = $assembly.GetManifestResourceStream('engine.wx')
  $engine = Join-Path $output 'wx.exe'
  $file = [IO.File]::Create($engine)
  try { $resource.CopyTo($file) } finally { $file.Dispose(); $resource.Dispose() }
  & (Join-Path $root 'build.ps1') -EnginePath $engine
  $compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
  $binary = Join-Path $env:TEMP 'wechat-regression-v0.1.37.exe'
  $sources = @(Get-ChildItem -LiteralPath $root -Filter '*.cs' | ForEach-Object FullName)
  $sources += Join-Path $PSScriptRoot 'Regression.cs'
  & $compiler /nologo /target:exe /main:Regression /platform:x64 /codepage:65001 /reference:System.dll /reference:System.Core.dll /reference:System.Drawing.dll /reference:System.Windows.Forms.dll "/reference:$(Join-Path (Split-Path $compiler) 'WPF\UIAutomationClient.dll')" "/reference:$(Join-Path (Split-Path $compiler) 'WPF\UIAutomationTypes.dll')" /reference:System.Net.Http.dll /reference:System.Security.dll /reference:System.Web.Extensions.dll "/out:$binary" @sources
  if ($LASTEXITCODE -ne 0) { throw 'Regression compilation failed' }
  & $binary (Join-Path $PSScriptRoot 'outgoing-language-cases.json') | Tee-Object -FilePath (Join-Path $output 'results.txt')
  if ($LASTEXITCODE -ne 0) { throw 'Regression tests failed' }
  $app = Join-Path $root 'Releases\v0.1.37\WeChat-Native-Translator-Windows-v0.1.37-x64.exe'
  $report = Join-Path $output 'package.txt'
  $localApp = Join-Path $env:TEMP 'WeChat-Native-Translator-Windows-v0.1.37-x64.exe'
  Copy-Item $app $localApp -Force
  $smoke = Start-Process -FilePath $localApp -ArgumentList @('--verify-package',('"'+$report+'"')) -Wait -PassThru
  if ($smoke.ExitCode -ne 0) { throw 'Package smoke failed' }
  Get-Content $report
  Get-FileHash $app -Algorithm SHA256
  'PASS: build, UI regression and isolated engine package verification' | Set-Content (Join-Path $output 'COMPLETE.txt')
} finally { Stop-Transcript }
