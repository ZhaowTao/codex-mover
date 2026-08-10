# Dev utility: renders Codex Mover brand assets (icon PNG, multi-size ICO,
# README banner) with System.Drawing. Deterministic, no network.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$assets = Join-Path (Split-Path $PSScriptRoot -Parent) 'assets'
New-Item -ItemType Directory -Path $assets -Force | Out-Null

function New-RoundedRectPath {
    param([int]$X, [int]$Y, [int]$W, [int]$H, [int]$R)
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = $R * 2
    $p.AddArc($X, $Y, $d, $d, 180, 90)
    $p.AddArc($X + $W - $d, $Y, $d, $d, 270, 90)
    $p.AddArc($X + $W - $d, $Y + $H - $d, $d, $d, 0, 90)
    $p.AddArc($X, $Y + $H - $d, $d, $d, 90, 90)
    $p.CloseFigure()
    return $p
}

function New-DawnGradientBrush {
    param([float]$Size)
    $rect = New-Object System.Drawing.RectangleF(0, 0, $Size, $Size)
    $c1 = [System.Drawing.Color]::FromArgb(255, 255, 178, 122)   # #FFB27A warm
    $c2 = [System.Drawing.Color]::FromArgb(255, 79, 140, 255)    # #4F8CFF soft blue
    $brush = New-Object System.Drawing.Drawing2D.LinearGradientBrush($rect, $c1, $c2, 45.0)
    return $brush
}

function Add-Diamond {
    param($G, [float]$Cx, [float]$Cy, [float]$Half, $Brush)
    $pTop = New-Object System.Drawing.PointF($Cx, ($Cy - $Half))
    $pRight = New-Object System.Drawing.PointF(($Cx + $Half), $Cy)
    $pBottom = New-Object System.Drawing.PointF($Cx, ($Cy + $Half))
    $pLeft = New-Object System.Drawing.PointF(($Cx - $Half), $Cy)
    $pts = @($pTop, $pRight, $pBottom, $pLeft)
    $G.FillPolygon($Brush, $pts)
}

# ---------- Icon 512x512 ----------
$size = 512
$bmp = New-Object System.Drawing.Bitmap($size, $size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
$g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
$g.Clear([System.Drawing.Color]::Transparent)

$path = New-RoundedRectPath -X 0 -Y 0 -W $size -H $size -R 118
$bg = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 20, 20, 22))
$g.FillPath($bg, $path)
$borderPen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(70, 255, 178, 122), 4)
$g.DrawPath($borderPen, $path)

for ($i = 6; $i -ge 1; $i--) {
    $alpha = 16 * $i
    $glow = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb($alpha, 255, 178, 122))
    Add-Diamond -G $g -Cx 256 -Cy 256 -Half (116 + $i * 15) -Brush $glow
    $glow.Dispose()
}
$dBrush = New-DawnGradientBrush 512
Add-Diamond -G $g -Cx 256 -Cy 256 -Half 114 -Brush $dBrush
$dBrush.Dispose()

$iconPng = Join-Path $assets 'codex-mover-icon.png'
$bmp.Save($iconPng, [System.Drawing.Imaging.ImageFormat]::Png)
$g.Dispose(); $bmp.Dispose()

