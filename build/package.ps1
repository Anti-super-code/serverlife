<#
.SYNOPSIS
    Builds the download that goes on the website: a framework-dependent x64 folder,
    zipped, with a SHA-256 beside it.

.DESCRIPTION
    Run from anywhere; paths are resolved relative to the repository root.
    Output lands in dist\ and is not committed.

        pwsh build\package.ps1
        pwsh build\package.ps1 -SkipTests     # only when you already ran them
#>
[CmdletBinding()]
param(
    [switch]$SkipTests
)

$ErrorActionPreference = 'Stop'

$repo = Split-Path -Parent $PSScriptRoot
$dist = Join-Path $repo 'dist'

# The SDK is installed per-user here, so it is not on PATH for a bare shell.
$userSdk = Join-Path $env:LOCALAPPDATA 'Microsoft\dotnet'
if (Test-Path $userSdk) { $env:PATH = "$userSdk;$env:PATH" }

$version = ([xml](Get-Content (Join-Path $repo 'src\Serverlife\Serverlife.csproj'))).
            Project.PropertyGroup.Version | Where-Object { $_ } | Select-Object -First 1
$name = "Serverlife-$version-win-x64"
$stage = Join-Path $dist $name
$zip = Join-Path $dist "$name.zip"

Write-Host "Packaging Serverlife $version" -ForegroundColor Cyan

# No test project exists yet (tests\ is a placeholder) - nothing to run today, but the
# switch stays so this script doesn't need editing the day one lands.
if (-not $SkipTests -and (Get-ChildItem (Join-Path $repo 'tests') -Recurse -Filter *.csproj -ErrorAction SilentlyContinue)) {
    Write-Host '-> tests'
    dotnet test $repo --nologo -v q
    if ($LASTEXITCODE -ne 0) { throw 'Tests failed — not packaging.' }
}

Write-Host '-> publish'
dotnet publish (Join-Path $repo 'src\Serverlife') `
    -c Release -r win-x64 --self-contained false -o $stage -v q --nologo
if ($LASTEXITCODE -ne 0) { throw 'Publish failed.' }

Write-Host '-> licences and read-me'
Copy-Item (Join-Path $repo 'LICENSE') $stage -Force
Copy-Item (Join-Path $repo 'THIRD-PARTY-NOTICES.md') $stage -Force
Copy-Item (Join-Path $repo 'licenses') $stage -Recurse -Force

@"
Serverlife $version
====================

1. If Windows says the .NET Desktop Runtime is missing, install it from
   https://dotnet.microsoft.com/download/dotnet/8.0/runtime  (Desktop Runtime, x64).

2. Move this folder somewhere permanent first - Documents, or
   %LOCALAPPDATA%\Programs\Serverlife. The right-click menu remembers where the app
   is, so moving it afterwards breaks the menu entry.

3. Run Serverlife.exe. Windows will warn that the publisher is unknown, because the
   app is not code-signed: choose More info -> Run anyway.

4. It lands in the notification area. Left-click the tray icon to bring the panel
   back; Quit is on its right-click menu.

5. Click the round gear icon, then switch on "Right-click menu" if you want
   "Start server here" on folders in Explorer - on the folder icon itself or in its
   empty space, including "Show more options" on Windows 11.

To uninstall: switch "Right-click menu" back off, quit from the tray, delete this
folder, and delete %APPDATA%\Serverlife.

Use at your own risk - see LICENSE and the disclaimer in README on the website.
Source: https://github.com/Anti-super-code/serverlife
"@ | Set-Content (Join-Path $stage 'READ-ME-FIRST.txt') -Encoding utf8

# Belt and braces: Release already sets DebugType=none, but never ship symbols.
Get-ChildItem $stage -Filter *.pdb -Recurse | ForEach-Object { [System.IO.File]::Delete($_.FullName) }

Write-Host '-> zip'
if (Test-Path $zip) { [System.IO.File]::Delete($zip) }
Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip -CompressionLevel Optimal

$hash = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower()
"$hash  $name.zip" | Set-Content "$zip.sha256" -Encoding ascii

$folderMb = [math]::Round((Get-ChildItem $stage -Recurse -File | Measure-Object Length -Sum).Sum / 1MB, 1)
$zipMb = [math]::Round((Get-Item $zip).Length / 1MB, 1)

Write-Host ''
Write-Host "  zip       $zip" -ForegroundColor Green
Write-Host "  download  $zipMb MB   (extracts to $folderMb MB)"
Write-Host "  sha256    $hash"
