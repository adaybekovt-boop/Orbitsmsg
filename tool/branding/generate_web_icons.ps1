# Generates the Orbits web/PWA/Safari icon set from the brand source PNG.
#
# Source: tool/branding/orbits_icon_source.png — the glass squircle on a
# TRANSPARENT background. We flatten it onto an opaque dark navy (#0A0E16,
# sampled from the icon interior) so Safari "Add to Home Screen" / favicons
# never composite the transparency onto black ("black junk"), and the result
# reads as a premium dark glass app tile.
#
# Outputs (PNG, opaque):
#   web/favicon.png                     64,  fill 0.94
#   web/icons/Icon-192.png              192, fill 0.92
#   web/icons/Icon-512.png              512, fill 0.92
#   web/icons/Icon-maskable-192.png     192, fill 0.74  (safe zone for masks)
#   web/icons/Icon-maskable-512.png     512, fill 0.74
#   web/apple-touch-icon.png            180, fill 0.92
#
# Re-run after changing the source:  pwsh tool/branding/generate_web_icons.ps1
param(
  [string]$Src = "tool/branding/orbits_icon_source.png",
  [string]$WebDir = "web"
)
Add-Type -AssemblyName System.Drawing

$srcBmp = New-Object System.Drawing.Bitmap((Resolve-Path $Src).Path)

# Opaque-content bounding box (detected) with a small safety pad, clamped.
$cx = 114; $cy = 117; $cw = 984; $ch = 972
if ($cx + $cw -gt $srcBmp.Width)  { $cw = $srcBmp.Width  - $cx }
if ($cy + $ch -gt $srcBmp.Height) { $ch = $srcBmp.Height - $cy }

$crop = New-Object System.Drawing.Bitmap($cw, $ch, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$gc = [System.Drawing.Graphics]::FromImage($crop)
$gc.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
$gc.DrawImage($srcBmp,
  (New-Object System.Drawing.Rectangle(0, 0, $cw, $ch)),
  (New-Object System.Drawing.Rectangle($cx, $cy, $cw, $ch)),
  [System.Drawing.GraphicsUnit]::Pixel)
$gc.Dispose()

$bg = [System.Drawing.Color]::FromArgb(255, 0x0A, 0x0E, 0x16)

function Make-Icon([int]$size, [double]$fill, [string]$outPath) {
  $out = New-Object System.Drawing.Bitmap($size, $size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $g = [System.Drawing.Graphics]::FromImage($out)
  $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
  $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
  $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
  $g.Clear($bg)
  $target = [int][Math]::Round($size * $fill)
  $scale = $target / [Math]::Max($crop.Width, $crop.Height)
  $dw = [int][Math]::Round($crop.Width * $scale)
  $dh = [int][Math]::Round($crop.Height * $scale)
  $dx = [int][Math]::Round(($size - $dw) / 2.0)
  $dy = [int][Math]::Round(($size - $dh) / 2.0)
  $g.DrawImage($crop, (New-Object System.Drawing.Rectangle($dx, $dy, $dw, $dh)))
  $g.Dispose()
  $full = Join-Path (Get-Location) $outPath
  $out.Save($full, [System.Drawing.Imaging.ImageFormat]::Png)
  $out.Dispose()
  Write-Output ("wrote {0}  ({1}x{1}, fill={2})" -f $outPath, $size, $fill)
}

New-Item -ItemType Directory -Force -Path (Join-Path $WebDir "icons") | Out-Null
Make-Icon 64  0.94 (Join-Path $WebDir "favicon.png")
Make-Icon 192 0.92 (Join-Path $WebDir "icons/Icon-192.png")
Make-Icon 512 0.92 (Join-Path $WebDir "icons/Icon-512.png")
Make-Icon 192 0.74 (Join-Path $WebDir "icons/Icon-maskable-192.png")
Make-Icon 512 0.74 (Join-Path $WebDir "icons/Icon-maskable-512.png")
Make-Icon 180 0.92 (Join-Path $WebDir "apple-touch-icon.png")

$crop.Dispose()
$srcBmp.Dispose()
Write-Output "done."
