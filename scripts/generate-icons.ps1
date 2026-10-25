param([string]$SourcePath = '')

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$appRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../apps/management'))
if ([string]::IsNullOrWhiteSpace($SourcePath)) {
    $SourcePath = Join-Path $appRoot 'assets/branding/kwadra-logo.png'
}
$sourceImage = [Drawing.Image]::FromFile([IO.Path]::GetFullPath($SourcePath))

function Write-KwadraIcon([string]$relativePath, [int]$size) {
    $target = [IO.Path]::GetFullPath((Join-Path $appRoot $relativePath))
    if (-not $target.StartsWith($appRoot + [IO.Path]::DirectorySeparatorChar)) { throw 'Icon target is outside the app.' }
    $bitmap = [Drawing.Bitmap]::new($size, $size)
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.Clear([Drawing.Color]::White)
        $graphics.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $graphics.PixelOffsetMode = [Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $graphics.CompositingQuality = [Drawing.Drawing2D.CompositingQuality]::HighQuality
        # Fit the complete supplied artwork, preserving its proportions.
        $scale = [Math]::Min($size / $sourceImage.Width, $size / $sourceImage.Height)
        $width = [single]($sourceImage.Width * $scale)
        $height = [single]($sourceImage.Height * $scale)
        $bounds = [Drawing.RectangleF]::new([single](($size - $width) / 2), [single](($size - $height) / 2), $width, $height)
        $graphics.DrawImage($sourceImage, $bounds)
        $bitmap.Save($target, [Drawing.Imaging.ImageFormat]::Png)
    } finally {
        $graphics.Dispose()
        $bitmap.Dispose()
    }
}

try {
    Write-KwadraIcon 'web/favicon.png' 48
    foreach ($size in @(192, 512)) {
        Write-KwadraIcon "web/icons/Icon-$size.png" $size
        Write-KwadraIcon "web/icons/Icon-maskable-$size.png" $size
    }
    $densities = @{ 'mdpi' = 48; 'hdpi' = 72; 'xhdpi' = 96; 'xxhdpi' = 144; 'xxxhdpi' = 192 }
    foreach ($density in $densities.Keys) { Write-KwadraIcon "android/app/src/main/res/mipmap-$density/ic_launcher.png" $densities[$density] }
    $catalog = Get-Content -LiteralPath (Join-Path $appRoot 'ios/Runner/Assets.xcassets/AppIcon.appiconset/Contents.json') -Raw | ConvertFrom-Json
    foreach ($icon in $catalog.images) {
        if ($icon.filename) {
            $pointsSize = [double]($icon.size.Split('x')[0])
            $scale = [double]($icon.scale.Replace('x', ''))
            Write-KwadraIcon ('ios/Runner/Assets.xcassets/AppIcon.appiconset/' + $icon.filename) ([int]($pointsSize * $scale))
        }
    }
    Write-Output 'Mascot applied to Kwadra web, Android, and iOS icons.'
} finally {
    $sourceImage.Dispose()
}
