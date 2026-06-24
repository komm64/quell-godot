param(
    [int]$MaxFrames = 0,
    [int]$Fps = 30,
    [string]$Display = "1280x720",
    [string]$Analysis = "256x144",
    [string]$OutputRoot = "validation/private/after-video-roundtrip/latest",
    [double]$Tolerance = 0.000001
)

$ErrorActionPreference = "Stop"

$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$OutputAbs = if ([System.IO.Path]::IsPathRooted($OutputRoot)) {
    $OutputRoot
} else {
    Join-Path $ProjectRoot $OutputRoot
}
$OutputAbs = [System.IO.Path]::GetFullPath($OutputAbs)
$AfterDir = Join-Path $OutputAbs "after"
$DecodedDir = Join-Path $OutputAbs "video_decoded"
$VideoPath = Join-Path $OutputAbs "after_lossless_ffv1.mkv"
$VideoRawJson = Join-Path $OutputAbs "video_raw_analysis.json"
$VideoRawCsv = Join-Path $OutputAbs "video_raw_metrics.csv"
$ReportPath = Join-Path $OutputAbs "after_video_roundtrip_report.json"

function Invoke-Checked {
    param(
        [Parameter(Mandatory = $true)][string]$Exe,
        [Parameter(Mandatory = $true)][string[]]$Args
    )
    & $Exe @Args
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed ($LASTEXITCODE): $Exe $($Args -join ' ')"
    }
}

function Get-ImageioFfmpeg {
    $ffmpeg = python -c "import imageio_ffmpeg; print(imageio_ffmpeg.get_ffmpeg_exe())"
    if (-not $ffmpeg -or -not (Test-Path -LiteralPath $ffmpeg)) {
        throw "imageio_ffmpeg ffmpeg binary was not found"
    }
    return $ffmpeg.Trim()
}

function Read-MetricsCsv {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Missing metrics CSV: $Path"
    }
    return @(Import-Csv -LiteralPath $Path)
}

function Compare-RiskLogs {
    param(
        [Parameter(Mandatory = $true)]$ExpectedAfter,
        [Parameter(Mandatory = $true)]$ActualRaw,
        [double]$AllowedDelta
    )
    if ($ExpectedAfter.Count -ne $ActualRaw.Count) {
        return @{
            passed = $false
            reason = "frame_count_mismatch"
            expected_frames = $ExpectedAfter.Count
            actual_frames = $ActualRaw.Count
        }
    }

    $fields = @(
        "QuellRawRisk",
        "QuellLuminance",
        "QuellRed",
        "QuellSpatial",
        "GeneralFlashCount",
        "RedFlashCount",
        "GeneralFlashArea",
        "RedFlashArea",
        "FrameLuminanceContrast",
        "TemporalLuminanceContrast"
    )
    $maxDiffs = @{}
    foreach ($field in $fields) {
        $maxDiffs[$field] = 0.0
    }
    $firstMismatch = $null

    for ($i = 0; $i -lt $ExpectedAfter.Count; $i++) {
        foreach ($field in $fields) {
            $a = [double]$ExpectedAfter[$i].$field
            $b = [double]$ActualRaw[$i].$field
            $diff = [Math]::Abs($a - $b)
            if ($diff -gt [double]$maxDiffs[$field]) {
                $maxDiffs[$field] = $diff
            }
            if ($null -eq $firstMismatch -and $diff -gt $AllowedDelta) {
                $firstMismatch = @{
                    frame = [int]$ExpectedAfter[$i].Frame
                    field = $field
                    after_value = $a
                    video_raw_value = $b
                    diff = $diff
                }
            }
        }
    }

    return @{
        passed = $null -eq $firstMismatch
        tolerance = $AllowedDelta
        frame_count = $ExpectedAfter.Count
        max_diffs = $maxDiffs
        first_mismatch = $firstMismatch
    }
}

