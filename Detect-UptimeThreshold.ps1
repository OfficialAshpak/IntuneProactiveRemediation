<#
.SYNOPSIS
    Intune Proactive Remediation Detection Script - System Uptime Monitoring
.DESCRIPTION
    Detects if system uptime exceeds defined thresholds and triggers remediation.
    Tracks notification stages via registry to implement progressive notification strategy.
.NOTES
    Author: Enterprise IT
    Version: 1.0
    Run As: SYSTEM
    Architecture: 64-bit only
    
    Deploy in: Microsoft Intune > Reports > Endpoint Analytics > Proactive Remediations
    Schedule: Daily or Hourly based on requirements
    
    Exit Codes:
    - 0: Compliant (under threshold or no action needed)
    - 1: Non-compliant (remediation required)
#>

#Requires -Version 5.1
#Requires -RunAsAdministrator

# ================================
# CONFIGURATION
# ================================
$Script:Config = @{
    RegistryPath = "HKLM:\SOFTWARE\IntuneRebootNotifier"
    Stage1Threshold = 2  # Days
    Stage2Threshold = 4  # Days
    Stage3Threshold = 6  # Days
    LogPrefix = "[DETECT]"
}

# ================================
# LOGGING FUNCTION
# ================================
function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('Info','Warning','Error')]
        [string]$Level = 'Info'
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "$timestamp [$Level] $($Script:Config.LogPrefix) $Message"
    Write-Output $logMessage
}

# ================================
# REGISTRY FUNCTIONS
# ================================
function Get-NotificationStage {
    try {
        if (Test-Path $Script:Config.RegistryPath) {
            $stage = Get-ItemProperty -Path $Script:Config.RegistryPath -Name "Stage" -ErrorAction SilentlyContinue
            if ($stage) {
                return [int]$stage.Stage
            }
        }
        return 0
    }
    catch {
        Write-Log "Error reading notification stage: $_" -Level Warning
        return 0
    }
}

function Initialize-RegistryPath {
    try {
        if (-not (Test-Path $Script:Config.RegistryPath)) {
            New-Item -Path $Script:Config.RegistryPath -Force | Out-Null
            Write-Log "Created registry path: $($Script:Config.RegistryPath)" -Level Info
        }
    }
    catch {
        Write-Log "Error creating registry path: $_" -Level Error
    }
}

# ================================
# UPTIME CALCULATION
# ================================
function Get-SystemUptime {
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        $lastBoot = $os.LastBootUpTime
        $uptime = (Get-Date) - $lastBoot
        $uptimeDays = [math]::Round($uptime.TotalDays, 2)
        
        Write-Log "System last boot: $lastBoot" -Level Info
        Write-Log "Current uptime: $uptimeDays days" -Level Info
        
        return $uptimeDays
    }
    catch {
        Write-Log "Error calculating uptime: $_" -Level Error
        return -1
    }
}

# ================================
# USER SESSION CHECK
# ================================
function Test-UserLoggedOn {
    try {
        $sessions = quser 2>&1
        if ($sessions -match "No User exists") {
            Write-Log "No user currently logged on" -Level Info
            return $false
        }
        
        # Parse quser output to find active sessions
        $sessionLines = $sessions | Where-Object { $_ -match '\s+\d+\s+' }
        if ($sessionLines) {
            Write-Log "Active user session(s) detected" -Level Info
            return $true
        }
        
        return $false
    }
    catch {
        Write-Log "Error checking user sessions: $_" -Level Warning
        # Assume user might be logged on if we can't determine
        return $true
    }
}

# ================================
# MAIN DETECTION LOGIC
# ================================
function Start-Detection {
    Write-Log "===== Starting Uptime Detection =====" -Level Info
    
    # Check for user session
    $userLoggedOn = Test-UserLoggedOn
    if (-not $userLoggedOn) {
        Write-Log "No user logged on - exiting compliant (no notification needed)" -Level Info
        exit 0
    }
    
    # Get current uptime
    $uptimeDays = Get-SystemUptime
    if ($uptimeDays -lt 0) {
        Write-Log "Failed to retrieve uptime - exiting compliant" -Level Error
        exit 0
    }
    
    # Initialize registry if needed
    Initialize-RegistryPath
    
    # Get current notification stage
    $currentStage = Get-NotificationStage
    Write-Log "Current notification stage: $currentStage" -Level Info
    
    # Determine if remediation is needed based on thresholds
    $remediationNeeded = $false
    $targetStage = 0
    
    if ($uptimeDays -ge $Script:Config.Stage3Threshold) {
        $remediationNeeded = $true
        $targetStage = 3
        Write-Log "Stage 3 threshold reached ($($Script:Config.Stage3Threshold) days) - Uptime: $uptimeDays days" -Level Warning
    }
    elseif ($uptimeDays -ge $Script:Config.Stage2Threshold) {
        $remediationNeeded = $true
        $targetStage = 2
        Write-Log "Stage 2 threshold reached ($($Script:Config.Stage2Threshold) days) - Uptime: $uptimeDays days" -Level Warning
    }
    elseif ($uptimeDays -ge $Script:Config.Stage1Threshold) {
        $remediationNeeded = $true
        $targetStage = 1
        Write-Log "Stage 1 threshold reached ($($Script:Config.Stage1Threshold) days) - Uptime: $uptimeDays days" -Level Info
    }
    else {
        Write-Log "Uptime ($uptimeDays days) is below Stage 1 threshold ($($Script:Config.Stage1Threshold) days)" -Level Info
    }
    
    # Store uptime in registry for remediation script
    try {
        Set-ItemProperty -Path $Script:Config.RegistryPath -Name "UptimeDays" -Value $uptimeDays -Force
        Set-ItemProperty -Path $Script:Config.RegistryPath -Name "LastCheck" -Value (Get-Date -Format "yyyy-MM-dd HH:mm:ss") -Force
        Write-Log "Stored uptime data in registry" -Level Info
    }
    catch {
        Write-Log "Error storing uptime data: $_" -Level Warning
    }
    
    # Exit with appropriate code
    if ($remediationNeeded) {
        Write-Log "DETECTION RESULT: Non-Compliant - Remediation required (Target Stage: $targetStage)" -Level Warning
        Write-Log "===== Detection Complete =====" -Level Info
        exit 1
    }
    else {
        Write-Log "DETECTION RESULT: Compliant - No action needed" -Level Info
        Write-Log "===== Detection Complete =====" -Level Info
        exit 0
    }
}

# ================================
# SCRIPT EXECUTION
# ================================
try {
    Start-Detection
}
catch {
    Write-Log "Unexpected error in detection script: $_" -Level Error
    Write-Log "Stack trace: $($_.ScriptStackTrace)" -Level Error
    # Exit compliant on unexpected errors to avoid false positives
    exit 0
}