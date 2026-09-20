<#
.SYNOPSIS
    Writes pending update data to disk and triggers the user-facing update prompt.

.DESCRIPTION
    Serializes the list of pending apps and reminder config into pending-updates.json,
    then fires the Winget-AutoUpdate-UpdatePrompt scheduled task which presents the
    WPF deadline dialog to the logged-in user.

    This function is fire-and-forget -- it returns immediately after starting the task.
    The caller should not poll for task completion.

    The JSON payload format:
        {
          "Config": { "ReminderIntervalHours": 2, "ReminderIntervalDays": 1, "CompanyName": "" },
          "Apps": [
            { "Name": "...", "Id": "...", "Version": "...", "AvailableVersion": "...", "Deadline": "yyyy-MM-dd HH:mm:ss" },
            ...
          ]
        }

.PARAMETER PendingApps
    Array of PSCustomObjects, each with:
        Name             [string] - Display name of the application
        Id               [string] - Winget package identifier
        Version          [string] - Currently installed version
        AvailableVersion [string] - Available version to install
        Deadline         [string] - Deadline date as "yyyy-MM-dd HH:mm:ss" string

    The caller is responsible for enriching deadline entries with Name and Version
    from the Get-WingetOutdatedApps result before calling this function.

.PARAMETER ReminderIntervalHours
    Number of hours to snooze when the user dismisses the dialog.
    Written into the JSON Config envelope so the prompt script does not
    need to independently re-read WAU configuration.
#>
function Start-UpdatePromptTask {

    param(
        [Parameter(Mandatory = $true)]
        [array]$PendingApps,

        [Parameter(Mandatory = $true)]
        [int]$ReminderIntervalHours,

        [Parameter(Mandatory = $false)]
        [string]$CompanyName = '',
        [string]$UserSid = '',
        [bool]$InventoryComplete = $true
    )

    $ConfigDir = Join-Path $WAUConfig.InstallLocation "config"
    $JsonPath  = Join-Path $ConfigDir "pending-updates.json"

    # Build the payload. @($PendingApps) forces array serialization in JSON
    # even when only a single app is pending.
    $payload = [PSCustomObject]@{
        Config = [PSCustomObject]@{
            ReminderIntervalHours = $ReminderIntervalHours
            ReminderIntervalDays  = [math]::Max(1, [int][math]::Round($ReminderIntervalHours / 24))
            CompanyName           = $CompanyName
            UserSid               = $UserSid
            InventoryComplete     = $InventoryComplete
        }
        Apps = @($PendingApps)
    }

    try {
        Write-WauAtomicJson -Path $JsonPath -Value $payload
        Write-ToLog "Pending updates written: $($PendingApps.Count) apps - $JsonPath"
    }
    catch {
        Write-ToLog "ERROR: Could not write pending-updates.json -- $($_.Exception.Message)" "Red"
        return
    }

    # Trigger the UpdatePrompt task. This runs WAU-UpdatePrompt.ps1 via ServiceUI.exe
    # in the logged-in user's desktop session. The main task exits immediately after.
    $promptTask = Get-ScheduledTask -TaskName "Winget-AutoUpdate-UpdatePrompt" -ErrorAction SilentlyContinue
    if ($promptTask) {
        try {
            $promptTask | Start-ScheduledTask -ErrorAction Stop
            Write-ToLog "Winget-AutoUpdate-UpdatePrompt task triggered"
        }
        catch {
            Write-ToLog "WARNING: Failed to start Winget-AutoUpdate-UpdatePrompt task -- $($_.Exception.Message)" "Yellow"
        }
    }
    else {
        # File-only deployments do not register the helper task. The main process
        # already runs as SYSTEM in the interactive session through ServiceUI.
        try {
            $promptCommand = "& '$([System.IO.Path]::Combine($Script:WorkingDir, 'WAU-UpdatePrompt.ps1'))'"
            $encodedPrompt = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($promptCommand))
            Start-Process -FilePath "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" `
                -ArgumentList "-NoProfile -ExecutionPolicy Bypass -Sta -WindowStyle Hidden -EncodedCommand $encodedPrompt" `
                -WorkingDirectory $Script:WorkingDir -ErrorAction Stop
            Write-ToLog 'UpdatePrompt helper task missing; prompt launched directly.' 'Yellow'
        }
        catch { Write-ToLog "ERROR: Update prompt could not be launched: $($_.Exception.Message)" 'Red' }
    }
}
