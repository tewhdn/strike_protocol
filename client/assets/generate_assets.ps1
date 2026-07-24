<#
  Regenerates the six PNG fallbacks used by the Godot client from the same
  simple geometry as the adjacent SVG sources. This script only uses the
  Windows System.Drawing assembly; no package download is required.
#>
param([string]$OutDir = $PSScriptRoot)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

function C([string]$hex, [int]$alpha = 255) {
  $rgb = [System.Drawing.ColorTranslator]::FromHtml($hex)
  return [System.Drawing.Color]::FromArgb($alpha, $rgb.R, $rgb.G, $rgb.B)
}

function New-Canvas([int]$width, [int]$height) {
  $bitmap = [System.Drawing.Bitmap]::new($width, $height, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $bitmap.SetResolution(96, 96)
  $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
  $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
  $graphics.CompositingMode = [System.Drawing.Drawing2D.CompositingMode]::SourceOver
  $graphics.Clear([System.Drawing.Color]::Transparent)
  return @($bitmap, $graphics)
}

function Save-Canvas($bitmap, $graphics, [string]$path) {
  $graphics.Dispose()
  $bitmap.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
  $bitmap.Dispose()
}

function Pt([float]$x, [float]$y) { return [System.Drawing.PointF]::new($x, $y) }
function Poly($g, [string]$fill, [string]$stroke, [float]$width, [object[]]$coords) {
  $points = for ($i = 0; $i -lt $coords.Count; $i += 2) { Pt $coords[$i] $coords[$i + 1] }
  $brush = [System.Drawing.SolidBrush]::new((C $fill))
  $g.FillPolygon($brush, $points)
  if ($width -gt 0 -and $stroke) {
    $pen = [System.Drawing.Pen]::new((C $stroke), $width)
    $pen.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
    $g.DrawPolygon($pen, $points)
    $pen.Dispose()
  }
  $brush.Dispose()
}
function Ell($g, [string]$fill, [string]$stroke, [float]$width, [float]$x, [float]$y, [float]$w, [float]$h) {
  $brush = [System.Drawing.SolidBrush]::new((C $fill))
  $g.FillEllipse($brush, $x, $y, $w, $h)
  if ($width -gt 0 -and $stroke) {
    $pen = [System.Drawing.Pen]::new((C $stroke), $width)
    $g.DrawEllipse($pen, $x, $y, $w, $h)
    $pen.Dispose()
  }
  $brush.Dispose()
}
function Line($g, [string]$stroke, [float]$width, [float]$x1, [float]$y1, [float]$x2, [float]$y2) {
  $pen = [System.Drawing.Pen]::new((C $stroke), $width)
  $pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
  $pen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
  $g.DrawLine($pen, $x1, $y1, $x2, $y2)
  $pen.Dispose()
}

function Draw-Player($g, [bool]$enemy) {
  $dark = if ($enemy) { '#16090d' } else { '#07111f' }
  $leg = if ($enemy) { '#672432' } else { '#18395f' }
  $boot = if ($enemy) { '#271117' } else { '#0d1b2a' }
  $accent = if ($enemy) { '#ff4b57' } else { '#2f7ef7' }
  $body = if ($enemy) { '#c63746' } else { '#2864c7' }
  $visor = if ($enemy) { '#ffbd6a' } else { '#70e6ff' }
  $panel = if ($enemy) { '#471821' } else { '#102a47' }
  $helmet = if ($enemy) { '#672432' } else { '#15395f' }
  $shine = if ($enemy) { '#ff8d77' } else { '#73dbff' }
  Ell $g '#030712' '' 0 55 203 146 34
  Poly $g $leg $dark 8 @(84,166,70,213,98,218,116,174)
  Poly $g $leg $dark 8 @(172,166,186,213,158,218,140,174)
  Poly $g $boot $dark 8 @(88,211,65,216,67,232,103,232,101,217)
  Poly $g $boot $dark 8 @(168,211,191,216,189,232,153,232,155,217)
  Poly $g $accent $dark 8 @(84,96,54,130,67,174,92,161,82,134,103,116)
  Poly $g $accent $dark 8 @(172,96,202,130,189,174,164,161,174,134,153,116)
  Poly $g $body $dark 8 @(91,91,128,70,165,91,178,170,128,194,78,170)
  Poly $g $panel $dark 8 @(101,115,155,115,160,161,128,176,96,161)
  Poly $g $visor $dark 5 @(117,120,139,120,139,151,117,151)
  Ell $g $accent $dark 8 85 25 86 86
  Poly $g $helmet $dark 8 @(91,65,128,35,165,65,158,88,98,88)
  Poly $g $visor $dark 5 @(101,66,128,50,155,66,151,79,105,79)
  Poly $g $body $dark 8 @(114,28,142,28,150,45,106,45)
  Line $g $shine 5 94 103 162 103
}

function Draw-Rifle($g) {
  Ell $g '#030712' '' 0 43 95 314 20
  Poly $g '#1b2b3d' '#07111f' 7 @(31,76,84,43,119,52,96,86,39,94)
  Poly $g '#263d54' '#07111f' 7 @(86,52,140,52,151,82,96,86)
  Poly $g '#35506b' '#07111f' 7 @(132,47,236,47,260,64,233,88,143,88)
  Poly $g '#26384a' '#07111f' 7 @(227,53,348,53,348,72,241,72)
  Poly $g '#162433' '#07111f' 7 @(343,49,374,49,374,77,343,77)
  Poly $g '#1b2b3d' '#07111f' 7 @(160,82,181,117,216,117,209,83)
  Poly $g '#22384d' '#07111f' 7 @(227,85,250,109,278,109,257,74)
  Poly $g '#162433' '#07111f' 7 @(165,46,176,29,224,29,235,47)
  Poly $g '#35506b' '#07111f' 6 @(186,29,186,18,211,18,211,29)
  Line $g '#5fd8ff' 5 149 60 230 60
  Line $g '#4b6d89' 4 268 60 337 60
  Ell $g '#f3b84b' '#07111f' 3 238 58 16 16
}

function Draw-Crate($g) {
  Ell $g '#030712' '' 0 41 210 174 32
  Poly $g '#b87735' '#15100c' 8 @(45,61,128,30,211,61,128,94)
  Poly $g '#925529' '#15100c' 8 @(45,61,128,94,128,221,45,188)
  Poly $g '#70401f' '#15100c' 8 @(211,61,128,94,128,221,211,188)
  Line $g '#d59a51' 13 45 61 211 188
  Line $g '#d59a51' 13 211 61 45 188
  Line $g '#402719' 8 128 94 128 221
  Line $g '#e4ad62' 9 45 61 128 94
  Line $g '#e4ad62' 9 128 94 211 61
  Line $g '#f2c478' 5 61 73 120 96
}

function Draw-Bullet($g) {
  Line $g '#ff7c29' 16 7 32 31 32
  Line $g '#ffb33a' 9 11 32 37 32
  Poly $g '#ffe27a' '#52250e' 5 @(24,24,45,24,57,32,45,40,24,40)
  Poly $g '#fff5bd' '' 0 @(42,27,51,32,42,37)
}

function Draw-Logo($g) {
  Poly $g '#102a47' '#07111f' 10 @(134,28,221,78,221,178,134,228,47,178,47,78)
  Poly $g '#4ed7ff' '#07111f' 10 @(134,50,198,87,163,107,134,91,105,107,70,87)
  Poly $g '#2f7ef7' '#07111f' 10 @(70,108,106,129,106,170,134,186,134,228,47,178,47,78)
  Poly $g '#ff4b57' '#07111f' 10 @(198,108,162,129,162,170,134,186,134,228,221,178,221,78)
  $font = [System.Drawing.Font]::new('Arial', 82, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
  $small = [System.Drawing.Font]::new('Arial', 52, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
  $shadow = [System.Drawing.SolidBrush]::new((C '#07111f'))
  $white = [System.Drawing.SolidBrush]::new((C '#f2f7ff'))
  $cyan = [System.Drawing.SolidBrush]::new((C '#61dcff'))
  $g.DrawString('STRIKE', $font, $shadow, 252, 39)
  $g.DrawString('STRIKE', $font, $white, 252, 32)
  $g.DrawString('PROTOCOL', $small, $shadow, 255, 140)
  $g.DrawString('PROTOCOL', $small, $cyan, 255, 134)
  Line $g '#ff4b57' 9 258 207 691 207
  $font.Dispose(); $small.Dispose(); $shadow.Dispose(); $white.Dispose(); $cyan.Dispose()
}

$items = @(
  @{Name='player_blue'; Width=256; Height=256; Draw={param($g) Draw-Player $g $false}},
  @{Name='enemy_red'; Width=256; Height=256; Draw={param($g) Draw-Player $g $true}},
  @{Name='rifle'; Width=384; Height=128; Draw={param($g) Draw-Rifle $g}},
  @{Name='crate'; Width=256; Height=256; Draw={param($g) Draw-Crate $g}},
  @{Name='bullet'; Width=64; Height=64; Draw={param($g) Draw-Bullet $g}},
  @{Name='logo'; Width=768; Height=256; Draw={param($g) Draw-Logo $g}}
)

foreach ($item in $items) {
  $canvas = New-Canvas $item.Width $item.Height
  $bitmap = $canvas[0]; $graphics = $canvas[1]
  $scale = [Math]::Min($item.Width / 256.0, $item.Height / 256.0)
  if ($item.Name -eq 'rifle') { $scale = 1.0 }
  if ($item.Name -eq 'bullet') { $scale = 1.0 }
  if ($item.Name -eq 'logo') { $scale = 1.0 }
  $graphics.ScaleTransform($scale, $scale)
  & $item.Draw $graphics
  Save-Canvas $bitmap $graphics (Join-Path $OutDir ($item.Name + '.png'))
}
Write-Host ('Generated {0} PNG assets in {1}' -f $items.Count, $OutDir)
