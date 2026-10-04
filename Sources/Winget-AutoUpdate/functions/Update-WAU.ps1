<#
.SYNOPSIS
    Downloads the latest WAU release and performs self-update.

.DESCRIPTION
    Downloads the WAU MSI package from GitHub and installs it to update
    WAU to the latest version. Sends notifications before and after
    the update process.

.EXAMPLE
    Update-WAU

.NOTES
    Exits the script after update to allow the new version to run.
    Uses MSI installer with silent installation parameters.
#>
function Update-WAU {

    # Setup notification action and button
    $OnClickAction = "https://github.com/Romanitho/$($GitHub_Repo)/releases"
    $Button1Text = $NotifLocale.local.outputs.output[10].message

    # Send "update available" notification
    $Title = $NotifLocale.local.outputs.output[2].title -f "Winget-AutoUpdate"
    $Message = $NotifLocale.local.outputs.output[2].message -f $WAUCurrentVersion, $WAUAvailableVersion
    $MessageType = "info"
    Start-NotifTask -Title $Title -Message $Message -MessageType $MessageType -Button1Action $OnClickAction -Button1Text $Button1Text

    # Download and install update
    try {
        Write-ToLog "Downloading the GitHub Repository version $WAUAvailableVersion" "Cyan"

        # Use a unique directory for this download.
        $MsiFolder = Join-Path $env:TEMP ('WAU_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $MsiFolder -ErrorAction Stop | Out-Null

        # Download the MSI package
        $MsiFile = Join-Path $MsiFolder "WAU.msi"
        if ([string]$WAUAvailableVersion -notmatch '^\d+(?:\.\d+){1,3}(?:-[A-Za-z0-9.-]+)?$') {
            throw 'Invalid WAU release version.'
        }
        $release = Invoke-RestMethod -Uri "https://api.github.com/repos/Romanitho/Winget-AutoUpdate/releases/tags/v$WAUAvailableVersion" `
            -Headers @{ 'User-Agent' = 'Winget-AutoUpdate'; Accept = 'application/vnd.github+json' } -ErrorAction Stop
        $assets = @($release.assets | Where-Object { $_.name -eq 'WAU.msi' })
        if ($release.tag_name -ne "v$WAUAvailableVersion" -or $assets.Count -ne 1 -or
            [string]$assets[0].digest -notmatch '^sha256:([a-fA-F0-9]{64})$') {
            throw 'Release does not provide an unambiguous SHA-256 digest; self-update refused.'
        }
        $expectedHash = $matches[1]
        $downloadUri = "https://github.com/Romanitho/Winget-AutoUpdate/releases/download/v$WAUAvailableVersion/WAU.msi"
        $null = Save-WauHttpsFile -Uri $downloadUri -Destination $MsiFile
        if ((Get-FileHash -LiteralPath $MsiFile -Algorithm SHA256 -ErrorAction Stop).Hash -ne $expectedHash) {
            throw 'WAU MSI SHA-256 verification failed.'
        }

        # Install the update
        Write-ToLog "Updating WAU..." "Yellow"
        $installer = Start-Process -FilePath "$env:WINDIR\System32\msiexec.exe" `
            -ArgumentList "/i ""$MsiFile"" /qn /L*v ""$WorkingDir\logs\WAU-Installer.log"" RUN_WAU=YES INSTALLDIR=""$WorkingDir""" `
            -Wait -PassThru -ErrorAction Stop
        if ($installer.ExitCode -notin @(0, 3010)) { throw "WAU MSI installation failed ($($installer.ExitCode))." }
        if ($installer.ExitCode -eq 3010) { Write-ToLog 'WAU installation succeeded; a restart is required.' 'Yellow' }

        # Send success notification
        Write-ToLog "WAU Update completed. Rerunning WAU..." "Green"
        $Title = $NotifLocale.local.outputs.output[3].title -f "Winget-AutoUpdate"
        $Message = $NotifLocale.local.outputs.output[3].message -f $WAUAvailableVersion
        $MessageType = "success"
        Start-NotifTask -Title $Title -Message $Message -MessageType $MessageType -Button1Action $OnClickAction -Button1Text $Button1Text

        # Cleanup temporary files
        Remove-Item -LiteralPath $MsiFolder -Recurse -Force -ErrorAction SilentlyContinue

        exit 0
    }

    catch {
        # Send error notification
        $Title = $NotifLocale.local.outputs.output[4].title -f "Winget-AutoUpdate"
        $Message = $NotifLocale.local.outputs.output[4].message
        $MessageType = "error"
        Start-NotifTask -Title $Title -Message $Message -MessageType $MessageType -Button1Action $OnClickAction -Button1Text $Button1Text
        Write-ToLog "WAU Update failed: $($_.Exception.Message)" "Red"
    }

}
