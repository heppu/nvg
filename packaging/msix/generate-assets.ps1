#!/usr/bin/env pwsh
# generate-assets.ps1 — regenerate placeholder MSIX logo assets.
#
# These are simple brand-coloured placeholders (a green focus chevron on the
# dark nvg background). Replace them with real artwork before the public Store
# listing; the sizes/filenames must stay the same to match AppxManifest.xml.
#
# Usage:  pwsh packaging/msix/generate-assets.ps1

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$assetsDir = Join-Path $PSScriptRoot 'Assets'
New-Item -ItemType Directory -Force -Path $assetsDir | Out-Null

# nvg brand palette (matches the website / app background).
$bg    = [System.Drawing.Color]::FromArgb(255, 0x0b, 0x0d, 0x0c)
$green = [System.Drawing.Color]::FromArgb(255, 0x4a, 0xf6, 0x26)

function New-Logo([int]$size, [string]$path) {
    $bmp = New-Object System.Drawing.Bitmap($size, $size)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    try {
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.Clear($bg)
        # A right-pointing chevron ("move focus →"), centred.
        $brush = New-Object System.Drawing.SolidBrush($green)
        $m = $size * 0.30           # margin
        $pts = @(
            (New-Object System.Drawing.PointF($m, $m)),
            (New-Object System.Drawing.PointF(($size - $m), ($size / 2.0))),
            (New-Object System.Drawing.PointF($m, ($size - $m)))
        )
        $g.FillPolygon($brush, $pts)
        $brush.Dispose()
        $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
        Write-Host "wrote $path ($size x $size)"
    } finally {
        $g.Dispose(); $bmp.Dispose()
    }
}

New-Logo 44  (Join-Path $assetsDir 'Square44x44Logo.png')
New-Logo 150 (Join-Path $assetsDir 'Square150x150Logo.png')
New-Logo 50  (Join-Path $assetsDir 'StoreLogo.png')
