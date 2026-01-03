<#
.SYNOPSIS
    Intune Proactive Remediation - Remediation Script for Uptime-Based Reboot Notifications
.DESCRIPTION
    Displays progressive toast notifications based on system uptime and notification stage.
    Stage 1: Dismissible reminder (2+ days)
    Stage 2: Strong recommendation (4+ days)
    Stage 3: Final warning with auto-reboot (6+ days)
.NOTES
    Author: Ashpak Shaikh
    Version: 1.0
    Run As: SYSTEM
    Architecture: 64-bit only
    
    Uses native Windows Toast Notifications via COM (Windows.UI.Notifications)
    No external dependencies required
#>

#Requires -Version 5.1
#Requires -RunAsAdministrator

# ================================
# CONFIGURATION
# ================================
$Script:Config = @{
    RegistryPath = "HKLM:\SOFTWARE\IntuneRebootNotifier"
    AppId = "IntuneRebootNotifier"
    CompanyName = "IT Department"
    Stage3CountdownMinutes = 20
    LogPrefix = "[REMEDY]"
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

function Set-NotificationStage {
    param([int]$Stage)
    try {
        if (-not (Test-Path $Script:Config.RegistryPath)) {
            New-Item -Path $Script:Config.RegistryPath -Force | Out-Null
        }
        Set-ItemProperty -Path $Script:Config.RegistryPath -Name "Stage" -Value $Stage -Force
        Set-ItemProperty -Path $Script:Config.RegistryPath -Name "LastNotification" -Value (Get-Date -Format "yyyy-MM-dd HH:mm:ss") -Force
        Write-Log "Updated notification stage to: $Stage" -Level Info
    }
    catch {
        Write-Log "Error setting notification stage: $_" -Level Error
    }
}

function Get-UptimeDays {
    try {
        if (Test-Path $Script:Config.RegistryPath) {
            $uptime = Get-ItemProperty -Path $Script:Config.RegistryPath -Name "UptimeDays" -ErrorAction SilentlyContinue
            if ($uptime) {
                return [double]$uptime.UptimeDays
            }
        }
        # Fallback calculation
        $os = Get-CimInstance -ClassName Win32_OperatingSystem
        $uptimeDays = ((Get-Date) - $os.LastBootUpTime).TotalDays
        return [math]::Round($uptimeDays, 2)
    }
    catch {
        Write-Log "Error reading uptime: $_" -Level Error
        return 0
    }
}

# ================================
# USER SESSION FUNCTIONS
# ================================
function Get-LoggedOnUser {
    try {
        $sessions = quser 2>&1
        if ($sessions -match "No User exists") {
            return $null
        }
        
        # Parse quser output to get username
        $sessionLines = $sessions | Where-Object { $_ -match '\s+\d+\s+' -and $_ -notmatch "SESSIONNAME" }
        if ($sessionLines) {
            $firstSession = $sessionLines | Select-Object -First 1
            $username = ($firstSession -split '\s+')[1]
            return $username
        }
        
        return $null
    }
    catch {
        Write-Log "Error getting logged on user: $_" -Level Warning
        return $null
    }
}

function Get-ActiveUserSessionId {
    try {
        $quser = quser 2>&1
        if ($quser -match "No User exists") {
            return $null
        }
        
        foreach ($line in $quser) {
            if ($line -match '^\s*(\S+)\s+(\S+)?\s+(\d+)\s+Active') {
                $sessionId = $matches[3]
                Write-Log "Found active session ID: $sessionId" -Level Info
                return $sessionId
            }
        }
        return $null
    }
    catch {
        Write-Log "Error getting session ID: $_" -Level Warning
        return $null
    }
}

# ================================
# TOAST NOTIFICATION FUNCTIONS
# ================================
function Show-ToastNotification {
    param(
        [string]$Title,
        [string]$Message,
        [string]$ActionButtonText = "Restart Now",
        [string]$DismissButtonText = "Dismiss",
        [bool]$ShowDismissButton = $true,
        [string]$Scenario = "reminder"
    )
    
    try {
        Write-Log "Attempting to show toast notification: $Title" -Level Info
        
        # Get active session
        $sessionId = Get-ActiveUserSessionId
        if (-not $sessionId) {
            Write-Log "No active user session found - cannot show toast" -Level Warning
            return $false
        }
        
        # Build toast XML
        $dismissSection = if ($ShowDismissButton) {
            "<action content='$DismissButtonText' arguments='dismiss' activationType='system'/>"
        } else { "" }
        
        [xml]$toastXml = @"
<toast scenario="$Scenario">
    <visual>
        <binding template="ToastGeneric">
            <text><![CDATA[$Title]]></text>
            <text><![CDATA[$Message]]></text>
        </binding>
    </visual>
    <actions>
        <action content="$ActionButtonText" arguments="restart" activationType="protocol" />
        $dismissSection
    </actions>
    <audio src="ms-winsoundevent:Notification.Default" />
</toast>
"@

        # Create script to show toast in user context
        $toastScript = @"
`$ErrorActionPreference = 'Stop'
try {
    [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
    [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime] | Out-Null
    
    `$appId = '$($Script:Config.AppId)'
    `$xml = [Windows.Data.Xml.Dom.XmlDocument]::new()
    `$xml.LoadXml(@'
$($toastXml.OuterXml)
'@)
    
    `$toast = [Windows.UI.Notifications.ToastNotification]::new(`$xml)
    
    # Handle button clicks
    `$toast.add_Activated({
        param(`$sender, `$args)
        if (`$args.Arguments -eq 'restart') {
            Start-Process 'shutdown.exe' -ArgumentList '/r /t 0' -NoNewWindow
        }
    })
    
    [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier(`$appId).Show(`$toast)
} catch {
    Write-Error "Toast error: `$_"
    exit 1
}
"@

        # Save script to temp location
        $scriptPath = "$env:TEMP\ShowToast_$sessionId.ps1"
        $toastScript | Out-File -FilePath $scriptPath -Encoding UTF8 -Force
        
        # Execute in user session using scheduled task (runs as logged on user)
        $taskName = "IntuneRebootToast_$sessionId"
        $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$scriptPath`""
        
        # Get current logged on user
        $username = Get-LoggedOnUser
        if (-not $username) {
            Write-Log "Could not determine logged on user" -Level Warning
            return $false
        }
        
        $principal = New-ScheduledTaskPrincipal -UserId $username -LogonType Interactive
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
        
        # Register and run task
        Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Settings $settings -Force | Out-Null
        Start-ScheduledTask -TaskName $taskName
        
        # Wait briefly then cleanup
        Start-Sleep -Seconds 3
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
        Remove-Item -Path $scriptPath -Force -ErrorAction SilentlyContinue
        
        Write-Log "Toast notification displayed successfully" -Level Info
        return $true
    }
    catch {
        Write-Log "Error showing toast notification: $_" -Level Error
        return $false
    }
}

# ================================
# STAGE-SPECIFIC NOTIFICATION HANDLERS
# ================================
function Invoke-Stage1Notification {
    param([double]$UptimeDays)
    
    Write-Log "===== STAGE 1: Initial Reminder =====" -Level Info
    
    $title = "System Restart Recommended"
    $message = "Your system has not been restarted for $([math]::Round($UptimeDays, 1)) days. Please restart soon for optimal security and performance."
    
    $success = Show-ToastNotification -Title $title -Message $message -ShowDismissButton $true
    
    if ($success) {
        Set-NotificationStage -Stage 1
        Write-Log "Stage 1 notification shown - user can dismiss" -Level Info
    }
    else {
        Write-Log "Failed to show Stage 1 notification" -Level Warning
    }
}

function Invoke-Stage2Notification {
    param([double]$UptimeDays)
    
    Write-Log "===== STAGE 2: Strong Recommendation =====" -Level Warning
    
    $title = "⚠️ System Restart Required"
    $message = "Second notice: Your system has not been restarted for $([math]::Round($UptimeDays, 1)) days. Please restart as soon as possible to ensure security updates are applied."
    
    $success = Show-ToastNotification -Title $title -Message $message -ShowDismissButton $true -Scenario "urgent"
    
    if ($success) {
        Set-NotificationStage -Stage 2
        Write-Log "Stage 2 notification shown - urgent reminder" -Level Info
    }
    else {
        Write-Log "Failed to show Stage 2 notification" -Level Warning
    }
}

function Invoke-Stage3Notification {
    param([double]$UptimeDays)
    
    Write-Log "===== STAGE 3: Final Warning with Auto-Reboot =====" -Level Error
    
    $countdownMinutes = $Script:Config.Stage3CountdownMinutes
    $title = "🛑 FINAL WARNING: Automatic Restart Scheduled"
    $message = "Your system has not been restarted for $([math]::Round($UptimeDays, 1)) days. An automatic restart will occur in $countdownMinutes minutes. SAVE ALL WORK NOW!"
    
    # Show non-dismissible notification
    $success = Show-ToastNotification -Title $title -Message $message -ShowDismissButton $false -Scenario "urgent"
    
    if ($success) {
        Set-NotificationStage -Stage 3
        Write-Log "Stage 3 notification shown - auto-reboot scheduled" -Level Warning
    }
    
    # Schedule forced reboot
    $rebootTime = (Get-Date).AddMinutes($countdownMinutes)
    Write-Log "Scheduling forced reboot for: $rebootTime" -Level Warning
    
    try {
        # Create scheduled task for forced reboot
        $taskName = "IntuneForceReboot"
        $action = New-ScheduledTaskAction -Execute "shutdown.exe" -Argument "/r /f /t 60 /c `"System restart required for security and performance. This restart was scheduled by IT.`""
        $trigger = New-ScheduledTaskTrigger -Once -At $rebootTime
        $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
        
        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
        Write-Log "Forced reboot scheduled successfully via task: $taskName" -Level Info
        
        # Store reboot schedule info
        Set-ItemProperty -Path $Script:Config.RegistryPath -Name "ScheduledRebootTime" -Value $rebootTime.ToString("yyyy-MM-dd HH:mm:ss") -Force
    }
    catch {
        Write-Log "Error scheduling forced reboot: $_" -Level Error
        # Fallback: immediate notification and shorter timer
        Write-Log "Attempting fallback immediate warning with 5 minute timer" -Level Warning
        Start-Process "shutdown.exe" -ArgumentList "/r /t 300 /c `"System restart required. Reboot in 5 minutes.`"" -NoNewWindow
    }
}

# ================================
# CLEANUP FUNCTION
# ================================
function Clear-RebootNotifierData {
    Write-Log "Clearing reboot notifier registry data" -Level Info
    try {
        if (Test-Path $Script:Config.RegistryPath) {
            Remove-Item -Path $Script:Config.RegistryPath -Recurse -Force
            Write-Log "Registry data cleared successfully" -Level Info
        }
        
        # Remove any pending scheduled reboot tasks
        $taskName = "IntuneForceReboot"
        $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        if ($task) {
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
            Write-Log "Removed scheduled reboot task" -Level Info
        }
    }
    catch {
        Write-Log "Error during cleanup: $_" -Level Warning
    }
}

# ================================
# MAIN REMEDIATION LOGIC
# ================================
function Start-Remediation {
    Write-Log "===== Starting Remediation =====" -Level Info
    
    # Check if user is logged on
    $loggedOnUser = Get-LoggedOnUser
    if (-not $loggedOnUser) {
        Write-Log "No user logged on - scheduling system reboot for maintenance window" -Level Warning
        # Schedule reboot for 2 AM next day
        try {
            $nextReboot = (Get-Date).Date.AddDays(1).AddHours(2)
            $taskName = "IntuneMaintenanceReboot"
            $action = New-ScheduledTaskAction -Execute "shutdown.exe" -Argument "/r /f /t 60"
            $trigger = New-ScheduledTaskTrigger -Once -At $nextReboot
            $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
            Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Force | Out-Null
            Write-Log "Scheduled maintenance reboot for: $nextReboot" -Level Info
        }
        catch {
            Write-Log "Error scheduling maintenance reboot: $_" -Level Error
        }
        exit 0
    }
    
    Write-Log "User logged on: $loggedOnUser" -Level Info
    
    # Get current uptime and stage
    $uptimeDays = Get-UptimeDays
    $currentStage = Get-NotificationStage
    
    Write-Log "Current uptime: $uptimeDays days" -Level Info
    Write-Log "Current notification stage: $currentStage" -Level Info
    
    # Determine which stage notification to show
    if ($uptimeDays -ge 6) {
        # Stage 3: Final warning with forced reboot
        if ($currentStage -lt 3) {
            Invoke-Stage3Notification -UptimeDays $uptimeDays
        }
        else {
            Write-Log "Stage 3 already processed - forced reboot should be scheduled" -Level Info
        }
    }
    elseif ($uptimeDays -ge 4) {
        # Stage 2: Strong recommendation
        if ($currentStage -lt 2) {
            Invoke-Stage2Notification -UptimeDays $uptimeDays
        }
        else {
            Write-Log "Stage 2 already processed - waiting for Stage 3 threshold" -Level Info
        }
    }
    elseif ($uptimeDays -ge 2) {
        # Stage 1: Initial reminder
        if ($currentStage -lt 1) {
            Invoke-Stage1Notification -UptimeDays $uptimeDays
        }
        else {
            Write-Log "Stage 1 already processed - waiting for Stage 2 threshold" -Level Info
        }
    }
    else {
        Write-Log "Uptime below all thresholds - no notification needed" -Level Info
        # Clear any existing data if system was recently rebooted
        if ($currentStage -gt 0) {
            Clear-RebootNotifierData
        }
    }
    
    Write-Log "===== Remediation Complete =====" -Level Info
    exit 0
}

# ================================
# SCRIPT EXECUTION
# ================================
try {
    Start-Remediation
}
catch {
    Write-Log "Unexpected error in remediation script: $_" -Level Error
    Write-Log "Stack trace: $($_.ScriptStackTrace)" -Level Error
    exit 1
}