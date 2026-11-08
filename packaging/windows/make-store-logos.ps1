<#
.SYNOPSIS
  Render the Microsoft Store listing logos into packaging\windows\store\logos\.

.DESCRIPTION
  The hexagon icon is redrawn as vector geometry (measured from
  flatpak\io.github.onojk.abstrakt_deck.png: flat-top hexagon, alternating
  red/orange triangles, cyan ring, yellow centre) so it is sharp at 2160 px.
  Backgrounds are crops of the Store screenshots, upscaled with
  high-quality bicubic filtering. All outputs are opaque 24-bit sRGB PNGs.

    boxart-2160.png        2160x2160  icon on darkened kaleidoscope, no text
    poster-1440x2160.png   1440x2160  icon + "Abstrakt Deck" on blackhole crop
    tile-300.png           300x300    icon on the MSIX tile background

  Run from the repo root:
    powershell -ExecutionPolicy Bypass -File packaging\windows\make-store-logos.ps1
#>
$ErrorActionPreference = 'Stop'
$Shots = Join-Path $PSScriptRoot 'store\screenshots'
$Out   = Join-Path $PSScriptRoot 'store\logos'
New-Item -ItemType Directory -Force $Out | Out-Null

Add-Type -AssemblyName System.Drawing
Add-Type -ReferencedAssemblies System.Drawing @"
using System; using System.Drawing; using System.Drawing.Drawing2D; using System.Drawing.Imaging; using System.Drawing.Text;
public static class Logo {
    public static readonly Color Bg     = Color.FromArgb(10, 14, 20);
    static readonly Color Orange = Color.FromArgb(255, 140, 0);
    static readonly Color Red    = Color.FromArgb(255, 48, 48);
    static readonly Color Cyan   = Color.FromArgb(0, 229, 255);
    static readonly Color Yellow = Color.FromArgb(255, 215, 0);

    static PointF V(float cx, float cy, float r, int k) {
        double a = Math.PI / 3 * k;                       // flat-top: vertices at 0,60,...
        return new PointF(cx + (float)(r * Math.Cos(a)), cy - (float)(r * Math.Sin(a)));
    }

    public static Graphics G(Bitmap b) {
        var g = Graphics.FromImage(b);
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.InterpolationMode = InterpolationMode.HighQualityBicubic;
        g.PixelOffsetMode = PixelOffsetMode.HighQuality;
        g.CompositingQuality = CompositingQuality.HighQuality;
        g.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;
        return g;
    }

    // r = hexagon circumradius. Proportions from the 512 px icon (R = 151.5).
    public static void Icon(Graphics g, float cx, float cy, float r) {
        var hex = new PointF[6];
        for (int k = 0; k < 6; k++) hex[k] = V(cx, cy, r, k);
        using (var b = new SolidBrush(Orange)) g.FillPolygon(b, hex);   // base: no seams
        using (var b = new SolidBrush(Red))
            for (int k = 0; k < 6; k += 2)                              // upper-right, upper-left, bottom
                g.FillPolygon(b, new[] { new PointF(cx, cy), V(cx, cy, r, k), V(cx, cy, r, k + 1) });
        float ro = r * 33.5f / 151.5f, ri = r * 18.5f / 151.5f;
        using (var b = new SolidBrush(Cyan))   g.FillEllipse(b, cx - ro, cy - ro, 2 * ro, 2 * ro);
        using (var b = new SolidBrush(Yellow)) g.FillEllipse(b, cx - ri, cy - ri, 2 * ri, 2 * ri);
    }

    // Soft dark halo behind the icon so it separates from busy backgrounds.
    public static void Halo(Graphics g, float cx, float cy, float rad, int alpha) {
        using (var p = new GraphicsPath()) {
            p.AddEllipse(cx - rad, cy - rad, 2 * rad, 2 * rad);
            using (var br = new PathGradientBrush(p)) {
                br.CenterColor = Color.FromArgb(alpha, 0, 0, 0);
                br.SurroundColors = new[] { Color.FromArgb(0, 0, 0, 0) };
                br.SetBlendTriangularShape(1.0f, 1.0f);
                var bl = new Blend(4);
                bl.Positions = new[] { 0f, 0.35f, 0.7f, 1f };
                bl.Factors   = new[] { 0f, 0.55f, 0.95f, 1f };
                br.Blend = bl;
                g.FillEllipse(br, cx - rad, cy - rad, 2 * rad, 2 * rad);
            }
        }
    }

