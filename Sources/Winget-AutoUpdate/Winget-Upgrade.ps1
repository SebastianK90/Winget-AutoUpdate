#region LOAD FUNCTIONS
# Get the Working Dir
[string]$Script:WorkingDir = $PSScriptRoot

# Get Functions
Get-ChildItem -Path "$($Script:WorkingDir)\functions" -File -Filter "*.ps1" -Depth 0 | ForEach-Object { . $_.FullName }
#endregion LOAD FUNCTIONS

#region INITIALIZATION
# Config console output encoding
$null = & "$env:WINDIR\System32\cmd.exe" /c ""
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$Script:ProgressPreference = [System.Management.Automation.ActionPreference]::SilentlyContinue

# Set GitHub Repo
[string]$Script:GitHub_Repo = "Winget-AutoUpdate"

# Log initialization
[string]$LogFile = [System.IO.Path]::Combine($Script:WorkingDir, 'logs', 'updates.log')
#endregion INITIALIZATION

#region CONTEXT
# Check if running account is system or interactive logon System(default) otherwise User
[bool]$Script:IsSystem = [System.Security.Principal.WindowsIdentity]::GetCurrent().IsSystem

# Check for current session ID (O = system without ServiceUI)
[Int32]$Script:SessionID = [System.Diagnostics.Process]::GetCurrentProcess().SessionId
#endregion CONTEXT

