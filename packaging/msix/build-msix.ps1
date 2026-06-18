#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Build an MSIX package for nvg from a prebuilt nvg.exe.

.DESCRIPTION
  Stages AppxManifest.xml (with tokens substituted), the executable and the
  logo assets into a layout directory, then runs makeappx to produce a .msix.

  For Microsoft Store submission leave the package UNSIGNED — Microsoft re-signs
  it during certification. For local testing, pass -Sign to sign with a
  self-signed certificate (its subject must equal -Publisher), or skip signing
  entirely and register the staged layout with:
      Add-AppxPackage -Register <layout>\AppxManifest.xml   # needs Developer Mode

.PARAMETER ExePath
  Path to the prebuilt nvg.exe (GUI-subsystem Windows release binary).

.PARAMETER OutFile
  Output .msix path. Default: packaging/msix/out/nvg.msix

.PARAMETER Version
  4-part MSIX version. Default: derived from build.zig.zon as <ver>.0
  (the 4th part must be 0 — the Store reserves it).

.PARAMETER IdentityName / Publisher / PublisherDisplayName
  Package identity. Defaults are placeholders for local builds; for the Store
  pass the exact values reserved in Partner Center (Product identity).

.PARAMETER Sign
  Sign the produced .msix with a self-signed cert (subject = Publisher).
  Local testing only — never needed for Store submission.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string]$ExePath,
    [string]$OutFile,
    [string]$Version,
    [string]$IdentityName        = 'BitBrewers.nvg',
    [string]$Publisher           = 'CN=Bit Brewers',
    [string]$PublisherDisplayName = 'Bit Brewers',
    [switch]$Sign
)

$ErrorActionPreference = 'Stop'
$scriptDir = $PSScriptRoot
$repoRoot  = (Resolve-Path (Join-Path $scriptDir '..\..')).Path

if (-not (Test-Path $ExePath)) { throw "nvg.exe not found at: $ExePath" }
if (-not $OutFile) { $OutFile = Join-Path $scriptDir 'out\nvg.msix' }

# ── Derive version from build.zig.zon if not supplied ──
if (-not $Version) {
    $zon = Get-Content (Join-Path $repoRoot 'build.zig.zon') -Raw
    if ($zon -notmatch '\.version\s*=\s*"([^"]+)"') { throw 'Could not read .version from build.zig.zon' }
    $v = $Matches[1]                      # e.g. 1.1.1
    $parts = $v.Split('.')
    while ($parts.Count -lt 3) { $parts += '0' }
    $Version = "{0}.{1}.{2}.0" -f $parts[0], $parts[1], $parts[2]   # 4th part = 0 (Store reserved)
}
Write-Host "MSIX version: $Version"

# ── Locate makeappx (newest installed Windows SDK) ──
$sdkBin = 'C:\Program Files (x86)\Windows Kits\10\bin'
$makeappx = Get-ChildItem -Path $sdkBin -Recurse -Filter makeappx.exe -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -match '\\x64\\' } |
    Sort-Object FullName -Descending | Select-Object -First 1 -ExpandProperty FullName
if (-not $makeappx) { throw "makeappx.exe not found under $sdkBin (install the Windows SDK)" }
Write-Host "makeappx: $makeappx"

# ── Stage the package layout ──
$layout = Join-Path $scriptDir 'layout'
if (Test-Path $layout) { Remove-Item -Recurse -Force $layout }
New-Item -ItemType Directory -Force -Path (Join-Path $layout 'Assets') | Out-Null

$manifest = Get-Content (Join-Path $scriptDir 'AppxManifest.xml') -Raw
$manifest = $manifest.Replace('__IDENTITY_NAME__', $IdentityName).
                      Replace('__PUBLISHER__', $Publisher).
                      Replace('__PUBLISHER_DISPLAY_NAME__', $PublisherDisplayName).
                      Replace('__VERSION__', $Version)
Set-Content -Path (Join-Path $layout 'AppxManifest.xml') -Value $manifest -Encoding UTF8

Copy-Item $ExePath (Join-Path $layout 'nvg.exe') -Force
Copy-Item (Join-Path $scriptDir 'Assets\*') (Join-Path $layout 'Assets') -Force

# ── Pack ──
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $OutFile) | Out-Null
& $makeappx pack /o /d $layout /p $OutFile
if ($LASTEXITCODE -ne 0) { throw "makeappx failed ($LASTEXITCODE)" }
Write-Host "Built: $OutFile"

# ── Optional self-signed signing (local testing only) ──
if ($Sign) {
    $signtool = Get-ChildItem -Path $sdkBin -Recurse -Filter signtool.exe -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match '\\x64\\' } |
        Sort-Object FullName -Descending | Select-Object -First 1 -ExpandProperty FullName
    if (-not $signtool) { throw 'signtool.exe not found' }

    $cert = Get-ChildItem Cert:\CurrentUser\My | Where-Object { $_.Subject -eq $Publisher } | Select-Object -First 1
    if (-not $cert) {
        Write-Host "Creating self-signed cert for $Publisher"
        $cert = New-SelfSignedCertificate -Type Custom -Subject $Publisher `
            -KeyUsage DigitalSignature -FriendlyName 'nvg MSIX test' `
            -CertStoreLocation 'Cert:\CurrentUser\My' `
            -TextExtension @('2.5.29.37={text}1.3.6.1.5.5.7.3.3', '2.5.29.19={text}')
    }
    & $signtool sign /fd SHA256 /a /sha1 $cert.Thumbprint $OutFile
    if ($LASTEXITCODE -ne 0) { throw "signtool failed ($LASTEXITCODE)" }
    Write-Host "Signed: $OutFile"
}
