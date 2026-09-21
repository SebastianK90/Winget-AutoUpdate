# Scope is installation identity, not a guess based on a directory or package ID.
function Get-WauAppKey ($App) {
    $identity = '{0}|{1}|{2}|{3}' -f $App.Source, $App.Id, $App.Scope, $App.UserSid
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($identity.ToLowerInvariant())))).Replace('-', '') }
    finally { $sha.Dispose() }
}

function Get-WauDeadlineRegistryPath {
    param($App, [string]$DeadlineRegPath = 'HKLM:\SOFTWARE\Romanitho\Winget-AutoUpdate\UpdateDeadlines')
    $packageId = if ($App.Id) { [string]$App.Id } else { [string]$App.PackageId }
    if (-not $packageId -or $packageId -notmatch '^[A-Za-z0-9][A-Za-z0-9._+\-]{0,255}$') {
        throw 'Invalid WinGet package ID for deadline registry path.'
    }
    if ($App.Scope -notin @('user','machine')) { throw 'Invalid deadline scope.' }
    $path = Join-Path $DeadlineRegPath $packageId
    if ($App.Scope -eq 'machine') { return Join-Path $path 'machine' }
    $sid = [string]$App.UserSid
    if ($sid -notmatch '^S-1-(?:5-21|12-1)-\d+-\d+-\d+-\d+$') { throw 'Invalid deadline user SID.' }
    return Join-Path (Join-Path $path 'user') $sid
}

