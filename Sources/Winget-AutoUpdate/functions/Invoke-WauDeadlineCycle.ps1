function Get-WauBlockReason {
    param($App)
    if (-not ($App.Scope -eq 'user' -and $Script:WAUConfig.WAU_BypassListForUsers -eq 1)) {
        if ($Script:WAUConfig.WAU_UseWhiteList -eq 1) {
            $included = @(Get-IncludedApps)
            if (-not @($included | Where-Object { $App.Id -like $_ }).Count) { return 'Not in allowlist' }
        }
        else {
            $excluded = @(Get-ExcludedApps)
            if (@($excluded | Where-Object { $App.Id -like $_ }).Count) { return 'Excluded by policy/list' }
        }
    }
    if (Test-PackageDeferral -App $App -Config $Script:WAUConfig -Source $App.Source -WorkingDir $Script:WorkingDir) {
        if ($App -and $App.DeferUntil) {
            return "Deferred by policy (until $($App.DeferUntil))"
        }
        return 'Deferred by policy'
    }
    return ''
}

function Invoke-WauDeadlineCycle {
    param([int]$DeadlineHours, [int]$ReminderIntervalHours)
    $apps = @(Get-WingetOutdatedApps -src $Script:WingetSourceCustom -Scope machine)
    $userSid = Get-WauInteractiveUser
    $inventoryComplete = $true
    if ($userSid) {
        try {
            $userApps = @(Invoke-WauUserOperation -Operation Scan -UserSid $userSid)
            foreach ($item in $userApps) {
                # Treat all user responses as untrusted. Rebuild data-only objects;
                # never accept a user-supplied scope, source, key or approval.
                if ($item.Id -notmatch '^[A-Za-z0-9][A-Za-z0-9._+\-]{0,255}$' -or
                    $item.AvailableVersion -notmatch '^[^\s\-\x00-\x1f][^\x00-\x1f]{0,127}$') { throw 'Invalid user inventory identity/version.' }
                $app = [pscustomobject]@{ Id=[string]$item.Id; Name=[string]$item.Name; Version=[string]$item.Version
                    AvailableVersion=[string]$item.AvailableVersion; Scope='user'; UserSid=$userSid; Source=$Script:WingetSourceCustom
                    UserInstallerSupport= if ($item.UserInstallerSupport -in @('Supported','Unavailable','Unknown')) { $item.UserInstallerSupport } else { 'Unknown' }
                    MachineInstallerSupport= if ($item.MachineInstallerSupport -in @('Supported','Unavailable','Unknown')) { $item.MachineInstallerSupport } else { 'Unknown' } }
                $app | Add-Member NoteProperty Key (Get-WauAppKey $app)
                $apps += $app
            }
        }
        catch { $inventoryComplete = $false; Write-ToLog "User inventory incomplete: $_" 'Yellow' }
    }
    # Retain scope/SID identity even when a package exists twice.
    $apps = @($apps | Sort-Object Key -Unique)
    foreach ($app in $apps) {
        $app | Add-Member NoteProperty BlockReason (Get-WauBlockReason $app) -Force
        $app | Add-Member NoteProperty CanUpdate ([string]::IsNullOrEmpty($app.BlockReason)) -Force
        $null = Set-WauScopePlan -App $app -Source $app.Source
        if ($app.InstallerSupport -eq 'Unavailable' -and -not $app.RequiresScopeMigration) {
            $app.BlockReason = 'No compatible installer for existing scope'
            $app.CanUpdate = $false
        }
        Set-UpdateDeadline -App $app -DeadlineHours $DeadlineHours
    }
    # Do not purge another user's deadlines or treat a failed scan as an empty scan.
    $deadlines = @(Get-UpdateDeadlines)
    foreach ($entry in $deadlines) {
        $scanned = $entry.Scope -eq 'machine' -or ($inventoryComplete -and $userSid -and $entry.Scope -eq 'user' -and $entry.UserSid -eq $userSid)
        if ($scanned -and $entry.AppId -notin @($apps | ForEach-Object Key)) {
            Remove-WauUpdateDeadline -App $entry
        }
    }
    $promptApps = @()
    foreach ($app in $apps) {
        $entry = $deadlines | Where-Object { $_.AppId -eq $app.Key } | Select-Object -First 1
        if (-not $entry) { continue }
        if ($app.CanUpdate -and $app.Scope -eq 'machine' -and $app.Version -ne 'Unknown' -and $entry.Deadline -lt (Get-Date)) {
            $before = $Script:InstallOK
            Update-App $app -src $app.Source
            if ($Script:InstallOK -gt $before) {
                Remove-WauUpdateDeadline -App $app
                continue
            }
        }
        $app | Add-Member NoteProperty Deadline ($entry.Deadline.ToString('yyyy-MM-dd HH:mm:ss')) -Force
        $promptApps += $app
    }
    if (-not $userSid -or -not $promptApps.Count) { return }
    $reg = 'HKLM:\SOFTWARE\Romanitho\Winget-AutoUpdate'
    $next = (Get-ItemProperty $reg -Name NextPromptTime -ErrorAction SilentlyContinue).NextPromptTime
    $date = [datetime]::MinValue
    if ($next -and [datetime]::TryParse($next, [ref]$date) -and $date -gt (Get-Date)) { return }
    Start-UpdatePromptTask -PendingApps $promptApps -ReminderIntervalHours $ReminderIntervalHours `
        -CompanyName $Script:WAUConfig.WAU_CompanyName -UserSid $userSid -InventoryComplete $inventoryComplete
}