New-Item -ItemType Directory -Force -Path $OutputAbs | Out-Null
if (Test-Path -LiteralPath $DecodedDir) {
    Remove-Item -LiteralPath $DecodedDir -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $DecodedDir | Out-Null

$Ffmpeg = Get-ImageioFfmpeg

$ExportArgs = @(
    "--path", $ProjectRoot,
    "--resolution", "64x64",
    "--position", "40,40",
    "--script", "res://tests/export_mitigated_frame_sequence.gd",
    "--",
    "--output-dir=$OutputAbs",
    "--output-fps=$Fps",
    "--display=$Display",
    "--analysis=$Analysis",
    "--solver",
    "--live-cadence"
)
if ($MaxFrames -gt 0) {
    $ExportArgs += "--max-frames=$MaxFrames"
}

Write-Host "[quell_after_video_roundtrip] export After frames and risk log"
Invoke-Checked "godot" $ExportArgs

$AfterCsv = Join-Path $AfterDir "quell_metrics.csv"
if (-not (Test-Path -LiteralPath $AfterCsv)) {
    throw "After metrics CSV was not written: $AfterCsv"
}

Write-Host "[quell_after_video_roundtrip] encode After PNG sequence to lossless video"
if (Test-Path -LiteralPath $VideoPath) {
    Remove-Item -LiteralPath $VideoPath -Force
}
Invoke-Checked $Ffmpeg @(
    "-hide_banner",
    "-loglevel", "error",
    "-y",
    "-framerate", "$Fps",
    "-i", (Join-Path $AfterDir "frame_%06d.png"),
    "-c:v", "ffv1",
    "-level", "3",
    "-pix_fmt", "bgra",
    $VideoPath
)

Write-Host "[quell_after_video_roundtrip] decode video back to frames"
Invoke-Checked $Ffmpeg @(
    "-hide_banner",
    "-loglevel", "error",
    "-y",
    "-i", $VideoPath,
    (Join-Path $DecodedDir "frame_%06d.png")
)

Write-Host "[quell_after_video_roundtrip] measure decoded video frames as Quell Raw"
$MeasureArgs = @(
    "--path", $ProjectRoot,
    "--resolution", "64x64",
    "--position", "120,40",
    "--script", "res://tests/measure_frame_sequence_gpu.gd",
    "--",
    "--input=$DecodedDir",
    "--output=$VideoRawJson",
    "--csv=$VideoRawCsv",
    "--fps=$Fps",
    "--display=$Display",
    "--analysis=$Analysis"
)
if ($MaxFrames -gt 0) {
    $MeasureArgs += "--max-frames=$MaxFrames"
}
Invoke-Checked "godot" $MeasureArgs

Write-Host "[quell_after_video_roundtrip] compare After risk log with decoded-video Raw log"
$ExpectedAfter = Read-MetricsCsv $AfterCsv
$ActualRaw = Read-MetricsCsv $VideoRawCsv
$Comparison = Compare-RiskLogs -ExpectedAfter $ExpectedAfter -ActualRaw $ActualRaw -AllowedDelta $Tolerance

$Report = [ordered]@{
    schema = "quell-after-video-roundtrip-v1"
    test_name = "quell_after_video_roundtrip"
    passed = [bool]$Comparison.passed
    tolerance = $Tolerance
    requested_max_frames = $MaxFrames
    frame_scope = $(if ($MaxFrames -gt 0) { "first_$MaxFrames" } else { "all" })
    fps = $Fps
    display = $Display
    analysis = $Analysis
    output_root = $OutputAbs
    after_metrics_csv = $AfterCsv
    video_path = $VideoPath
    decoded_frames_dir = $DecodedDir
    video_raw_metrics_csv = $VideoRawCsv
    comparison = $Comparison
}
$Report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $ReportPath -Encoding UTF8
$Report | ConvertTo-Json -Depth 8

if (-not [bool]$Comparison.passed) {
    throw "quell_after_video_roundtrip failed; see $ReportPath"
}