function Remove-WauUpdateDeadline {
    param($App, [string]$DeadlineRegPath = 'HKLM:\SOFTWARE\Romanitho\Winget-AutoUpdate\UpdateDeadlines')
    $leaf = Get-WauDeadlineRegistryPath -App $App -DeadlineRegPath $DeadlineRegPath
    Remove-Item -LiteralPath $leaf -Recurse -Force -ErrorAction SilentlyContinue
    # Remove empty SID/scope, source and package containers, but never the root.
    $parent = Split-Path $leaf -Parent
    while ($parent -and $parent -ne $DeadlineRegPath -and $parent.StartsWith($DeadlineRegPath + '\', [StringComparison]::OrdinalIgnoreCase)) {
        $children = @(Get-ChildItem -LiteralPath $parent -ErrorAction SilentlyContinue)
        $container = Get-ItemProperty -LiteralPath $parent -ErrorAction SilentlyContinue
        $dataProperties = @($container.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS(Path|ParentPath|ChildName|Drive|Provider)$' })
        if ($children.Count -or $dataProperties.Count) { break }
        Remove-Item -LiteralPath $parent -Force -ErrorAction SilentlyContinue
        $parent = Split-Path $parent -Parent
    }
}


function Set-WauDeadlineLeafValues {
    param([string]$Path, $App, [datetime]$FirstDetected, [datetime]$Deadline, [string]$AvailableVersion)
    New-Item -Path $Path -Force | Out-Null
    Set-ItemProperty -LiteralPath $Path -Name FirstDetected -Value $FirstDetected.ToString('yyyy-MM-dd HH:mm:ss')
    Set-ItemProperty -LiteralPath $Path -Name Deadline -Value $Deadline.ToString('yyyy-MM-dd HH:mm:ss')
    Set-ItemProperty -LiteralPath $Path -Name AvailableVersion -Value $AvailableVersion
    Set-ItemProperty -LiteralPath $Path -Name PackageId -Value ([string]$App.Id)
    Set-ItemProperty -LiteralPath $Path -Name Source -Value $(if ($App.Source) { [string]$App.Source } else { 'winget' })
    Set-ItemProperty -LiteralPath $Path -Name Scope -Value ([string]$App.Scope)
    Set-ItemProperty -LiteralPath $Path -Name UserSid -Value ([string]$App.UserSid)
    Set-ItemProperty -LiteralPath $Path -Name IdentityKey -Value (Get-WauAppKey $App)
}

function Get-WauCleanAppName ($Name, $Version) {
    $clean = [string]$Name
    if ($Version) {
        $escapedVer = [regex]::Escape($Version)
        $clean = $clean -replace "(?i)\s*(version\s*|v\.?\s*)?$escapedVer\b", ""
        $verParts = $Version.Split('.')
        if ($verParts.Count -ge 3) {
            $threePart = [regex]::Escape("$($verParts[0]).$($verParts[1]).$($verParts[2])")
            $clean = $clean -replace "(?i)\s*(version\s*|v\.?\s*)?$threePart\b", ""
        }
        if ($verParts.Count -ge 2) {
            $twoPart = [regex]::Escape("$($verParts[0]).$($verParts[1])")
            $clean = $clean -replace "(?i)\s*(version\s*|v\.?\s*)?$twoPart\b", ""
        }
    }
    return $clean.Trim()
}

function Test-WauSameVersion ([string]$Installed, [string]$Expected) {
    if ([string]::IsNullOrWhiteSpace($Installed) -or [string]::IsNullOrWhiteSpace($Expected)) { return $false }
    $inst = $Installed.Trim().TrimStart('v', 'V')
    $exp  = $Expected.Trim().TrimStart('v', 'V')
    if ($inst -eq $exp) { return $true }

    # Normalize dot-separated numeric versions: strip trailing zero segments and compare integer parts
    if ($inst -match '^\d+(\.\d+)+$' -and $exp -match '^\d+(\.\d+)+$') {
        try {
            $instParts = [System.Collections.Generic.List[long]]::new([long[]]($inst.Split('.') | ForEach-Object { [long]$_ }))
            $expParts  = [System.Collections.Generic.List[long]]::new([long[]]($exp.Split('.') | ForEach-Object { [long]$_ }))
            while ($instParts.Count -gt 0 -and $instParts[$instParts.Count - 1] -eq 0) {
                $instParts.RemoveAt($instParts.Count - 1)
            }
            while ($expParts.Count -gt 0 -and $expParts[$expParts.Count - 1] -eq 0) {
                $expParts.RemoveAt($expParts.Count - 1)
            }
            if ($instParts.Count -ne $expParts.Count) { return $false }
            for ($i = 0; $i -lt $instParts.Count; $i++) {
                if ($instParts[$i] -ne $expParts[$i]) { return $false }
            }
            return $true
        } catch {}
    }

    # WinGet manifests and ARP often differ only by trailing zero components (e.g. 26.03.00.0 vs 26.03).
    $instClean = $inst -replace '(\.0+)+$', ''
    $expClean  = $exp -replace '(\.0+)+$', ''
    return ($instClean -eq $expClean)
}

function Invoke-WauWinget {
    param([string[]]$Arguments)
    $output = @(& $Script:Winget @Arguments 2>&1 | ForEach-Object { "$_" })
    [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($output -join "`n") }
}

function Invoke-WauWingetTimed {
    param([string[]]$Arguments, [int]$TimeoutSeconds = 30)
    if ($Script:Winget -isnot [string] -or [string]::IsNullOrWhiteSpace($Script:Winget)) {
        return Invoke-WauWinget -Arguments $Arguments
    }
    $quoted = foreach ($argument in $Arguments) {
        if ($argument -notmatch '[\s"]') { $argument; continue }
        # Windows CommandLineToArgvW escaping: double backslashes before quotes
        # and at the end of a quoted argument.
        '"' + ([regex]::Replace($argument, '(\\*)"', '$1$1\"') -replace '(\\+)$', '$1$1') + '"'
    }
    $stdoutPath = Join-Path $env:TEMP ('wau-winget-' + [guid]::NewGuid().ToString('N') + '.out')
    $stderrPath = Join-Path $env:TEMP ('wau-winget-' + [guid]::NewGuid().ToString('N') + '.err')
    $process = $null
    try {
        $process = Start-Process -FilePath $Script:Winget -ArgumentList ($quoted -join ' ') -PassThru -WindowStyle Hidden `
            -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -ErrorAction Stop
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
            return [pscustomobject]@{ExitCode=1460;Output='WinGet metadata query timed out.'}
        }
        $output = @(
            Get-Content -LiteralPath $stdoutPath -Raw -ErrorAction SilentlyContinue
            Get-Content -LiteralPath $stderrPath -Raw -ErrorAction SilentlyContinue
        ) -join "`n"
        return [pscustomobject]@{ExitCode=$process.ExitCode;Output=$output}
    }
    finally {
        if ($process) { $process.Dispose() }
        Remove-Item -LiteralPath $stdoutPath,$stderrPath -Force -ErrorAction SilentlyContinue
    }
}

function Test-WauWingetDetails {
    if ($null -eq $Script:WauHasListDetails) {
        $help = Invoke-WauWinget -Arguments @('list', '--help')
        $Script:WauHasListDetails = $help.ExitCode -eq 0 -and $help.Output.Contains('--details')
    }
    return $Script:WauHasListDetails
}

# New WinGet releases expose untruncated identities with list --details. The
# position of the installed version and the source [version] line are independent
# of UI language. Prefer this over terminal-column parsing whenever available.
function ConvertFrom-WauWingetDetails {
    param([string]$Text, [string]$Source, [switch]$Upgrade)
    $clean = $Text -replace '\x1b\[[0-9;?]*[A-Za-z]', ''
    $blocks = [regex]::Matches($clean, '(?ms)^(?:\(\d+/\d+\) )?(?<name>[^\s\r\n][^\r\n]*) \[(?<id>[^\]\r\n]+)\]\r?\n[^:\r\n]+:[ \t]*(?<version>[^\r\n]+)\r?\n(?<body>.*?)(?=^(?:\(\d+/\d+\) )?[^\s\r\n][^\r\n]* \[[^\]\r\n]+\]\r?\n|\z)')
    foreach ($block in $blocks) {
        $id = $block.Groups['id'].Value
        if ($id -notmatch '^[A-Za-z0-9][A-Za-z0-9._+\-]*$') { continue }
        $available = [regex]::Match($block.Groups['body'].Value, ('(?m)^\s+' + [regex]::Escape($Source) + ' \[(?<version>[^\]\r\n]+)\]'))
        if ($Upgrade -and -not $available.Success) { continue }
        [pscustomobject]@{Name=$block.Groups['name'].Value;Id=$id;Version=$block.Groups['version'].Value.Trim()
            AvailableVersion=$available.Groups['version'].Value.Trim()}
    }
    if ($clean -match '(?m)^\S[^\r\n]* \[[^\]\r\n]+\]$' -and -not $blocks.Count) { throw 'Unrecognised WinGet detailed inventory format.' }
}

# WinGet renders tables in terminal cells, not UTF-16 offsets. Pad wide characters
# before slicing, and reject truncated identities instead of executing a wrong ID.
function ConvertFrom-WauWingetTable {
    param([string]$Text, [switch]$Upgrade)
    $lines = ($Text -replace '\x1b\[[0-9;?]*[A-Za-z]', '') -split '\r?\n'
    $starts = $null
    for ($i = 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\s*-{5,}\s*$') {
            $starts = @([regex]::Matches($lines[$i-1], '\S+(?: \S+)*?(?=\s{2,}|$)') | ForEach-Object { $_.Index })
            continue
        }
        if (-not $starts -or $starts.Count -lt 3) { continue }
        $line = $lines[$i] -replace '([\u1100-\u115f\u2e80-\ua4cf\uac00-\ud7a3\uf900-\ufaff\ufe10-\ufe6f\uff01-\uff60])', ('$1' + [char]0x200B)
        if ($line.Length -le $starts[2]) { continue }
        $cells = @()
        for ($c = 0; $c -lt $starts.Count; $c++) {
            $end = if ($c + 1 -lt $starts.Count) { [math]::Min($starts[$c+1], $line.Length) } else { $line.Length }
            if ($end -le $starts[$c]) { $cells += ''; continue }
            $cells += $line.Substring($starts[$c], $end-$starts[$c]).Replace([string][char]0x200B, '').Trim()
        }
        if ($cells[1] -notmatch '^[A-Za-z0-9][A-Za-z0-9._+\-]*$' -or -not $cells[2]) { continue }
        if ($Upgrade -and ($cells.Count -lt 4 -or -not $cells[3])) { continue }
        [pscustomobject]@{
            Name = $cells[0]; Id = $cells[1]; Version = $cells[2]
            AvailableVersion = if ($Upgrade) { $cells[3] } else { '' }
        }
    }
}

function Get-WauInstallerSupport {
    param($App, [ValidateSet('user','machine')][string]$Scope, [string]$Source)
    $result = Invoke-WauWinget -Arguments @('show', '--id', $App.Id, '--exact', '--version', $App.AvailableVersion,
        '--source', $Source, '--scope', $Scope, '--accept-source-agreements', '--disable-interactivity')
    if ($result.ExitCode -ne 0) { return 'Unknown' }
    # A selected non-Store installer has a required SHA256. show can return 0 even
    # when no applicable installer exists; its exit code alone is not sufficient.
    if ($result.Output -match '(?im)^\s+[^\r\n:]*SHA256\s*:\s*[0-9a-f]{64}\s*$') { return 'Supported' }
    # show ends with an installer section. With no applicable installer it contains
    # one indented warning instead of key:value fields (ShowFlow.cpp). Recognise
    # the structure rather than an English/German translation. Store product IDs
    # contain a colon and deliberately remain Unknown here, never machine-only.
    $lines = @($result.Output -split '\r?\n')
    $lastHeader = -1
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        if ($lines[$i] -match '^\S[^:]*:\s*$') { $lastHeader = $i; break }
    }
    if ($lastHeader -ge 0) {
        $detail = @($lines[($lastHeader + 1)..($lines.Count - 1)] | Where-Object { $_.Trim() })
        if ($detail.Count -eq 1 -and $detail[0] -notmatch ':' -and $result.Output.Contains("[$($App.Id)]")) { return 'Unavailable' }
    }
    return 'Unknown'
}