# ---------- ICO (16/24/32/48/64/128/256 PNG frames) ----------
function Write-MultiSizeIcon {
    param([string]$PngPath, [string]$IcoPath, [int[]]$Sizes)
    $source = [System.Drawing.Bitmap]::FromFile($PngPath)
    $images = New-Object System.Collections.Generic.List[byte[]]
    try {
        foreach ($s in $Sizes) {
            $small = New-Object System.Drawing.Bitmap($s, $s, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
            $sg = [System.Drawing.Graphics]::FromImage($small)
            $sg.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
            $sg.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $sg.DrawImage($source, 0, 0, $s, $s)
            $sg.Dispose()
            $ms = New-Object System.IO.MemoryStream
            $small.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
            $images.Add($ms.ToArray())
            $ms.Dispose(); $small.Dispose()
        }
    } finally {
        $source.Dispose()
    }
    $fs = [System.IO.File]::Create($IcoPath)
    $bw = New-Object System.IO.BinaryWriter($fs)
    $bw.Write([UInt16]0)
    $bw.Write([UInt16]1)
    $bw.Write([UInt16]$images.Count)
    $offset = 6 + 16 * $images.Count
    for ($i = 0; $i -lt $images.Count; $i++) {
        $s = $Sizes[$i]
        $dim = if ($s -ge 256) { 0 } else { $s }
        $bytes = $images[$i]
        $entry = New-Object System.IO.MemoryStream
        $ew = New-Object System.IO.BinaryWriter($entry)
        $ew.Write([Byte]$dim)
        $ew.Write([Byte]$dim)
        $ew.Write([Byte]0)
        $ew.Write([Byte]0)
        $ew.Write([UInt16]1)
        $ew.Write([UInt16]32)
        $ew.Write([UInt32]$bytes.Length)
        $ew.Write([UInt32]$offset)
        $bw.Write($entry.ToArray())
        $offset += $bytes.Length
        $ew.Dispose(); $entry.Dispose()
    }
    foreach ($im in $images) { $bw.Write($im) }
    $bw.Dispose(); $fs.Dispose()
}

Write-MultiSizeIcon -PngPath $iconPng -IcoPath (Join-Path $assets 'app-icon.ico') -Sizes @(16, 24, 32, 48, 64, 128, 256)

# ---------- Banner 1280x400 ----------
$bw = 1280; $bh = 400
$bmp = New-Object System.Drawing.Bitmap($bw, $bh, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
$g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
$g.Clear([System.Drawing.Color]::FromArgb(255, 18, 18, 20))

# Dawn glow, top-left
$glowRect = New-Object System.Drawing.Rectangle(-220, -260, 980, 980)
$c1 = [System.Drawing.Color]::FromArgb(70, 255, 178, 122)
$c2 = [System.Drawing.Color]::FromArgb(45, 79, 140, 255)
$glow = New-Object System.Drawing.Drawing2D.LinearGradientBrush($glowRect, $c1, $c2, 45.0)
$g.FillEllipse($glow, $glowRect)
$glow.Dispose()

# Large watermark diamond, right side
$wm = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(16, 255, 178, 122))
Add-Diamond -G $g -Cx 1080 -Cy 240 -Half 210 -Brush $wm
$wm.Dispose()

# Logo diamond
$dBrush = New-DawnGradientBrush 200
Add-Diamond -G $g -Cx 96 -Cy 150 -Half 46 -Brush $dBrush
$dBrush.Dispose()

# Title
$fTitle = New-Object System.Drawing.Font('Segoe UI', 54, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
$bTitle = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 245, 245, 247))
$g.DrawString('Codex Mover', $fTitle, $bTitle, 166, 96)

# Tagline
$fTag = New-Object System.Drawing.Font('Segoe UI', 22, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
$bTag = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 155, 155, 161))
$g.DrawString('Move Codex data off a full drive - safely.', $fTag, $bTag, 168, 172)

# by Dawn pill
$pill = New-RoundedRectPath -X 168 -Y 226 -W 128 -H 38 -R 19
$pillBrush = New-DawnGradientBrush 128
$g.FillPath($pillBrush, $pill)
$fBy = New-Object System.Drawing.Font('Segoe UI', 16, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
$bBy = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White)
$g.DrawString('by Dawn', $fBy, $bBy, 189, 234)

$banner = Join-Path $assets 'banner.png'
$bmp.Save($banner, [System.Drawing.Imaging.ImageFormat]::Png)
$g.Dispose(); $bmp.Dispose()

Get-ChildItem -LiteralPath $assets | Select-Object Name, Length
