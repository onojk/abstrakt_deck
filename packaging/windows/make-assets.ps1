<#
.SYNOPSIS
  Regenerate the MSIX logo assets from the 512x512 app icon.

.DESCRIPTION
  Source: flatpak\io.github.onojk.abstrakt_deck.png (hexagon on a flat
  #0A0E14 square). Output: packaging\windows\Assets\*.png using MRT
  qualifiers (scale-*, targetsize-*, altform-unplated); build-msix.ps1 runs
  makepri so Windows picks the right file per context.

  * Tiles + Store logo keep the full dark square design.
  * Square44x44Logo (Start list, taskbar, title bar) uses the hexagon cut
    out onto a transparent background so it stays legible at 16-48 px.

  Run from the repo root:
    powershell -ExecutionPolicy Bypass -File packaging\windows\make-assets.ps1
#>
$ErrorActionPreference = 'Stop'
$Root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$Src  = Join-Path $Root 'flatpak\io.github.onojk.abstrakt_deck.png'
$Out  = Join-Path $PSScriptRoot 'Assets'
New-Item -ItemType Directory -Force $Out | Out-Null
Get-ChildItem $Out -Filter *.png | Remove-Item

Add-Type -AssemblyName System.Drawing
Add-Type -ReferencedAssemblies System.Drawing @"
using System; using System.Drawing; using System.Drawing.Drawing2D; using System.Drawing.Imaging;
public static class Icons {
    static readonly Color Bg = Color.FromArgb(10, 14, 20);

    // Remove the flat background colour with a soft matte so antialiased
    // edges keep their colour instead of a dark fringe.
    public static Bitmap Cutout(Bitmap src, Rectangle crop) {
        var o = new Bitmap(crop.Width, crop.Height, PixelFormat.Format32bppArgb);
        for (int y = 0; y < crop.Height; y++)
        for (int x = 0; x < crop.Width; x++) {
            Color c = src.GetPixel(crop.X + x, crop.Y + y);
            int d = Math.Max(Math.Abs(c.R - Bg.R), Math.Max(Math.Abs(c.G - Bg.G), Math.Abs(c.B - Bg.B)));
            double a = Math.Min(1.0, d / 90.0);
            if (a <= 0.0) { o.SetPixel(x, y, Color.Transparent); continue; }
            Func<int,int,int> un = (v, b) => (int)Math.Max(0, Math.Min(255, (v - b * (1 - a)) / a));
            o.SetPixel(x, y, Color.FromArgb((int)(a * 255), un(c.R, Bg.R), un(c.G, Bg.G), un(c.B, Bg.B)));
        }
        return o;
    }

    // Draw `img` scaled to fit (w*fill, h*fill), centred on a w x h canvas.
    public static void Save(Image img, int w, int h, double fill, bool darkBg, string path) {
        using (var bmp = new Bitmap(w, h, PixelFormat.Format32bppArgb))
        using (var g = Graphics.FromImage(bmp)) {
            g.Clear(darkBg ? Bg : Color.Transparent);
            g.InterpolationMode = InterpolationMode.HighQualityBicubic;
            g.PixelOffsetMode   = PixelOffsetMode.HighQuality;
            g.SmoothingMode     = SmoothingMode.HighQuality;
            g.CompositingQuality = CompositingQuality.HighQuality;
            double s = Math.Min(w * fill / img.Width, h * fill / img.Height);
            int dw = (int)Math.Round(img.Width * s), dh = (int)Math.Round(img.Height * s);
            using (var ia = new ImageAttributes()) {
                ia.SetWrapMode(WrapMode.TileFlipXY);   // no edge bleed when downscaling
                g.DrawImage(img, new Rectangle((w - dw) / 2, (h - dh) / 2, dw, dh),
                            0, 0, img.Width, img.Height, GraphicsUnit.Pixel, ia);
            }
            bmp.Save(path, ImageFormat.Png);
        }
    }
}
"@

$icon = [Drawing.Bitmap]::new($Src)
# Square crop around the hexagon (bbox x 104..406, y 124..387, centred on 256).
$hex  = [Icons]::Cutout($icon, [Drawing.Rectangle]::new(100, 100, 312, 312))
# The full icon minus some of its empty margin, for tiles.
$tile = $icon.Clone([Drawing.Rectangle]::new(64, 64, 384, 384), $icon.PixelFormat)

function Emit($img, $name, $w, $h, $fill, $dark) {
    [Icons]::Save($img, $w, $h, $fill, $dark, (Join-Path $Out $name))
    Write-Host ("  {0,-48} {1}x{2}" -f $name, $w, $h)
}

# Square44x44Logo: Start menu list, taskbar, title bar, Alt+Tab.
foreach ($s in @{100=44;125=55;150=66;200=88;400=176}.GetEnumerator()) {
    Emit $hex "Square44x44Logo.scale-$($s.Key).png" $s.Value $s.Value 0.92 $false
}
foreach ($t in 16,24,32,48,256) {
    Emit $hex "Square44x44Logo.targetsize-$t.png"                  $t $t 1.0 $false
    Emit $hex "Square44x44Logo.targetsize-${t}_altform-unplated.png" $t $t 1.0 $false
}
# Medium tile, wide tile, Store logo: full dark design.
foreach ($s in @{100=1;125=1.25;150=1.5;200=2;400=4}.GetEnumerator()) {
    $k = $s.Value
    Emit $tile "Square150x150Logo.scale-$($s.Key).png" ([int](150*$k)) ([int](150*$k)) 0.80 $true
    Emit $tile "Wide310x150Logo.scale-$($s.Key).png"   ([int](310*$k)) ([int](150*$k)) 0.80 $true
    Emit $icon "StoreLogo.scale-$($s.Key).png"         ([int](50*$k))  ([int](50*$k))  1.0  $true
}
$icon.Dispose(); $hex.Dispose(); $tile.Dispose()
Write-Host "Assets written to $Out"