function Set-WauScopePlan {
    param($App, [string]$Source)
    # Inventory must stay fast: installer applicability is checked only for
    # selected user updates, immediately before consent/dispatch.
    $support = if ($App.Scope -eq 'user' -and $App.UserInstallerSupport) { $App.UserInstallerSupport }
               elseif ($App.Scope -eq 'machine' -and $App.MachineInstallerSupport) { $App.MachineInstallerSupport }
               else { 'Unknown' }
    $target = $App.Scope
    $migration = $false
    if ($App.Scope -eq 'user' -and $support -eq 'Unavailable' -and $App.MachineInstallerSupport -eq 'Supported') {
        $target = 'machine'; $migration = $true
    }
    $App | Add-Member NoteProperty TargetScope $target -Force
    $App | Add-Member NoteProperty RequiresScopeMigration $migration -Force
    $App | Add-Member NoteProperty ScopeMigrationApproved $false -Force
    $App | Add-Member NoteProperty InstallerSupport $support -Force
    return $App
}

function Select-WauApprovedUpdates {
    param([array]$Apps, [scriptblock]$ConfirmMigration)
    foreach ($item in $Apps) {
        if ($item.CanUpdate -ne $true) { continue }
        $app = $item | ConvertTo-Json -Depth 6 | ConvertFrom-Json
        $app | Add-Member NoteProperty ScopeMigrationApproved $false -Force
        if ($app.RequiresScopeMigration) {
            $answer = & $ConfirmMigration $app
            if ($answer -isnot [bool] -or -not $answer) { continue }
            $app.ScopeMigrationApproved = $true
        }
        $app
    }
}