#region EXECUTION CONTEXT AND LOGGING
# Preparation to run in current context
if ($true -eq $IsSystem) {

    #If log file doesn't exist, force create it
    if (!(Test-Path -Path $LogFile)) {
        Write-ToLog "New log file created"
    }

    #Check if running with session ID 0
    if ($SessionID -eq 0) {
        #Check if ServiceUI exists
        [string]$ServiceUIexe = [System.IO.Path]::Combine($Script:WorkingDir, 'ServiceUI.exe')
        [bool]$IsServiceUI = Test-Path $ServiceUIexe -PathType Leaf
        if ($true -eq $IsServiceUI) {
            #Check if any connected user
            $explorerprocesses = @(Get-CimInstance -Query "SELECT * FROM Win32_Process WHERE Name='explorer.exe'" -ErrorAction SilentlyContinue)
            if ($explorerprocesses.Count -gt 0) {
                Write-ToLog "Rerun WAU in system context with ServiceUI"
                Start-Process `
                    -FilePath $ServiceUIexe `
                    -ArgumentList "-process:explorer.exe $env:windir\System32\conhost.exe --headless powershell.exe -NoProfile -ExecutionPolicy Bypass -File winget-upgrade.ps1" `
                    -WorkingDirectory $WorkingDir
                Wait-Process "ServiceUI" -ErrorAction SilentlyContinue
                Exit 0
            }
            else {
                Write-ToLog -LogMsg "CHECK FOR APP UPDATES (System context)" -IsHeader
            }
        }
        else {
            Write-ToLog -LogMsg "CHECK FOR APP UPDATES (System context - No ServiceUI)" -IsHeader
        }
    }
    else {
        Write-ToLog -LogMsg "CHECK FOR APP UPDATES (System context - Connected user)" -IsHeader
    }
}
else {
    Write-ToLog -LogMsg "CHECK FOR APP UPDATES (User context)" -IsHeader
}
#endregion EXECUTION CONTEXT AND LOGGING

# Prevent overlapping runs in the same security context. SYSTEM and the fixed
# interactive user task intentionally use different mutexes and can cooperate.
$mutexName = if ($Script:IsSystem) { 'Global\Winget-AutoUpdate-System' }
             else { 'Local\Winget-AutoUpdate-User-' + [Security.Principal.WindowsIdentity]::GetCurrent().User.Value }
$Script:RunMutex = New-Object Threading.Mutex($false, $mutexName)
if (-not $Script:RunMutex.WaitOne(0)) {
    Write-ToLog 'Another WAU run is already active in this security context; exiting.' 'Yellow'
    Exit 0
}

#region CONFIG & POLICIES
Write-ToLog "Reading WAUConfig"
$Script:WAUConfig = Get-WAUConfig
#endregion CONFIG & POLICIES

#region WINGET SOURCE
# Defining a custom source even if not used below (failsafe suggested by github/sebneus mentioned in issues/823)
[string]$Script:WingetSourceCustom = 'winget'

# Defining custom repository for winget tool
if (-not [string]::IsNullOrWhiteSpace($Script:WAUConfig.WAU_WingetSourceCustom)) {
    $Script:WingetSourceCustom = $Script:WAUConfig.WAU_WingetSourceCustom.Trim()
    Write-ToLog "Selecting winget repository named '$($Script:WingetSourceCustom)'"
}
#endregion WINGET SOURCE

#region Log running context
if ($true -eq $IsSystem) {

    # Maximum number of log files to keep. Default is 3. Setting MaxLogFiles to 0 will keep all log files.
    $MaxLogFiles = $WAUConfig.WAU_MaxLogFiles
    if ($null -eq $MaxLogFiles) {
        [int32]$MaxLogFiles = 3
    }
    else {
        [int32]$MaxLogFiles = $MaxLogFiles
    }

    # Maximum size of log file.
    $MaxLogSize = $WAUConfig.WAU_MaxLogSize
    if (!$MaxLogSize) {
        [int64]$MaxLogSize = [int64]1MB # in bytes, default is 1 MB = 1048576
    }
    else {
        [int64]$MaxLogSize = $MaxLogSize
    }

    #LogRotation if System
    [bool]$LogRotate = Invoke-LogRotation $LogFile $MaxLogFiles $MaxLogSize
    if ($false -eq $LogRotate) {
        Write-ToLog "An Exception occurred during Log Rotation..."
    }
}
#endregion Log running context

#region Run Scope Machine function if run as System
if ($true -eq $IsSystem) {
    Add-ScopeMachine
}
#endregion Run Scope Machine function if run as System

#region Get Notif Locale function
[string]$LocaleDisplayName = Get-NotifLocale
Write-ToLog "Notification Level: $($WAUConfig.WAU_NotificationLevel). Notification Language: $LocaleDisplayName" "Cyan"
#endregion Get Notif Locale function

#region MAIN
#Check network connectivity
if (Test-Network) {

    #Check prerequisites
    if ($true -eq $IsSystem) {
        Install-Prerequisites
    }

    #Check if Winget is installed and get Winget cmd
    [string]$Script:Winget = Get-WingetCmd
    Write-ToLog "Selected winget instance: $($Script:Winget)"

    if ($Script:Winget) {

        # The existing fixed UserContext task processes one pending request and
        # exits. No per-run scheduled task is created.
        if (-not $Script:IsSystem -and (Invoke-WauPendingUserOperation)) {
            Write-ToLog 'User-context request completed.' 'Cyan'
            Exit 0
        }

        if ($true -eq $IsSystem) {

            #Get Current Version
            $WAUCurrentVersion = $WAUConfig.ProductVersion
            Write-ToLog "WAU current version: $WAUCurrentVersion"

            #Check if WAU update feature is enabled or not if run as System
            $WAUDisableAutoUpdate = $WAUConfig.WAU_DisableAutoUpdate
            #If yes then check WAU update if run as System
            if ($WAUDisableAutoUpdate -eq 1) {
                Write-ToLog "WAU AutoUpdate is Disabled." "Gray"
            }
            else {
                Write-ToLog "WAU AutoUpdate is Enabled." "Green"
                #Get Available Version
                $Script:WAUAvailableVersion = Get-WAUAvailableVersion
                #Compare
                if ((Compare-SemVer -Version1 $WAUCurrentVersion -Version2 $WAUAvailableVersion) -lt 0) {
                    #If new version is available, update it
                    Write-ToLog "WAU Available version: $WAUAvailableVersion" "DarkYellow"
                    Update-WAU
                }
                else {
                    Write-ToLog "WAU is up to date." "Green"
                }
            }

            #Delete previous list_/winget_error (if they exist) if run as System
            [string]$fp4 = [System.IO.Path]::Combine($Script:WorkingDir, 'logs', 'error.txt')
            if (Test-Path $fp4) {
                Remove-Item $fp4 -Force
            }

            #Get External ListPath if run as System
            if ($WAUConfig.WAU_ListPath) {
                $ListPathClean = $($WAUConfig.WAU_ListPath.TrimEnd(" ", "\", "/"))
                Write-ToLog "WAU uses External Lists from: $ListPathClean"
                if ($ListPathClean -ne "GPO") {
                    $NewList = Test-ListPath $ListPathClean $WAUConfig.WAU_UseWhiteList $WAUConfig.InstallLocation.TrimEnd(" ", "\")
                    if ($ReachNoPath) {
                        Write-ToLog "Couldn't reach/find/compare/copy from $ListPathClean..." "Red"
                        if ($ListPathClean -notlike "http*") {
                            if (Test-Path -Path "$ListPathClean" -PathType Leaf) {
                                Write-ToLog "PATH must end with a Directory, not a File..." "Red"
                            }
                        }
                        else {
                            if ($ListPathClean -match "_apps.txt") {
                                Write-ToLog "PATH must end with a Directory, not a File..." "Red"
                            }
                        }
                        $Script:ReachNoPath = $False
                    }
                    if ($NewList) {
                        if ($AlwaysDownloaded) {
                            Write-ToLog "List downloaded/copied to local path: $($WAUConfig.InstallLocation.TrimEnd(" ", "\"))" "DarkYellow"
                        }
                        else {
                            Write-ToLog "Newer List downloaded/copied to local path: $($WAUConfig.InstallLocation.TrimEnd(" ", "\"))" "DarkYellow"
                        }
                        $Script:AlwaysDownloaded = $False
                    }
                    else {
                        if ($WAUConfig.WAU_UseWhiteList -and (Test-Path "$WorkingDir\included_apps.txt")) {
                            Write-ToLog "List (white) is up to date." "Green"
                        }
                        elseif (!$WAUConfig.WAU_UseWhiteList -and (Test-Path "$WorkingDir\excluded_apps.txt")) {
                            Write-ToLog "List (black) is up to date." "Green"
                        }
                        else {
                            Write-ToLog "Critical: White/Black List doesn't exist, exiting..." "Red"
                            New-Item "$WorkingDir\logs\error.txt" -Value "White/Black List doesn't exist" -Force
                            Exit 1
                        }
                    }
                }
            }

            #Get External ModsPath if run as System
            if ($WAUConfig.WAU_ModsPath) {
                $ModsPathClean = $($WAUConfig.WAU_ModsPath.TrimEnd(" ", "\", "/"))
                Write-ToLog "WAU uses External Mods from: $ModsPathClean"
                if ($WAUConfig.WAU_AzureBlobSASURL) {
                    $NewMods, $DeletedMods = Test-ModsPath $ModsPathClean $WAUConfig.InstallLocation.TrimEnd(" ", "\") $WAUConfig.WAU_AzureBlobSASURL.TrimEnd(" ")
                }
                else {
                    $NewMods, $DeletedMods = Test-ModsPath $ModsPathClean $WAUConfig.InstallLocation.TrimEnd(" ", "\")
                }
                if ($ReachNoPath) {
                    Write-ToLog "Couldn't reach/find/compare/copy from $ModsPathClean..." "Red"
                    $Script:ReachNoPath = $False
                }
                if ($NewMods -gt 0) {
                    Write-ToLog "$NewMods newer Mods downloaded/copied to local path: $($WAUConfig.InstallLocation.TrimEnd(" ", "\"))\mods" "DarkYellow"
                }
                else {
                    if (Test-Path "$WorkingDir\mods\*.ps1") {
                        Write-ToLog "Mods are up to date." "Green"
                    }
                    else {
                        Write-ToLog "No Mods are implemented..." "DarkYellow"
                    }
                }
                if ($DeletedMods -gt 0) {
                    Write-ToLog "$DeletedMods Mods deleted (not externally managed) from local path: $($WAUConfig.InstallLocation.TrimEnd(" ", "\"))\mods" "Red"
                }
            }

            # Test if _WAU-mods.ps1 exist: Mods for WAU (if Network is active/any Winget is installed/running as SYSTEM)
            $Mods = "$WorkingDir\mods"
            if (Test-Path "$Mods\_WAU-mods.ps1") {
                Write-ToLog "Running Mods for WAU..." "DarkYellow"
                Test-WAUMods -WorkingDir $WorkingDir -WAUConfig $WAUConfig -GitHub_Repo $GitHub_Repo
            }

        }

        #Get White or Black list
        if ($WAUConfig.WAU_UseWhiteList -eq 1) {
            Write-ToLog "WAU uses White List config"
            $toUpdate = Get-IncludedApps
            $UseWhiteList = $true
        }
        else {
            Write-ToLog "WAU uses Black List config"
            $toSkip = Get-ExcludedApps
        }

        #region DEADLINE CONFIG
        # Read update deadline settings. Both contexts need to know if deadline mode
        # is active: SYSTEM manages deadlines, user context detects user-scoped apps.
        # DeadlineHours = 0 means deadline mode is disabled -- normal silent update behaviour applies.
        [int]$DeadlineHours = 0
        [int]$ReminderIntervalHours = 2
        if (![string]::IsNullOrWhiteSpace($WAUConfig.WAU_UpdateDeadlineHours)) {
            try { $DeadlineHours = [int]$WAUConfig.WAU_UpdateDeadlineHours } catch {}
        }
        elseif (![string]::IsNullOrWhiteSpace($WAUConfig.WAU_UpdateDeadlineDays)) {
            try { $DeadlineHours = [int]$WAUConfig.WAU_UpdateDeadlineDays * 24 } catch {}
        }

        if (![string]::IsNullOrWhiteSpace($WAUConfig.WAU_ReminderIntervalHours)) {
            try { $ReminderIntervalHours = [int]$WAUConfig.WAU_ReminderIntervalHours } catch {}
        }
        elseif (![string]::IsNullOrWhiteSpace($WAUConfig.WAU_ReminderIntervalDays)) {
            try { $ReminderIntervalHours = [int]$WAUConfig.WAU_ReminderIntervalDays * 24 } catch {}
        }

        if ($Script:IsSystem -and $DeadlineHours -le 0) {
            # When deadline mode is disabled, purge any leftover registry entries so that
            # re-enabling deadline mode later does not treat old entries as instantly overdue.
            $DeadlineRegPath = "HKLM:\SOFTWARE\Romanitho\Winget-AutoUpdate\UpdateDeadlines"
            if (Test-Path $DeadlineRegPath) {
                Remove-Item -Path $DeadlineRegPath -Recurse -Force -ErrorAction SilentlyContinue
                Write-ToLog "Deadline mode disabled -- registry entries purged"
            }
        }
        #endregion DEADLINE CONFIG
        # The interactive deadline GUI always inventories its owning user as well
        # as the machine. WAU_UserContext controls only the legacy silent task.
        $Script:InstallOK = 0
        if ($DeadlineHours -gt 0) {
            if ($Script:IsSystem) {
                Invoke-WauDeadlineCycle -DeadlineHours $DeadlineHours -ReminderIntervalHours $ReminderIntervalHours
            }
            else { Write-ToLog 'Deadline mode is coordinated by SYSTEM; use Run WAU to open the combined GUI.' }
            exit 0
        }
        $userContextTriggered = $false
        $migrationTriggeredOnly = $false

        # If running as SYSTEM, process any pending scope migrations approved by users
        if ($Script:IsSystem) {
            $userSubkeys = @([Microsoft.Win32.Registry]::Users.GetSubKeyNames() | Where-Object {
                $_ -match '^S-1-5-21-\d+-\d+-\d+-\d+$' -or $_ -match '^S-1-12-1-\d+-\d+-\d+-\d+$'
            })
            foreach ($sid in $userSubkeys) {
                $userWauPath = "Registry::HKEY_USERS\$sid\SOFTWARE\Romanitho\Winget-AutoUpdate"
                $trig = (Get-ItemProperty -LiteralPath $userWauPath -Name "ScopeMigrationTriggered" -ErrorAction SilentlyContinue).ScopeMigrationTriggered
                if ($trig -eq 1) {
                    $migrationTriggeredOnly = $true
                    Remove-ItemProperty -LiteralPath $userWauPath -Name "ScopeMigrationTriggered" -Force -ErrorAction SilentlyContinue
                }

                $approvedPath = "$userWauPath\ApprovedScopeMigrations"
                if (Test-Path -LiteralPath $approvedPath) {
                    $pendingApps = @(Get-ChildItem -LiteralPath $approvedPath -ErrorAction SilentlyContinue)
                    foreach ($regItem in $pendingApps) {
                        $props = Get-ItemProperty -LiteralPath $regItem.PSPath -ErrorAction SilentlyContinue
                        if ($props -and $props.PackageId) {
                            $pkgId = $props.PackageId
                            $pkgName = if ($props.Name) { $props.Name } else { $pkgId }
                            $pkgVer = $props.ApprovedVersion
                            $pkgCurVer = if ($props.CurrentVersion) { [string]$props.CurrentVersion } else { 'Unknown' }
                            $pkgSrc = if ($props.Source) { $props.Source } else { $Script:WingetSourceCustom }

                            Write-ToLog "Processing approved scope migration for $pkgName ($pkgId) to machine scope..." "Cyan"

                            $migApp = [pscustomobject]@{
                                Id = $pkgId
                                Name = $pkgName
                                Version = $pkgCurVer
                                AvailableVersion = $pkgVer
                                Scope = 'user'
                                TargetScope = 'machine'
                                ScopeMigrationApproved = $true
                                UserSid = $sid
                            }
                            $machineSupport = Get-WauInstallerSupport -App $migApp -Scope machine -Source $pkgSrc
                            if ($machineSupport -eq 'Supported') {
                                Update-App $migApp -src $pkgSrc
                                if (Confirm-Installation $pkgId $pkgVer $pkgSrc -Scope 'machine') {
                                    Write-ToLog "Scope migration to machine scope successful for $pkgName ($pkgId)." "Green"
                                }
                                else {
                                    Write-ToLog "Scope migration install did not result in confirmed machine installation for $pkgName ($pkgId)." "Yellow"
                                }
                            }
                            else {
                                Write-ToLog "Machine installer support no longer valid for $pkgName ($pkgId)." "Yellow"
                            }
                            Remove-Item -LiteralPath $regItem.PSPath -Recurse -Force -ErrorAction SilentlyContinue
                        }
                    }
                }
            }
        }

        if ($migrationTriggeredOnly) {
            $outdated = @()
        }
        else {
            $outdated = @(Get-WingetOutdatedApps -src $Script:WingetSourceCustom)
        }
        foreach ($app in $outdated) {
            $reason = Get-WauBlockReason $app
            if ($reason) { Write-ToLog "$($app.Name): $reason" 'Gray'; continue }
            if ($app.Version -eq 'Unknown') { Write-ToLog "$($app.Name): unknown version requires interactive review" 'Yellow'; continue }

            # Check for User -> Machine scope migration
            if ($app.Scope -eq 'user') {
                $userSupport = Get-WauInstallerSupport -App $app -Scope user -Source $Script:WingetSourceCustom
                if ($userSupport -eq 'Unavailable') {
                    $machineSupport = Get-WauInstallerSupport -App $app -Scope machine -Source $Script:WingetSourceCustom
                    if ($machineSupport -eq 'Supported') {
                        # If already installed in machine scope at available version, skip prompting
                        if (Confirm-Installation $app.Id $app.AvailableVersion $Script:WingetSourceCustom -Scope 'machine') {
                            Write-ToLog "$($app.Name): Machine-scoped installation already present at version $($app.AvailableVersion)." "Yellow"
                            continue
                        }

                        Add-Type -AssemblyName PresentationFramework -ErrorAction SilentlyContinue
                        $cleanAppName = Get-WauCleanAppName $app.Name $app.Version
                        $message = "$cleanAppName $($app.AvailableVersion) no longer provides a user-scoped installer in WinGet, but includes a machine-scoped installer.`n`nWould you like to install the new version with administrator privileges for all users?`n`nThe existing user installation and its user data will not be automatically removed. Depending on the software, both installations may coexist.`n`nYes: Allow machine installation.`nNo: Skip this update and keep current user installation."
                        $answer = [System.Windows.MessageBox]::Show($message, 'Confirm User to Machine Scope Migration',
                            [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Question,
                            [System.Windows.MessageBoxResult]::No)
                        if ($answer -eq [System.Windows.MessageBoxResult]::Yes) {
                            Write-ToLog "$($app.Name): User approved migration to machine scope. Queuing for SYSTEM execution." "Cyan"
                            $regPath = "HKCU:\SOFTWARE\Romanitho\Winget-AutoUpdate\ApprovedScopeMigrations\$($app.Id)"
                            if (-not (Test-Path -LiteralPath $regPath)) {
                                New-Item -Path $regPath -Force | Out-Null
                            }
                            Set-ItemProperty -LiteralPath $regPath -Name "PackageId" -Value $app.Id -Force
                            Set-ItemProperty -LiteralPath $regPath -Name "Name" -Value $cleanAppName -Force
                            Set-ItemProperty -LiteralPath $regPath -Name "CurrentVersion" -Value $app.Version -Force
                            Set-ItemProperty -LiteralPath $regPath -Name "ApprovedVersion" -Value $app.AvailableVersion -Force
                            Set-ItemProperty -LiteralPath $regPath -Name "Source" -Value $Script:WingetSourceCustom -Force
                            Set-ItemProperty -LiteralPath $regPath -Name "Timestamp" -Value (Get-Date -Format "o") -Force
                            $script:HasPendingScopeMigration = $true
                            continue
                        }
                        else {
                            Write-ToLog "$($app.Name): Migration to machine scope declined by user." "Yellow"
                            continue
                        }
                    }
                    else {
                        Write-ToLog "$($app.Name): No applicable installer found in user or machine scope." "Yellow"
                        continue
                    }
                }
            }

            Update-App $app -src $Script:WingetSourceCustom
        }

        if ($script:HasPendingScopeMigration -and -not $Script:IsSystem) {
            Write-ToLog "Triggering SYSTEM task to execute approved scope migrations..." "Cyan"
            $regWAU = "HKCU:\SOFTWARE\Romanitho\Winget-AutoUpdate"
            Set-ItemProperty -LiteralPath $regWAU -Name "ScopeMigrationTriggered" -Value 1 -Force
            $systemTask = Get-ScheduledTask -TaskName 'Winget-AutoUpdate' -TaskPath '\WAU\' -ErrorAction SilentlyContinue
            if (-not $systemTask) {
                $systemTask = Get-ScheduledTask -TaskName 'Winget-AutoUpdate' -ErrorAction SilentlyContinue
            }
            if ($systemTask) {
                $systemTask | Start-ScheduledTask -ErrorAction SilentlyContinue
            }
        }

        if ($InstallOK -eq 0 -or !$InstallOK) {
            Write-ToLog "No new update." "Green"
        }

        # Test if _WAU-mods-postsys.ps1 exists: Mods for WAU (postsys) - if Network is active/any Winget is installed/running as SYSTEM _after_ SYSTEM updates
        if ($true -eq $IsSystem) {
            if (Test-Path "$Mods\_WAU-mods-postsys.ps1") {
                Write-ToLog "Running Mods (postsys) for WAU..." "DarkYellow"
                & "$Mods\_WAU-mods-postsys.ps1"
            }
        }

        #Check if user context is activated during system run
        if ($IsSystem -and ($WAUConfig.WAU_UserContext -eq 1) -and -not $userContextTriggered -and -not $migrationTriggeredOnly) {

            $UserContextTask = Get-ScheduledTask -TaskName 'Winget-AutoUpdate-UserContext' -ErrorAction SilentlyContinue

            $explorerprocesses = @(Get-CimInstance -Query "SELECT * FROM Win32_Process WHERE Name='explorer.exe'" -ErrorAction SilentlyContinue)
            If ($explorerprocesses.Count -eq 0) {
                Write-ToLog "No explorer process found / Nobody interactively logged on..."
            }
            Else {
                #Get Winget system apps to escape them before running user context
                Write-ToLog "User logged on, get a list of installed Winget apps in System context..."
                # Explicit --scope user makes the old machine-ID exclusion file unnecessary.

                #Run user context scheduled task
                Write-ToLog "Starting WAU in User context..."
                $null = $UserContextTask | Start-ScheduledTask -ErrorAction SilentlyContinue
                Exit 0
            }
        }
    }
    else {
        Write-ToLog "Critical: Winget not installed or detected, exiting..." "red"
        New-Item "$WorkingDir\logs\error.txt" -Value "Winget not installed or detected" -Force
        Write-ToLog "End of process!" "Cyan"
        Exit 1
    }
}
#endregion MAIN

#End
Write-ToLog "End of process!" "Cyan"
Start-Sleep 3