    // Crop `src` to `crop`, scale to w x h, darken by `dark` (0..1).
    public static Bitmap Background(Bitmap src, Rectangle crop, int w, int h, float dark) {
        var o = new Bitmap(w, h, PixelFormat.Format24bppRgb);
        using (var g = G(o))
        using (var ia = new ImageAttributes()) {
            ia.SetWrapMode(WrapMode.TileFlipXY);
            g.DrawImage(src, new Rectangle(0, 0, w, h), crop.X, crop.Y, crop.Width, crop.Height, GraphicsUnit.Pixel, ia);
            using (var b = new SolidBrush(Color.FromArgb((int)(dark * 255), 0, 0, 0))) g.FillRectangle(b, 0, 0, w, h);
        }
        return o;
    }

    public static void Text(Graphics g, string s, float cx, float top, float maxW, float size) {
        using (var f = new FontFamily("Segoe UI Semibold")) {
            var font = new Font(f, size, FontStyle.Regular, GraphicsUnit.Pixel);
            var sz = g.MeasureString(s, font);
            if (sz.Width > maxW) { font = new Font(f, size * maxW / sz.Width, FontStyle.Regular, GraphicsUnit.Pixel); sz = g.MeasureString(s, font); }
            float x = cx - sz.Width / 2;
            for (int i = 6; i >= 1; i--)                                  // soft shadow
                using (var b = new SolidBrush(Color.FromArgb(28, 0, 0, 0))) g.DrawString(s, font, b, x + i * 0.6f, top + i);
            using (var b = new SolidBrush(Color.White)) g.DrawString(s, font, b, x, top);
            font.Dispose();
        }
    }
}
"@

function Save($bmp, $name) {
    $p = Join-Path $Out $name
    $bmp.Save($p, [Drawing.Imaging.ImageFormat]::Png)
    Write-Host ("  {0,-24} {1}x{2}" -f $name, $bmp.Width, $bmp.Height)
}

# Box art: square crop of the kaleidoscope screenshot around its centre.
$k = [Drawing.Bitmap]::new((Join-Path $Shots '01-kaleidoscope.png'))
$box = [Logo]::Background($k, [Drawing.Rectangle]::new(420, 0, 1080, 1080), 2160, 2160, 0.50)
$g = [Logo]::G($box)
[Logo]::Halo($g, 1080, 1080, 1000, 255)
[Logo]::Icon($g, 1080, 1080, 470)
$g.Dispose(); Save $box 'boxart-2160.png'; $box.Dispose(); $k.Dispose()

# Poster: 2:3 vertical crop of the blackhole screenshot.
$bh = [Drawing.Bitmap]::new((Join-Path $Shots '02-blackhole.png'))
$poster = [Logo]::Background($bh, [Drawing.Rectangle]::new(600, 0, 720, 1080), 1440, 2160, 0.45)
$g = [Logo]::G($poster)
[Logo]::Halo($g, 720, 1260, 760, 170)
[Logo]::Halo($g, 720, 620, 640, 255)
[Logo]::Icon($g, 720, 620, 330)
[Logo]::Text($g, 'Abstrakt Deck', 720, 1140, 1200, 190)
$g.Dispose(); Save $poster 'poster-1440x2160.png'; $poster.Dispose(); $bh.Dispose()

# Tile: same framing as Square150x150Logo (hexagon ~63% of the width).
$tile = New-Object Drawing.Bitmap 300, 300, ([Drawing.Imaging.PixelFormat]::Format24bppRgb)
$g = [Logo]::G($tile)
$g.Clear([Logo]::Bg)
[Logo]::Icon($g, 150, 150, 94)
$g.Dispose(); Save $tile 'tile-300.png'; $tile.Dispose()

Write-Host "Logos written to $Out"
