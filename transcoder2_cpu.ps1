# Video transcoding script - CPU optimized with parallel processing
param(
    [Parameter(Mandatory=$true)]
    [string]$DrivePath,
    [string]$FFmpegPath = "ffmpeg",
    [int]$MaxConcurrentJobs = $env:NUMBER_OF_PROCESSORS,
    [ValidateSet("ultrafast", "superfast", "veryfast", "faster", "fast", "medium", "slow", "slower", "veryslow")]
    [string]$Preset = "medium",
    [int]$CRF = 23
)

# CPU encoder configuration
function Get-CPUConfig {
    param($Preset, $CRF)
    
    return @{
        VideoCodec = "libx264"
        Preset = $Preset
        CRF = $CRF
        ExtraArgs = @(
            "-preset", $Preset
            "-crf", $CRF
            "-profile:v", "high"
            "-level", "4.1"
            "-threads", "0"  # Use all available CPU threads
        )
    }
}

# Check FFmpeg availability
function Test-FFmpegAvailability {
    param($FFmpegPath)
    
    Write-Host "Checking FFmpeg availability..." -ForegroundColor Cyan
    
    try {
        $FFmpegVersion = & $FFmpegPath -version 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Host "✓ FFmpeg available" -ForegroundColor Green
            $VersionLine = $FFmpegVersion[0]
            Write-Host "  Version: $VersionLine" -ForegroundColor Gray
            
            # Check for libx264 encoder
            $Encoders = & $FFmpegPath -encoders 2>&1 | Out-String
            if ($Encoders -match "libx264") {
                Write-Host "✓ libx264 encoder available" -ForegroundColor Green
                return $true
            } else {
                Write-Host "✗ libx264 encoder not found" -ForegroundColor Red
                return $false
            }
        } else {
            Write-Host "✗ FFmpeg not accessible at path: $FFmpegPath" -ForegroundColor Red
            return $false
        }
    }
    catch {
        Write-Host "✗ Error testing FFmpeg: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

# Display system info
Write-Host "PowerShell Video Transcoder - CPU Optimized" -ForegroundColor Green
Write-Host "PowerShell Version: $($PSVersionTable.PSVersion)" -ForegroundColor Cyan
Write-Host "CPU Threads: $env:NUMBER_OF_PROCESSORS" -ForegroundColor Cyan
Write-Host "=" * 60

# Verify FFmpeg is available
if (-not (Test-FFmpegAvailability -FFmpegPath $FFmpegPath)) {
    Write-Host "FFmpeg is required but not available. Please install FFmpeg and ensure it's in your PATH." -ForegroundColor Red
    exit 1
}

# Get CPU encoder configuration
$CPUConfig = Get-CPUConfig -Preset $Preset -CRF $CRF
Write-Host "Using CPU encoder: libx264" -ForegroundColor Green
Write-Host "Preset: $Preset | CRF: $CRF | Threads: All available" -ForegroundColor Green

# Video file extensions
$VideoExtensions = @("*.mp4", "*.avi", "*.mkv", "*.mov", "*.wmv", "*.flv", "*.webm", "*.m4v")

# Scan for files
Write-Host "Scanning for video files in: $DrivePath" -ForegroundColor Cyan
$VideoFiles = Get-ChildItem -Path $DrivePath -Recurse -Include $VideoExtensions
$TotalFiles = $VideoFiles.Count

if ($TotalFiles -eq 0) {
    Write-Host "No video files found!" -ForegroundColor Red
    exit 0
}

Write-Host "Found $TotalFiles video files to process" -ForegroundColor Green
Write-Host "Using $MaxConcurrentJobs concurrent CPU jobs" -ForegroundColor Green
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

# Test FFmpeg with a simple file first
Write-Host "Testing FFmpeg with first video file..." -ForegroundColor Cyan
if ($VideoFiles.Count -gt 0) {
    $TestFile = $VideoFiles[0]
    $TestOutput = "$($TestFile.DirectoryName)\test_cpu_output.mp4"
    
    Write-Host "Test file: $($TestFile.Name)" -ForegroundColor Yellow
    
    $TestArgs = @(
        "-i", "`"$($TestFile.FullName)`""
        "-t", "10"  # Only encode 10 seconds for testing
        "-vf", "scale=1920:1080:force_original_aspect_ratio=decrease"
        "-c:v", $CPUConfig.VideoCodec
        "-preset", $CPUConfig.Preset
        "-crf", $CPUConfig.CRF
        "-c:a", "aac"
        "-y", "`"$TestOutput`""
    )
    
    Write-Host "Running test transcode (10 seconds)..." -ForegroundColor Cyan
    $TestProcess = Start-Process -FilePath $FFmpegPath -ArgumentList $TestArgs -Wait -PassThru -NoNewWindow
    
    if ($TestProcess.ExitCode -eq 0 -and (Test-Path $TestOutput)) {
        Write-Host "✓ CPU encoding test successful!" -ForegroundColor Green
        Remove-Item $TestOutput -Force
    } else {
        Write-Host "✗ CPU encoding test failed - exit code: $($TestProcess.ExitCode)" -ForegroundColor Red
        Write-Host "This suggests an issue with FFmpeg configuration" -ForegroundColor Yellow
        exit 1
    }
}

# Process files in parallel - PowerShell 7 optimized
if ($PSVersionTable.PSVersion.Major -ge 7) {
    Write-Host "Using PowerShell 7+ parallel processing with CPU encoding" -ForegroundColor Green
    
    # Extract config for better $using: compatibility
    $VideoCodec = $CPUConfig.VideoCodec
    $EncoderPreset = $CPUConfig.Preset
    $EncoderCRF = $CPUConfig.CRF
    
    $VideoFiles | ForEach-Object -Parallel {
        $InputFile = $_
        $FFmpeg = $using:FFmpegPath
        $Codec = $using:VideoCodec
        $CpuPreset = $using:EncoderPreset
        $CpuCRF = $using:EncoderCRF
        $Total = $using:TotalFiles
        
        # Thread-safe counter increment
        $ProcessedCount = [System.Threading.Interlocked]::Increment([ref]$using:Global:ProcessedCount)
        $PercentComplete = [math]::Round(($ProcessedCount / $Total) * 100, 1)
        
        Write-Host ""
        Write-Host "[$ProcessedCount/$Total] ($PercentComplete%) Processing: $($InputFile.Name)" -ForegroundColor Yellow
        Write-Host "Thread: $([System.Threading.Thread]::CurrentThread.ManagedThreadId) | Size: $([math]::Round($InputFile.Length / 1MB, 2)) MB" -ForegroundColor Gray
        
        try {
            $TempOutput = "$($InputFile.DirectoryName)\temp_cpu_$($InputFile.BaseName)_$([System.Threading.Thread]::CurrentThread.ManagedThreadId).mp4"
            
            # Build FFmpeg arguments for CPU encoding
            $FFmpegArgs = @(
                "-i", "`"$($InputFile.FullName)`""
                "-vf", "scale=1920:1080:force_original_aspect_ratio=decrease,pad=1920:1080:(ow-iw)/2:(oh-ih)/2"
                "-r", "30"
                "-c:v", $Codec
                "-preset", $CpuPreset
                "-crf", $CpuCRF
                "-profile:v", "high"
                "-level", "4.1"
                "-threads", "0"  # Use all available threads
                "-c:a", "aac"
                "-b:a", "128k"
                "-ac", "2"
                "-ar", "48000"
                "-movflags", "+faststart"
                "-avoid_negative_ts", "make_zero"
                "-y"
                "`"$TempOutput`""
            )
            
            Write-Host "Transcoding with CPU ($Codec, preset: $CpuPreset, CRF: $CpuCRF)..." -ForegroundColor Cyan
            
            # Execute FFmpeg with timeout and error handling
            $ProcessStartTime = Get-Date
            
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
                
                # Wait with timeout (10 minutes max per file for CPU encoding)
                $TimeoutMinutes = 10
                $ProcessCompleted = $Process.WaitForExit($TimeoutMinutes * 60 * 1000)
                
                if (-not $ProcessCompleted) {
                    Write-Host "✗ TIMEOUT - Process killed after $TimeoutMinutes minutes" -ForegroundColor Red
                    $Process.Kill()
                    $Process.WaitForExit()
                    if (Test-Path $TempOutput) { Remove-Item $TempOutput -Force }
                    return
                }
                
                $ProcessEndTime = Get-Date
                $ProcessDuration = ($ProcessEndTime - $ProcessStartTime).TotalSeconds
                
                $StdOut = $Process.StandardOutput.ReadToEnd()
                $StdErr = $Process.StandardError.ReadToEnd()
                
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
                    Write-Host "✓ SUCCESS - Size change: $SizeReduction% | Duration: $([math]::Round($ProcessDuration, 1))s" -ForegroundColor Green
                } else {
                    [System.Threading.Interlocked]::Increment([ref]$using:Global:ErrorCount) | Out-Null
                    Write-Host "✗ FAILED - FFmpeg exit code: $($Process.ExitCode)" -ForegroundColor Red
                    
                    # Show error details
                    if ($StdErr) {
                        $ErrorLines = $StdErr.Split("`n") | Where-Object { $_ -ne "" } | Select-Object -Last 3
                        Write-Host "Error: $($ErrorLines -join ' | ')" -ForegroundColor Red
                    }
                    
                    if (Test-Path $TempOutput) { Remove-Item $TempOutput -Force }
                }
                
            } catch {
                Write-Host "✗ ERROR starting FFmpeg: $($_.Exception.Message)" -ForegroundColor Red
                [System.Threading.Interlocked]::Increment([ref]$using:Global:ErrorCount) | Out-Null
                if (Test-Path $TempOutput) { Remove-Item $TempOutput -Force }
            }
        }
        catch {
            [System.Threading.Interlocked]::Increment([ref]$using:Global:ErrorCount) | Out-Null
            Write-Host "✗ ERROR: $($_.Exception.Message)" -ForegroundColor Red
            
            $TempOutput = "$($InputFile.DirectoryName)\temp_cpu_$($InputFile.BaseName)_$([System.Threading.Thread]::CurrentThread.ManagedThreadId).mp4"
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
    exit 1
}

# Final summary
Write-Host ""
Write-Host "CPU TRANSCODING COMPLETE!" -ForegroundColor Green -BackgroundColor Black
Write-Host "Encoder: libx264 - Preset: $Preset | CRF: $CRF" -ForegroundColor Cyan
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
    Write-Host "Some files failed to transcode. Check FFmpeg installation and file permissions." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "All original files have been replaced with transcoded versions." -ForegroundColor Green