function Get-WauInteractiveUser {
    $session = [Diagnostics.Process]::GetCurrentProcess().SessionId
    if ($session -eq 0) {
        $explorers = @(Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" | Where-Object { $_.SessionId -gt 0 })
    }
    else {
        $explorers = @(Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" | Where-Object { $_.SessionId -eq $session })
    }
    if (-not $explorers) { return $null }
    $owner = Invoke-CimMethod -InputObject $explorers[0] -MethodName GetOwnerSid
    if ($owner.ReturnValue -eq 0) { return $owner.Sid }
    return $null
}

function Write-WauAtomicJson {
    param([string]$Path, $Value)
    $temporary = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        ConvertTo-Json -InputObject $Value -Depth 8 | Set-Content -LiteralPath $temporary -Encoding UTF8 -ErrorAction Stop
        Move-Item -LiteralPath $temporary -Destination $Path -Force -ErrorAction Stop
    }
    finally { Remove-Item -LiteralPath $temporary -ErrorAction SilentlyContinue }
}

# SYSTEM owns requests; the target user can write only that request's response.
# Never execute scripts, installer arguments or a machine update from a response.
function Invoke-WauUserOperation {
    param([ValidateSet('Scan','Plan','Update')][string]$Operation, [string]$UserSid,
          [array]$Apps = @(), [int]$TimeoutSeconds = 600)
    if (-not [Security.Principal.WindowsIdentity]::GetCurrent().IsSystem) { throw 'User delegation requires SYSTEM.' }
    if ($UserSid -notmatch '^S-1-5-21-\d+-\d+-\d+-\d+$' -and $UserSid -notmatch '^S-1-12-1-\d+-\d+-\d+-\d+$') { throw 'Invalid target user SID.' }
    $requestId = [guid]::NewGuid().ToString('N')
    $root = Join-Path $Script:WorkingDir 'config\scope-requests'
    $directory = Join-Path $root $requestId
    New-Item -ItemType Directory -Path $directory -Force -ErrorAction Stop | Out-Null
    try {
        $acl = New-Object Security.AccessControl.DirectorySecurity
        $acl.SetAccessRuleProtection($true, $false)
        foreach ($sid in @('S-1-5-18','S-1-5-32-544', $UserSid)) {
            $rights = if ($sid -eq $UserSid) { 'ReadAndExecute' } else { 'FullControl' }
            $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid), $rights, 'ContainerInherit,ObjectInherit', 'None', 'Allow'))
        }
        Set-Acl -LiteralPath $directory -AclObject $acl -ErrorAction Stop
        $responseDir = New-Item -ItemType Directory -Path (Join-Path $directory 'response') -ErrorAction Stop
        $responseAcl = Get-Acl -LiteralPath $responseDir.FullName
        $responseAcl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($UserSid), 'Modify', 'ContainerInherit,ObjectInherit', 'None', 'Allow'))
        Set-Acl -LiteralPath $responseDir.FullName -AclObject $responseAcl -ErrorAction Stop
        Write-WauAtomicJson (Join-Path $directory 'request.json') ([pscustomobject]@{
            RequestId=$requestId; UserSid=$UserSid; Operation=$Operation; Source=$Script:WingetSourceCustom; Apps=@($Apps)
        })
        # Reuse WAU's fixed interactive task. Per-run tasks left orphaned entries
        # behind when a worker or WinGet call stalled.
        $userTask = Get-ScheduledTask -TaskName 'Winget-AutoUpdate-UserContext' -TaskPath '\WAU\' -ErrorAction Stop
        $readyWatch = [Diagnostics.Stopwatch]::StartNew()
        while ($userTask.State -eq 'Running' -and $readyWatch.Elapsed.TotalSeconds -lt 15) {
            Start-Sleep -Milliseconds 500
            $userTask = Get-ScheduledTask -TaskName 'Winget-AutoUpdate-UserContext' -TaskPath '\WAU\' -ErrorAction Stop
        }
        if ($userTask.State -eq 'Running') { throw 'The fixed WAU user task is still busy.' }
        Start-ScheduledTask -InputObject $userTask -ErrorAction Stop
        $responsePath = Join-Path $responseDir.FullName 'result.json'
        $watch = [Diagnostics.Stopwatch]::StartNew()
        while ($watch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
            if (Test-Path -LiteralPath $responsePath) {
                if ((Get-Item -LiteralPath $responsePath).Length -gt 4MB) { throw 'Oversized user response.' }
                $response = Get-Content -LiteralPath $responsePath -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json
                if ($response.RequestId -ne $requestId -or $response.UserSid -ne $UserSid -or $response.Success -ne $true) { throw "User operation failed: $($response.Error)" }
                return @($response.Apps)
            }
            Start-Sleep -Seconds 1
        }
        throw "User $Operation timed out; no stale inventory will be used."
    }
    finally {
        if ($directory -and $directory.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) {
            Remove-Item -LiteralPath $directory -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Invoke-WauPendingUserOperation {
    if ([Security.Principal.WindowsIdentity]::GetCurrent().IsSystem) { return $false }
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $root = Join-Path $Script:WorkingDir 'config\scope-requests'
    foreach ($directory in @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue | Sort-Object CreationTime)) {
        $requestPath = Join-Path $directory.FullName 'request.json'
        $responsePath = Join-Path $directory.FullName 'response\result.json'
        if (-not (Test-Path -LiteralPath $requestPath) -or (Test-Path -LiteralPath $responsePath)) { continue }
        $response = [pscustomobject]@{RequestId=$directory.Name;UserSid=$sid;Success=$false;Apps=@();Error=''}
        try {
            $request = Get-Content -LiteralPath $requestPath -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json
            if ($request.UserSid -ne $sid -or $request.RequestId -ne $directory.Name) { continue }
            $response.RequestId = $request.RequestId
            if ($request.Operation -eq 'Scan') {
                $response.Apps = @(Get-WingetOutdatedApps -src $request.Source -Scope user)
                foreach ($app in $response.Apps) {
                    $userSupport = Get-WauInstallerSupport -App $app -Scope user -Source $request.Source
                    $machineSupport = if ($userSupport -eq 'Unavailable') {
                        Get-WauInstallerSupport -App $app -Scope machine -Source $request.Source
                    } else { 'Unknown' }
                    $app | Add-Member NoteProperty UserInstallerSupport $userSupport -Force
                    $app | Add-Member NoteProperty MachineInstallerSupport $machineSupport -Force
                }
            }
            elseif ($request.Operation -eq 'Plan') {
                $fresh = @(Get-WingetOutdatedApps -src $request.Source -Scope user)
                $planned = @()
                foreach ($selected in @($request.Apps)) {
                    $app = $fresh | Where-Object { $_.Key -eq $selected.Key -and $_.AvailableVersion -eq $selected.AvailableVersion } | Select-Object -First 1
                    if (-not $app) { continue }
                    $userSupport = Get-WauInstallerSupport -App $app -Scope user -Source $request.Source
                    $machineSupport = if ($userSupport -eq 'Unavailable') {
                        Get-WauInstallerSupport -App $app -Scope machine -Source $request.Source
                    } else { 'Unknown' }
                    $planned += [pscustomobject]@{
                        Key=$app.Key; Id=$app.Id; AvailableVersion=$app.AvailableVersion
                        UserInstallerSupport=$userSupport
                        MachineInstallerSupport=$machineSupport
                    }
                }
                $response.Apps = $planned
            }
            elseif ($request.Operation -eq 'Update') {
                $Script:InstallOK = 0
                $fresh = @(Get-WingetOutdatedApps -src $request.Source -Scope user)
                $completed = @()
                foreach ($selected in @($request.Apps)) {
                    $app = $fresh | Where-Object { $_.Key -eq $selected.Key -and $_.AvailableVersion -eq $selected.AvailableVersion } | Select-Object -First 1
                    if (-not $app) { Write-ToLog "Selected user update changed or disappeared: $($selected.Id)" 'Yellow'; continue }
                    $before = $Script:InstallOK
                    Update-App $app -src $request.Source
                    if ($Script:InstallOK -gt $before) { $completed += [pscustomobject]@{Key=$app.Key;Id=$app.Id} }
                }
                $response.Apps = $completed
            }
            else { throw 'Unknown user operation.' }
            $response.Success = $true
        }
        catch {
            $response.Error = $_.Exception.Message
            Write-ToLog "User operation failed: $($response.Error)" 'Red'
        }
        Write-WauAtomicJson -Path $responsePath -Value $response
        return $true
    }
    return $false
}

