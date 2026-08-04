# Video transcoding script optimized for AMD GPU (AMF) - PowerShell 7+ Compatible
param(
    [Parameter(Mandatory=$true)]
    [string]$DrivePath,
    [string]$FFmpegPath = "ffmpeg",
    [int]$MaxConcurrentJobs = 2,
    [ValidateSet("quality", "balanced", "speed")]
    [string]$AMFPreset = "quality"
)

# AMD AMF encoder configuration
function Get-AMFConfig {
    param($Preset)
    
    switch ($Preset) {
        "quality" {
            return @{
                VideoCodec = "h264_amf"
                ExtraArgs = @(
                    "-rc", "vbr_peak"
                    "-qp_i", "20"
                    "-qp_p", "22" 
                    "-qp_b", "24"
                    "-quality", "quality"
                    "-profile:v", "high"
                    "-level", "4.1"
                )
            }
        }
        "balanced" {
            return @{
                VideoCodec = "h264_amf"
                ExtraArgs = @(
                    "-rc", "vbr_peak"
                    "-qp_i", "23"
                    "-qp_p", "25"
                    "-qp_b", "27"
                    "-quality", "balanced"
                    "-profile:v", "high"
                )
            }
        }
        "speed" {
            return @{
                VideoCodec = "h264_amf"
                ExtraArgs = @(
                    "-rc", "vbr_peak"
                    "-qp_i", "26"
                    "-qp_p", "28"
                    "-qp_b", "30"
                    "-quality", "speed"
                    "-profile:v", "main"
                )
            }
        }
    }
}

