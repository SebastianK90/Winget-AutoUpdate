<#
.SYNOPSIS
    Gets WAU configuration including GPO overrides.

.DESCRIPTION
    Reads settings from registry, applying GPO policies if present.

.OUTPUTS
    PSCustomObject with WAU configuration properties.
#>
Function Get-WAUConfig {

    # Get base config (newest version from registry)
    $WAUConfig = Get-ItemProperty "HKLM:\SOFTWARE\Romanitho\Winget-AutoUpdate*", "HKLM:\SOFTWARE\WOW6432Node\Romanitho\Winget-AutoUpdate*" -ErrorAction SilentlyContinue |
        Sort-Object { $_.ProductVersion } -Descending |
        Select-Object -First 1

    # Secrets are readable only by SYSTEM/elevated administrators. Normal user
    # tasks continue to receive the non-sensitive configuration.
    $secretNames = @('WAU_GitHubToken', 'WAU_AzureBlobSASURL')
    foreach ($name in $secretNames) {
        if ($WAUConfig) { $WAUConfig | Add-Member NoteProperty $name '' -Force }
    }
    if ($WAUConfig.PSPath) {
        $secretPath = Join-Path $WAUConfig.PSPath 'Secrets'
        $secrets = Get-ItemProperty -LiteralPath $secretPath -ErrorAction SilentlyContinue
        foreach ($name in $secretNames) {
            if ($secrets.$name) { $WAUConfig.$name = $secrets.$name }
        }
    }

    # Apply GPO overrides if present
    $GPO = Get-ItemProperty "HKLM:\SOFTWARE\Policies\Romanitho\Winget-AutoUpdate" -ErrorAction SilentlyContinue
    if ($GPO) {
        Write-ToLog "GPO policies detected - applying" "Yellow"
        $GPO.PSObject.Properties | Where-Object { $_.Name -notin $secretNames } | ForEach-Object {
            if ($WAUConfig.PSObject.Properties.Match($_.Name).Count) {
                $WAUConfig.$($_.Name) = $_.Value
            }
            else {
                $WAUConfig.PSObject.Properties.Add($_)
            }
        }
    }

    $secretGpo = Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Romanitho\Winget-AutoUpdate\Secrets' -ErrorAction SilentlyContinue
    foreach ($name in $secretNames) {
        if ($secretGpo -and $WAUConfig -and $secretGpo.PSObject.Properties[$name]) {
            $WAUConfig | Add-Member NoteProperty $name $secretGpo.$name -Force
        }
    }

    return $WAUConfig
}