# Check AMD GPU availability
function Test-AMFAvailability {
    param($FFmpegPath)
    
    Write-Host "Checking AMD AMF encoder availability..." -ForegroundColor Cyan
    
    try {
        $TestResult = & $FFmpegPath -f lavfi -i testsrc=duration=1:size=320x240:rate=1 -c:v h264_amf -f null - 2>&1
        
        if ($LASTEXITCODE -eq 0 -or $TestResult -notmatch "Unknown encoder|not found") {
            Write-Host "✓ AMD AMF encoder available" -ForegroundColor Green
            
            try {
                $GPUInfo = Get-WmiObject -Class Win32_VideoController | Where-Object { $_.Name -like "*AMD*" -or $_.Name -like "*Radeon*" }
                if ($GPUInfo) {
                    Write-Host "✓ AMD GPU detected: $($GPUInfo.Name)" -ForegroundColor Green
                    Write-Host "  Driver version: $($GPUInfo.DriverVersion)" -ForegroundColor Gray
                    Write-Host "  VRAM: $([math]::Round($GPUInfo.AdapterRAM / 1GB, 1)) GB" -ForegroundColor Gray
                }
            }
            catch {
                Write-Host "  GPU info not available via WMI" -ForegroundColor Gray
            }
            
            return $true
        } else {
            Write-Host "✗ AMD AMF encoder not available" -ForegroundColor Red
            Write-Host "  Make sure you have recent AMD drivers installed" -ForegroundColor Yellow
            return $false
        }
    }
    catch {
        Write-Host "✗ Error testing AMF availability: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

# Display system info
Write-Host "PowerShell Video Transcoder - AMD GPU Optimized" -ForegroundColor Green
Write-Host "PowerShell Version: $($PSVersionTable.PSVersion)" -ForegroundColor Cyan
Write-Host "=" * 60

# Verify AMF is available
if (-not (Test-AMFAvailability -FFmpegPath $FFmpegPath)) {
    Write-Host "Falling back to CPU encoding..." -ForegroundColor Yellow
    $AMFConfig = @{
        VideoCodec = "libx264"
        ExtraArgs = @("-crf", "23", "-preset", "medium")
    }
} else {
    $AMFConfig = Get-AMFConfig -Preset $AMFPreset
    Write-Host "Using AMD AMF preset: $AMFPreset" -ForegroundColor Green
}

# Video file extensions
$VideoExtensions = @("*.mp4", "*.avi", "*.mkv", "*.mov", "*.wmv", "*.flv", "*.webm", "*.m4v")

# Scan for files
Write-Host "Scanning for video files in: $DrivePath" -ForegroundColor Cyan
$VideoFiles = Get-ChildItem -Path $DrivePath -Recurse -Include $VideoExtensions
$TotalFiles = $VideoFiles.Count

if ($TotalFiles -eq 0) {
    Write-Host "No video files found!" -ForegroundColor Red
    exit
}

Write-Host "Found $TotalFiles video files to process" -ForegroundColor Green
Write-Host "Using $MaxConcurrentJobs concurrent streams" -ForegroundColor Green
Write-Host "=" * 60

# Initialize counters
$Global:ProcessedCount = 0
$Global:SuccessCount = 0
$Global:ErrorCount = 0
$Global:TotalSizeBefore = 0
$Global:TotalSizeAfter = 0
$Global:StartTime = Get-Date

# Test parallel processing first
Write-Host "Testing parallel processing..." -ForegroundColor Cyan
1..3 | ForEach-Object -Parallel {
    Write-Host "Test job $_ running on thread $([System.Threading.Thread]::CurrentThread.ManagedThreadId)" -ForegroundColor Yellow
    Start-Sleep 1
} -ThrottleLimit 2
Write-Host "Parallel test completed - starting transcoding..." -ForegroundColor Green
Write-Host ""

# Test FFmpeg AMF with a simple file first
Write-Host "Testing FFmpeg AMF with first video file..." -ForegroundColor Cyan
if ($VideoFiles.Count -gt 0) {
    $TestFile = $VideoFiles[0]
    $TestOutput = "$($TestFile.DirectoryName)\test_amd_output.mp4"
    
    Write-Host "Test file: $($TestFile.Name)" -ForegroundColor Yellow
    
    $TestArgs = @(
        "-i", "`"$($TestFile.FullName)`""
        "-t", "10"  # Only encode 10 seconds for testing
        "-vf", "scale=1920:1080:force_original_aspect_ratio=decrease"
        "-c:v", $AMFConfig.VideoCodec
    )
    $TestArgs += $AMFConfig.ExtraArgs
    $TestArgs += @("-c:a", "aac", "-y", "`"$TestOutput`"")
    
    Write-Host "Running test transcode (10 seconds)..." -ForegroundColor Cyan
    $TestProcess = Start-Process -FilePath $FFmpegPath -ArgumentList $TestArgs -Wait -PassThru -NoNewWindow
    
    if ($TestProcess.ExitCode -eq 0 -and (Test-Path $TestOutput)) {
        Write-Host "✓ AMF test successful!" -ForegroundColor Green
        Remove-Item $TestOutput -Force
    } else {
        Write-Host "✗ AMF test failed - exit code: $($TestProcess.ExitCode)" -ForegroundColor Red
        Write-Host "This suggests an issue with FFmpeg or AMF configuration" -ForegroundColor Yellow
        exit
    }
}

# Process files in parallel - PowerShell 7 optimized
if ($PSVersionTable.PSVersion.Major -ge 7) {
    Write-Host "Using PowerShell 7+ parallel processing" -ForegroundColor Green

    # Extract config for better $using: compatibility
    $VideoCodec = $AMFConfig.VideoCodec
    $ExtraArgs = $AMFConfig.ExtraArgs

    $VideoFiles | ForEach-Object -Parallel {
        $InputFile = $_
        $FFmpeg = $using:FFmpegPath
        $Codec = $using:VideoCodec
        $Args = $using:ExtraArgs
        $Total = $using:TotalFiles

        # Thread-safe counter increment
        $ProcessedCount = [System.Threading.Interlocked]::Increment([ref]$using:Global:ProcessedCount)
        $PercentComplete = [math]::Round(($ProcessedCount / $Total) * 100, 1)

        Write-Host ""
        Write-Host "[$ProcessedCount/$Total] ($PercentComplete%) Processing: $($InputFile.Name)" -ForegroundColor Yellow
        Write-Host "Thread: $([System.Threading.Thread]::CurrentThread.ManagedThreadId) | Size: $([math]::Round($InputFile.Length / 1MB, 2)) MB" -ForegroundColor Gray

        try {
            $TempOutput = "$($InputFile.DirectoryName)\temp_amd_$($InputFile.BaseName)_$([System.Threading.Thread]::CurrentThread.ManagedThreadId).mp4"

            # Build FFmpeg arguments
            $FFmpegArgs = @(
                "-i", "`"$($InputFile.FullName)`""
                "-vf", "scale=1920:1080:force_original_aspect_ratio=decrease,pad=1920:1080:(ow-iw)/2:(oh-ih)/2"
                "-r", "30"
                "-c:v", $Codec
            )

            # Add AMF-specific arguments
            $FFmpegArgs += $Args

            # Audio and container settings
            $FFmpegArgs += @(
                "-c:a", "aac"
                "-b:a", "128k"
                "-ac", "2"
                "-ar", "48000"
                "-movflags", "+faststart"
                "-avoid_negative_ts", "make_zero"
                "-y"
                "`"$TempOutput`""
            )

            Write-Host "Transcoding with AMD AMF ($Codec)..." -ForegroundColor Cyan

            # Debug: Show the exact FFmpeg command being executed
            $DebugCommand = "$FFmpeg " + ($FFmpegArgs -join " ")
            Write-Host "DEBUG: FFmpeg command:" -ForegroundColor Magenta
            Write-Host $DebugCommand -ForegroundColor Gray

            # Test if FFmpeg is accessible
            try {
                $FFmpegTest = & $FFmpeg -version 2>&1
                Write-Host "DEBUG: FFmpeg accessible - version: $($FFmpegTest[0])" -ForegroundColor Green
            } catch {
                Write-Host "DEBUG: FFmpeg not accessible at path: $FFmpeg" -ForegroundColor Red
                Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
                return
            }

            # Execute FFmpeg with timeout and better error handling
            Write-Host "DEBUG: Starting FFmpeg process..." -ForegroundColor Cyan
            $ProcessStartTime = Get-Date

            # Execute FFmpeg with error capture
            $ProcessInfo = New-Object System.Diagnostics.ProcessStartInfo
            $ProcessInfo.FileName = $FFmpeg
            $ProcessInfo.Arguments = $FFmpegArgs -join " "
            $ProcessInfo.UseShellExecute = $false
            $ProcessInfo.RedirectStandardOutput = $true
            $ProcessInfo.RedirectStandardError = $true
            $ProcessInfo.CreateNoWindow = $true

            $Process = New-Object System.Diagnostics.Process
            $Process.StartInfo = $ProcessInfo

            try {
                $Process.Start() | Out-Null
                Write-Host "DEBUG: FFmpeg process started with PID: $($Process.Id)" -ForegroundColor Green

                # Wait with timeout (5 minutes max per file)
                $TimeoutMinutes = 5
                $ProcessCompleted = $Process.WaitForExit($TimeoutMinutes * 60 * 1000)

                if (-not $ProcessCompleted) {
                    Write-Host "DEBUG: FFmpeg process timed out after $TimeoutMinutes minutes - killing process" -ForegroundColor Red
                    $Process.Kill()
                    $Process.WaitForExit()
                    Write-Host "✗ TIMEOUT - Process killed" -ForegroundColor Red
                    return
                }

                $ProcessEndTime = Get-Date
                $ProcessDuration = ($ProcessEndTime - $ProcessStartTime).TotalSeconds
                Write-Host "DEBUG: FFmpeg completed in $([math]::Round($ProcessDuration, 1)) seconds" -ForegroundColor Green

                $StdOut = $Process.StandardOutput.ReadToEnd()
                $StdErr = $Process.StandardError.ReadToEnd()

                Write-Host "DEBUG: FFmpeg exit code: $($Process.ExitCode)" -ForegroundColor Cyan

                # Show FFmpeg output for debugging
                if ($StdErr) {
                    Write-Host "DEBUG: FFmpeg stderr (last 5 lines):" -ForegroundColor Yellow
                    $StdErr.Split("`n") | Select-Object -Last 5 | ForEach-Object {
                        if ($_ -ne "") { Write-Host "  $_" -ForegroundColor Gray }
                    }
                }

            } catch {
                Write-Host "DEBUG: Error starting FFmpeg process: $($_.Exception.Message)" -ForegroundColor Red
                return
            }

            if ($Process.ExitCode -eq 0 -and (Test-Path $TempOutput)) {
                $OriginalSize = $InputFile.Length
                $NewSize = (Get-Item $TempOutput).Length
                $SizeReduction = [math]::Round((($OriginalSize - $NewSize) / $OriginalSize) * 100, 1)

                # Update global size tracking
                [System.Threading.Interlocked]::Add([ref]$using:Global:TotalSizeBefore, $OriginalSize) | Out-Null
                [System.Threading.Interlocked]::Add([ref]$using:Global:TotalSizeAfter, $NewSize) | Out-Null

                # Replace original file
                Remove-Item $InputFile.FullName -Force
                Move-Item $TempOutput $InputFile.FullName

                [System.Threading.Interlocked]::Increment([ref]$using:Global:SuccessCount) | Out-Null
                Write-Host "✓ SUCCESS - Size change: $SizeReduction%" -ForegroundColor Green
            } else {
                [System.Threading.Interlocked]::Increment([ref]$using:Global:ErrorCount) | Out-Null
                Write-Host "✗ FAILED - FFmpeg exit code: $($Process.ExitCode)" -ForegroundColor Red

                # Show last few lines of error for debugging
                if ($StdErr) {
                    $ErrorLines = $StdErr.Split("`n") | Where-Object { $_ -ne "" } | Select-Object -Last 3
                    Write-Host "Error: $($ErrorLines -join ' | ')" -ForegroundColor Red
                }

                if (Test-Path $TempOutput) { Remove-Item $TempOutput -Force }
            }
        }
        catch {
            [System.Threading.Interlocked]::Increment([ref]$using:Global:ErrorCount) | Out-Null
            Write-Host "✗ ERROR: $($_.Exception.Message)" -ForegroundColor Red

            $TempOutput = "$($InputFile.DirectoryName)\temp_amd_$($InputFile.BaseName)_$([System.Threading.Thread]::CurrentThread.ManagedThreadId).mp4"
            if (Test-Path $TempOutput) { Remove-Item $TempOutput -Force }
        }

        # Progress update
        $ElapsedTime = (Get-Date).Subtract($using:Global:StartTime).TotalMinutes
        if ($ProcessedCount -gt 1) {
            $AvgTimePerFile = $ElapsedTime / $ProcessedCount
            $EstimatedTimeRemaining = [math]::Round(($Total - $ProcessedCount) * $AvgTimePerFile, 1)
            Write-Host "Totals: $($using:Global:SuccessCount) success, $($using:Global:ErrorCount) failed | ETA: $EstimatedTimeRemaining min" -ForegroundColor Magenta
        } else {
            Write-Host "Totals: $($using:Global:SuccessCount) success, $($using:Global:ErrorCount) failed" -ForegroundColor Magenta
        }
        Write-Host "-" * 60

    } -ThrottleLimit $MaxConcurrentJobs

} else {
    Write-Host "PowerShell 5.x detected - please upgrade to PowerShell 7 for parallel processing" -ForegroundColor Yellow
    Write-Host "Download from: https://github.com/PowerShell/PowerShell/releases" -ForegroundColor Yellow
    exit
}

# Final summary
Write-Host ""
Write-Host "AMD GPU TRANSCODING COMPLETE!" -ForegroundColor Green -BackgroundColor Black
Write-Host "Encoder: AMD AMF ($($AMFConfig.VideoCodec)) - Preset: $AMFPreset" -ForegroundColor Cyan
Write-Host "Files processed: $($Global:ProcessedCount) | Success: $($Global:SuccessCount) | Failed: $($Global:ErrorCount)" -ForegroundColor White

if ($Global:SuccessCount -gt 0) {
    $OverallSizeReduction = [math]::Round((($Global:TotalSizeBefore - $Global:TotalSizeAfter) / $Global:TotalSizeBefore) * 100, 1)
    $SpaceSaved = [math]::Round(($Global:TotalSizeBefore - $Global:TotalSizeAfter) / 1GB, 2)
    Write-Host "Total size reduction: $OverallSizeReduction% ($SpaceSaved GB saved)" -ForegroundColor Green
}

$TotalTime = (Get-Date).Subtract($Global:StartTime).TotalMinutes
$FilesPerMinute = if ($TotalTime -gt 0) { [math]::Round($Global:ProcessedCount / $TotalTime, 1) } else { 0 }
Write-Host "Total time: $([math]::Round($TotalTime, 1)) minutes ($FilesPerMinute files/min)" -ForegroundColor Cyan

if ($Global:ErrorCount -gt 0) {
    Write-Host ""
    Write-Host "Some files failed to transcode. Check FFmpeg installation and AMD drivers." -ForegroundColor Yellow
}
