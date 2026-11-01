#Requires -Version 5.1
<#
.SYNOPSIS
    Watches Elite Dangerous journals for fleet carrier jump events.

.DESCRIPTION
    Tails Elite Dangerous journal files and reports when a carrier jump is
    plotted, cancelled, or confirmed. Multiple journals (multiboxing) can be
    followed at the same time; each event is tagged with the commander and
    carrier it belongs to.

    Console output is built in. Additional actions can be registered in
    carrier-actions.ps1.

.PARAMETER JournalPath
    One or more journal directories. Defaults to the standard Saved Games
    location for Elite Dangerous.

.PARAMETER ActiveWindowMinutes
    How recently a journal must have been written to count as "active" during
    startup discovery. Defaults to 15 minutes.

.PARAMETER PollMilliseconds
    How often tracked journals are checked for new lines. Defaults to 500 ms.

.PARAMETER FollowAll
    Follow every journal found during startup discovery without prompting.

.PARAMETER Follow
    Follow specific journal file names (for example
    "Journal.2026-10-31T142543.01.log"), skipping discovery.

.PARAMETER ActionScript
    Path to a PowerShell file that registers actions. Defaults to
    carrier-actions.ps1 next to this script.

.PARAMETER ShowPaths
    Show full journal and script paths, and full exception messages. By
    default, paths are shortened and profile names are replaced with
    %USERPROFILE% or <user>.

.EXAMPLE
    .\carrier-watch.ps1

.EXAMPLE
    .\carrier-watch.ps1 -JournalPath "D:\Games\ED-Journals" -FollowAll

.EXAMPLE
    .\carrier-watch.ps1 -Follow "Journal.2026-10-31T142543.01.log"

.EXAMPLE
    .\carrier-watch.ps1 -ShowPaths
#>
[CmdletBinding()]
param(
    [string[]]$JournalPath,
    [ValidateRange(1, 10080)]
    [int]$ActiveWindowMinutes = 15,
    [ValidateRange(100, 10000)]
    [int]$PollMilliseconds = 500,
    [switch]$FollowAll,
    [string[]]$Follow,
    [string]$ActionScript,
    [switch]$ShowPaths
)

$ErrorActionPreference = 'Continue'

try {
    $Host.UI.RawUI.WindowTitle = 'Elite Dangerous Carrier Jump Tracker'
}
catch {
    # Some hosts do not expose a window title.
}

# Keep redirected output (logs) valid UTF-8; the Windows console already
# renders Unicode correctly.
try {
    [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
}
catch {
    # Not fatal if the host refuses the change.
}

# powershell.exe -File passes array arguments as a single literal string, so
# accept comma-separated values for convenience.
if ($JournalPath) {
    $JournalPath = @(
        $JournalPath |
            ForEach-Object { $_ -split ',' } |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_.Length -gt 0 }
    )
}
if ($Follow) {
    $Follow = @(
        $Follow |
            ForEach-Object { $_ -split ',' } |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_.Length -gt 0 }
    )
}

$script:StartTime = Get-Date
$script:Tracked = @{}
$script:KnownFiles = @{}
$script:CarrierState = @{}
$script:JournalDirectories = @()
$script:CarrierActions = @{
    JumpPlotted   = @()
    JumpCancelled = @()
    JumpConfirmed = @()
}
$script:PromptQuit = $false

$JournalFilePattern = '^Journal\.\d{4}-\d{2}-\d{2}T\d{6}\.\d{2}\.log$'
$CarrierEventPattern = '"event"\s*:\s*"(Commander|LoadGame|CarrierJumpRequest|CarrierJumpCancelled|CarrierJump)"'

# ---------------------------------------------------------------------------
# Path privacy
# ---------------------------------------------------------------------------

$script:PathRoots = @(
    [pscustomobject]@{ Variable = '%TEMP%'; Path = $env:TEMP },
    [pscustomobject]@{ Variable = '%LOCALAPPDATA%'; Path = $env:LOCALAPPDATA },
    [pscustomobject]@{ Variable = '%APPDATA%'; Path = $env:APPDATA },
    [pscustomobject]@{ Variable = '%USERPROFILE%'; Path = $env:USERPROFILE },
    [pscustomobject]@{ Variable = '%ProgramData%'; Path = $env:ProgramData }
) |
    Where-Object { $_.Path } |
    Sort-Object { $_.Path.Length } -Descending

function Get-SafePath {
    param([string]$Path)

    if ($ShowPaths -or [string]::IsNullOrEmpty($Path)) {
        return $Path
    }

    foreach ($root in $script:PathRoots) {
        $rootPath = $root.Path.TrimEnd('\', '/')
        if ($Path.Equals($rootPath, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $root.Variable
        }
        if ($Path.StartsWith($rootPath + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
            return $root.Variable + $Path.Substring($rootPath.Length)
        }
    }

    $userPattern = '^(?<prefix>[A-Za-z]:\\(?:Users|Documents and Settings)\\)[^\\]+(?<rest>.*)$'
    $match = [regex]::Match(
        $Path,
        $userPattern,
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )
    if ($match.Success) {
        return $match.Groups['prefix'].Value + '<user>' + $match.Groups['rest'].Value
    }

    $leaf = Split-Path -Path $Path -Leaf
    if ($leaf) {
        return '...\' + $leaf
    }
    return '...'
}

function Format-Exception {
    param($Exception)

    if ($null -eq $Exception) {
        return 'unknown error'
    }

    $inner = $Exception
    while ($inner.InnerException) {
        $inner = $inner.InnerException
    }

    if ($ShowPaths) {
        return $inner.Message
    }
    return $inner.GetType().Name
}

trap {
    $message = 'Unexpected error.'
    if ($_.Exception) {
        $message = 'Unexpected error: ' + (Format-Exception $_.Exception)
    }
    Write-Host $message -ForegroundColor Red
    exit 1
}

# ---------------------------------------------------------------------------
# Console output
# ---------------------------------------------------------------------------

function Write-TrackerLine {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [string]$Source,
        [ConsoleColor]$Color = [ConsoleColor]::Gray
    )

    $prefix = '[' + (Get-Date).ToString('HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture) + ']'
    if ($Source) {
        $prefix += ' [' + $Source + ']'
    }
    Write-Host ($prefix + ' ' + $Message) -ForegroundColor $Color
}

function Get-LocalTimeText {
    param($Instant)

    if ($null -eq $Instant) {
        return $null
    }

    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    $local = $Instant.ToLocalTime()
    if ($local.Date -eq (Get-Date).Date) {
        return $local.ToString('HH:mm', $culture) + ' local'
    }
    return $local.ToString('yyyy-MM-dd HH:mm', $culture) + ' local'
}

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------

function Get-EventProperty {
    param(
        $InputObject,
        [string]$Name,
        $Default = $null
    )

    if ($null -eq $InputObject) {
        return $Default
    }

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -ne $property -and $null -ne $property.Value) {
        return $property.Value
    }
    return $Default
}

function ConvertTo-EventTime {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }

    try {
        return [DateTimeOffset]::Parse(
            $Value,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::AssumeUniversal
        )
    }
    catch {
        return $null
    }
}

function New-ByteArray {
    param([int]$Length)

    if ($Length -le 0) {
        return [byte[]]@()
    }
    return New-Object byte[] $Length
}

function Get-FileKey {
    param([string]$Path)
    return $Path.ToLowerInvariant()
}

# ---------------------------------------------------------------------------
# Action registration (used by carrier-actions.ps1)
# ---------------------------------------------------------------------------

function Register-CarrierAction {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('JumpPlotted', 'JumpCancelled', 'JumpConfirmed')]
        [string]$Event,
        [Parameter(Mandatory = $true)]
        [scriptblock]$Action
    )

    $script:CarrierActions[$Event] = @($script:CarrierActions[$Event]) + $Action
}

function Invoke-CarrierActions {
    param(
        [Parameter(Mandatory = $true)][string]$Event,
        [Parameter(Mandatory = $true)]$Context
    )

    if (-not $script:CarrierActions.ContainsKey($Event)) {
        return
    }

    foreach ($action in @($script:CarrierActions[$Event])) {
        try {
            & $action $Context | Out-Null
        }
        catch {
            Write-Warning ("Action for {0} failed: {1}" -f $Event, (Format-Exception $_.Exception))
        }
    }
}

function New-CarrierContext {
    param(
        [string]$Event,
        [hashtable]$Track,
        $Raw,
        $CarrierId,
        $CarrierType,
        $SystemName,
        $Body,
        $DepartureTime,
        $Timestamp,
        $StationName
    )

    return [pscustomobject]@{
        Event         = $Event
        JournalEvent  = (Get-EventProperty $Raw 'event')
        Cmdr          = $Track.Cmdr
        FID           = $Track.FID
        CarrierID     = $CarrierId
        CarrierType   = $CarrierType
        SystemName    = $SystemName
        Body          = $Body
        DepartureTime = $DepartureTime
        Timestamp     = $Timestamp
        StationName   = $StationName
        JournalFile   = $Track.Path
        Raw           = $Raw
    }
}

# ---------------------------------------------------------------------------
# Journal discovery and reading
# ---------------------------------------------------------------------------

function Get-DefaultJournalDirectories {
    $candidates = New-Object System.Collections.Generic.List[string]

    $profileDirectory = [Environment]::GetFolderPath('UserProfile')
    if ($profileDirectory) {
        $candidates.Add((Join-Path $profileDirectory 'Saved Games\Frontier Developments\Elite Dangerous'))
    }

    # Saved Games can be relocated; the known-folder GUID points at the real one.
    try {
        $shellFolders = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders' -ErrorAction Stop
        $savedGames = $shellFolders.'{4C5C32FF-BB9D-43B0-B5B4-2D72E54EAAA4}'
        if ($savedGames) {
            $savedGames = [Environment]::ExpandEnvironmentVariables($savedGames)
            $candidate = Join-Path $savedGames 'Frontier Developments\Elite Dangerous'
            if (-not $candidates.Contains($candidate)) {
                $candidates.Add($candidate)
            }
        }
    }
    catch {
        # Registry lookup is best-effort only.
    }

    return $candidates.ToArray()
}

function Resolve-JournalDirectory {
    param([string]$Path)

    $expanded = [Environment]::ExpandEnvironmentVariables($Path)
    if (-not [System.IO.Path]::IsPathRooted($expanded)) {
        $expanded = Join-Path (Get-Location).Path $expanded
    }

    $full = [System.IO.Path]::GetFullPath($expanded)
    $root = [System.IO.Path]::GetPathRoot($full)
    if ($full.Length -gt $root.Length) {
        $full = $full.TrimEnd([char[]]@('\', '/'))
    }
    return $full
}

function Get-JournalFiles {
    $files = New-Object System.Collections.Generic.List[System.IO.FileInfo]

    foreach ($directory in $script:JournalDirectories) {
        $items = @(Get-ChildItem -LiteralPath $directory -Filter 'Journal.*.log' -File -ErrorAction SilentlyContinue)
        foreach ($item in $items) {
            if ($item.Name -match $JournalFilePattern) {
                [void]$files.Add($item)
            }
        }
    }

    return $files.ToArray()
}

function Read-FileRange {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [long]$Offset = 0,
        [int]$MaxBytes = 0
    )

    $reset = $false
    $stream = [System.IO.File]::Open(
        $Path,
        [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::Read,
        ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
    )

    try {
        if ($stream.Length -lt $Offset) {
            $Offset = 0
            $reset = $true
        }

        [void]$stream.Seek($Offset, [System.IO.SeekOrigin]::Begin)

        $memory = New-Object System.IO.MemoryStream
        try {
            $buffer = New-Object byte[] 65536
            $total = 0

            while ($true) {
                $requested = $buffer.Length
                if ($MaxBytes -gt 0) {
                    $remaining = $MaxBytes - $total
                    if ($remaining -le 0) {
                        break
                    }
                    if ($requested -gt $remaining) {
                        $requested = $remaining
                    }
                }

                $read = $stream.Read($buffer, 0, $requested)
                if ($read -le 0) {
                    break
                }

                $memory.Write($buffer, 0, $read)
                $total += $read
            }

            $bytes = $memory.ToArray()
        }
        finally {
            $memory.Dispose()
        }
    }
    finally {
        $stream.Dispose()
    }

    return [pscustomobject]@{
        Bytes  = $bytes
        Offset = $Offset + $bytes.Length
        Reset  = $reset
    }
}

function Split-JournalBytes {
    param(
        [byte[]]$Remainder,
        [byte[]]$NewBytes
    )

    if ($null -eq $Remainder) {
        $Remainder = [byte[]]@()
    }
    if ($null -eq $NewBytes) {
        $NewBytes = [byte[]]@()
    }

    $combined = New-ByteArray ($Remainder.Length + $NewBytes.Length)
    if ($Remainder.Length -gt 0) {
        [Array]::Copy($Remainder, 0, $combined, 0, $Remainder.Length)
    }
    if ($NewBytes.Length -gt 0) {
        [Array]::Copy($NewBytes, 0, $combined, $Remainder.Length, $NewBytes.Length)
    }

    $lastNewline = -1
    for ($index = $combined.Length - 1; $index -ge 0; $index--) {
        if ($combined[$index] -eq 10) {
            $lastNewline = $index
            break
        }
    }

    if ($lastNewline -lt 0) {
        return [pscustomobject]@{
            Lines     = @()
            Remainder = $combined
        }
    }

    if ($lastNewline -gt 0) {
        # Decode only complete lines so multi-byte UTF-8 characters cannot be
        # split across a read boundary.
        $text = [System.Text.Encoding]::UTF8.GetString($combined, 0, $lastNewline)
        $lines = @(
            $text -split "`n" |
                ForEach-Object { $_.TrimEnd("`r") } |
                Where-Object { $_.Length -gt 0 }
        )
    }
    else {
        $lines = @()
    }

    $remainderLength = $combined.Length - $lastNewline - 1
    $remainderBytes = New-ByteArray $remainderLength
    if ($remainderLength -gt 0) {
        [Array]::Copy($combined, $lastNewline + 1, $remainderBytes, 0, $remainderLength)
    }

    return [pscustomobject]@{
        Lines     = $lines
        Remainder = $remainderBytes
    }
}

function Read-NextJournalLines {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [long]$Offset = 0,
        [byte[]]$Remainder = $null
    )

    $range = Read-FileRange -Path $Path -Offset $Offset
    if ($range.Reset) {
        $Remainder = [byte[]]@()
    }

    $split = Split-JournalBytes -Remainder $Remainder -NewBytes $range.Bytes

    return [pscustomobject]@{
        Lines     = $split.Lines
        Offset    = $range.Offset
        Remainder = $split.Remainder
    }
}

function Get-JournalInfo {
    param([Parameter(Mandatory = $true)][System.IO.FileInfo]$File)

    $cmdr = $null
    $fid = $null
    $lastEvent = $null
    $lastTimestamp = $null

    try {
        $header = Read-FileRange -Path $File.FullName -Offset 0 -MaxBytes 131072
        if ($header.Bytes.Length -gt 0) {
            $headerText = [System.Text.Encoding]::UTF8.GetString($header.Bytes)
            foreach ($line in ($headerText -split "`n")) {
                $line = $line.TrimEnd("`r")
                if ($line -notmatch '"event"\s*:\s*"(Commander|LoadGame)"') {
                    continue
                }

                try {
                    $event = $line | ConvertFrom-Json -ErrorAction Stop
                }
                catch {
                    continue
                }

                if ($event.event -eq 'Commander') {
                    $cmdr = Get-EventProperty $event 'Name'
                    $fid = Get-EventProperty $event 'FID'
                    break
                }

                if ($event.event -eq 'LoadGame' -and $event.Commander) {
                    $cmdr = $event.Commander
                    $fid = Get-EventProperty $event 'FID'
                }
            }
        }
    }
    catch {
        # Identification is best-effort; a file may be mid-write.
    }

    try {
        if ($File.Length -gt 0) {
            $tailLength = 65536
            $tailOffset = [Math]::Max(0, $File.Length - $tailLength)
            $tail = Read-FileRange -Path $File.FullName -Offset $tailOffset -MaxBytes $tailLength

            if ($tail.Bytes.Length -gt 0) {
                $tailText = [System.Text.Encoding]::UTF8.GetString($tail.Bytes)
                $tailLines = @($tailText -split "`n")

                for ($index = $tailLines.Count - 1; $index -ge 0; $index--) {
                    $line = $tailLines[$index].TrimEnd("`r")
                    if (-not $line) {
                        continue
                    }

                    try {
                        $event = $line | ConvertFrom-Json -ErrorAction Stop
                    }
                    catch {
                        continue
                    }

                    if ($event.event) {
                        $lastEvent = $event.event
                        $lastTimestamp = Get-EventProperty $event 'timestamp'
                        break
                    }
                }
            }
        }
    }
    catch {
        # Tail inspection is best-effort.
    }

    return [pscustomobject]@{
        Cmdr          = $cmdr
        FID           = $fid
        LastEvent     = $lastEvent
        LastTimestamp = $lastTimestamp
    }
}

function New-JournalCandidate {
    param([Parameter(Mandatory = $true)][System.IO.FileInfo]$File)

    $info = Get-JournalInfo -File $File
    return [pscustomobject]@{
        File          = $File
        Name          = $File.Name
        FullName      = $File.FullName
        LastWriteTime = $File.LastWriteTime
        Cmdr          = $info.Cmdr
        FID           = $info.FID
        LastEvent     = $info.LastEvent
    }
}

# ---------------------------------------------------------------------------
# Event processing
# ---------------------------------------------------------------------------

function Get-EventTag {
    param(
        [hashtable]$Track,
        $CarrierId
    )

    $who = $Track.Cmdr
    if (-not $who) {
        $who = $Track.FileName
    }

    if ($CarrierId) {
        return ('{0} / {1}' -f $who, $CarrierId)
    }
    return [string]$who
}

function Process-JournalLine {
    param(
        [Parameter(Mandatory = $true)][string]$Line,
        [Parameter(Mandatory = $true)][hashtable]$Track,
        [switch]$Notify
    )

    if ($Line -notmatch $CarrierEventPattern) {
        return
    }

    try {
        $event = $Line | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        return
    }

    $eventName = Get-EventProperty $event 'event'
    if (-not $eventName) {
        return
    }

    $eventTime = ConvertTo-EventTime (Get-EventProperty $event 'timestamp')

    switch ($eventName) {
        'Commander' {
            $Track.Cmdr = Get-EventProperty $event 'Name' $Track.Cmdr
            $Track.FID = Get-EventProperty $event 'FID' $Track.FID
        }

        'LoadGame' {
            if (-not $Track.Cmdr) {
                $Track.Cmdr = Get-EventProperty $event 'Commander'
            }
            if (-not $Track.FID) {
                $Track.FID = Get-EventProperty $event 'FID'
            }
        }

        'CarrierJumpRequest' {
            $carrierId = Get-EventProperty $event 'CarrierID'
            $systemName = Get-EventProperty $event 'SystemName'
            $body = Get-EventProperty $event 'Body'
            $carrierType = Get-EventProperty $event 'CarrierType'
            $departureTime = ConvertTo-EventTime (Get-EventProperty $event 'DepartureTime')

            if ($carrierId) {
                $script:CarrierState[[string]$carrierId] = @{
                    CarrierID     = $carrierId
                    CarrierType   = $carrierType
                    SystemName    = $systemName
                    Body          = $body
                    DepartureTime = $departureTime
                    Timestamp     = $eventTime
                }
            }

            if ($Notify) {
                $message = 'Jump plotted -> ' + $systemName
                $departureText = Get-LocalTimeText $departureTime
                if ($departureText) {
                    $message += ' (depart ' + $departureText + ')'
                }

                Write-TrackerLine -Message $message -Source (Get-EventTag -Track $Track -CarrierId $carrierId) -Color Cyan

                $context = New-CarrierContext -Event 'JumpPlotted' -Track $Track -Raw $event `
                    -CarrierId $carrierId -CarrierType $carrierType -SystemName $systemName `
                    -Body $body -DepartureTime $departureTime -Timestamp $eventTime
                Invoke-CarrierActions -Event 'JumpPlotted' -Context $context
            }
        }

        'CarrierJumpCancelled' {
            $carrierId = Get-EventProperty $event 'CarrierID'
            $carrierType = Get-EventProperty $event 'CarrierType'

            $state = $null
            if ($carrierId) {
                $state = $script:CarrierState[[string]$carrierId]
                $script:CarrierState.Remove([string]$carrierId)
            }

            $systemName = $null
            $departureTime = $null
            $body = $null
            if ($null -ne $state) {
                $systemName = $state.SystemName
                $departureTime = $state.DepartureTime
                $body = $state.Body
                if (-not $carrierType) {
                    $carrierType = $state.CarrierType
                }
            }

            if ($Notify) {
                $message = 'Jump CANCELLED'
                if ($systemName) {
                    $message += ' (was ' + $systemName
                    $departureText = Get-LocalTimeText $departureTime
                    if ($departureText) {
                        $message += ', due ' + $departureText
                    }
                    $message += ')'
                }

                Write-TrackerLine -Message $message -Source (Get-EventTag -Track $Track -CarrierId $carrierId) -Color Yellow

                $context = New-CarrierContext -Event 'JumpCancelled' -Track $Track -Raw $event `
                    -CarrierId $carrierId -CarrierType $carrierType -SystemName $systemName `
                    -Body $body -DepartureTime $departureTime -Timestamp $eventTime
                Invoke-CarrierActions -Event 'JumpCancelled' -Context $context
            }
        }

        'CarrierJump' {
            $carrierId = Get-EventProperty $event 'CarrierID'
            if (-not $carrierId) {
                $carrierId = Get-EventProperty $event 'MarketID'
            }

            $systemName = Get-EventProperty $event 'StarSystem'
            if (-not $systemName) {
                $systemName = Get-EventProperty $event 'SystemName'
            }
            $stationName = Get-EventProperty $event 'StationName'
            $carrierType = 'FleetCarrier'

            $state = $null
            if ($carrierId) {
                $state = $script:CarrierState[[string]$carrierId]
                $script:CarrierState.Remove([string]$carrierId)
            }

            $departureTime = $null
            $body = $null
            if ($null -ne $state) {
                $departureTime = $state.DepartureTime
                $body = $state.Body
                if ($state.CarrierType) {
                    $carrierType = $state.CarrierType
                }
            }

            if ($Notify) {
                $message = 'JUMP CONFIRMED -> ' + $systemName
                if ($stationName) {
                    $message += ' (' + $stationName + ')'
                }

                Write-TrackerLine -Message $message -Source (Get-EventTag -Track $Track -CarrierId $carrierId) -Color Green

                $context = New-CarrierContext -Event 'JumpConfirmed' -Track $Track -Raw $event `
                    -CarrierId $carrierId -CarrierType $carrierType -SystemName $systemName `
                    -Body $body -DepartureTime $departureTime -Timestamp $eventTime `
                    -StationName $stationName
                Invoke-CarrierActions -Event 'JumpConfirmed' -Context $context
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Tracking setup
# ---------------------------------------------------------------------------

function Initialize-TrackedJournal {
    param(
        [Parameter(Mandatory = $true)][System.IO.FileInfo]$File,
        [switch]$SilentBackfill
    )

    $info = Get-JournalInfo -File $File
    $key = Get-FileKey $File.FullName

    $track = @{
        Path      = $File.FullName
        Key       = $key
        FileName  = $File.Name
        Offset    = [long]0
        Remainder = [byte[]]@()
        Cmdr      = $info.Cmdr
        FID       = $info.FID
    }

    $script:Tracked[$key] = $track
    $script:KnownFiles[$key] = $true

    $who = $track.Cmdr
    if (-not $who) {
        $who = '(unknown CMDR)'
    }

    $lastEvent = $info.LastEvent
    if (-not $lastEvent) {
        $lastEvent = 'no events'
    }

    Write-TrackerLine -Message ("Following {0} | {1} | last event: {2}" -f $who, $track.FileName, $lastEvent) -Color DarkGray

    # Replay existing content. At startup this is silent and only rebuilds
    # state; a journal discovered while running is new, so its events notify.
    try {
        $result = Read-NextJournalLines -Path $track.Path -Offset 0 -Remainder ([byte[]]@())
        $track.Offset = $result.Offset
        $track.Remainder = $result.Remainder

        foreach ($line in $result.Lines) {
            if ($SilentBackfill) {
                Process-JournalLine -Line $line -Track $track
            }
            else {
                Process-JournalLine -Line $line -Track $track -Notify
            }
        }
    }
    catch {
        Write-Warning ("Could not read {0}: {1}" -f $track.FileName, (Format-Exception $_.Exception))
    }
}

function Read-JournalSelection {
    param([object[]]$Candidates)

    for ($attempt = 0; $attempt -lt 3; $attempt++) {
        $answer = Read-Host 'Follow: [a]ll (default) / 1,2 / [n]ewest / [q]uit'

        if ([string]::IsNullOrWhiteSpace($answer)) {
            return $Candidates
        }

        $answer = $answer.Trim().ToLowerInvariant()
        if ($answer -eq 'a' -or $answer -eq 'all') {
            return $Candidates
        }
        if ($answer -eq 'n' -or $answer -eq 'newest') {
            return @($Candidates[0])
        }
        if ($answer -eq 'q' -or $answer -eq 'quit') {
            $script:PromptQuit = $true
            return @()
        }

        $indices = @()
        $valid = $true

        foreach ($part in ($answer -split '[, ]+')) {
            if (-not $part) {
                continue
            }

            $number = 0
            if (-not [int]::TryParse($part, [ref]$number)) {
                $valid = $false
                break
            }
            if ($number -lt 1 -or $number -gt $Candidates.Count) {
                $valid = $false
                break
            }
            if (-not ($indices -contains $number)) {
                $indices += $number
            }
        }

        if ($valid -and $indices.Count -gt 0) {
            return @($indices | ForEach-Object { $Candidates[$_ - 1] })
        }

        Write-Host 'Invalid selection. Enter a, n, q, or numbers separated by commas.' -ForegroundColor Yellow
    }

    Write-Host 'No valid selection; following all candidates.' -ForegroundColor Yellow
    return $Candidates
}

function Show-JournalCandidates {
    param([object[]]$Candidates)

    Write-Host ''
    Write-Host 'Multiple recently active journals found:' -ForegroundColor White
    Write-Host ('  {0,-3} {1,-38} {2,-14} {3,-11} {4}' -f '#', 'Journal file', 'CMDR', 'Last write', 'Last event') -ForegroundColor DarkGray

    for ($index = 0; $index -lt $Candidates.Count; $index++) {
        $candidate = $Candidates[$index]
        $cmdr = $candidate.Cmdr
        if (-not $cmdr) {
            $cmdr = '(unknown)'
        }
        $lastEvent = $candidate.LastEvent
        if (-not $lastEvent) {
            $lastEvent = '(unknown)'
        }

        $lastWrite = $candidate.LastWriteTime.ToString('HH:mm', [System.Globalization.CultureInfo]::InvariantCulture)
        if ($candidate.LastWriteTime.Date -ne (Get-Date).Date) {
            $lastWrite = $candidate.LastWriteTime.ToString('MM-dd HH:mm', [System.Globalization.CultureInfo]::InvariantCulture)
        }
        Write-Host ('  {0,-3} {1,-38} {2,-14} {3,-11} {4}' -f `
            ($index + 1), $candidate.Name, $cmdr, $lastWrite, $lastEvent)
    }

    Write-Host ''
}

# ---------------------------------------------------------------------------
# Startup
# ---------------------------------------------------------------------------

if ($JournalPath -and $JournalPath.Count -gt 0) {
    foreach ($path in $JournalPath) {
        $script:JournalDirectories += Resolve-JournalDirectory $path
    }
}
else {
    $script:JournalDirectories = @(Get-DefaultJournalDirectories)
}

$script:JournalDirectories = @($script:JournalDirectories | Select-Object -Unique)

$existingDirectories = @()
foreach ($directory in $script:JournalDirectories) {
    if (Test-Path -LiteralPath $directory -PathType Container) {
        $existingDirectories += $directory
    }
    else {
        Write-Warning ("Journal directory not found: {0}" -f (Get-SafePath $directory))
    }
}

if ($existingDirectories.Count -eq 0) {
    Write-Host 'No Elite Dangerous journal directory found. Use -JournalPath to point at one.' -ForegroundColor Red
    exit 2
}

$script:JournalDirectories = $existingDirectories

if (-not $ActionScript) {
    $ActionScript = Join-Path $PSScriptRoot 'carrier-actions.ps1'
}

if (Test-Path -LiteralPath $ActionScript -PathType Leaf) {
    try {
        . $ActionScript
    }
    catch {
        Write-Warning ("Could not load action script {0}: {1}" -f (Get-SafePath $ActionScript), (Format-Exception $_.Exception))
    }
}
elseif ($PSBoundParameters.ContainsKey('ActionScript')) {
    Write-Warning ("Action script not found: {0}" -f (Get-SafePath $ActionScript))
}

Write-Host 'Elite Dangerous carrier jump tracker' -ForegroundColor White
foreach ($directory in $script:JournalDirectories) {
    Write-Host ('Journal folder: ' + (Get-SafePath $directory)) -ForegroundColor DarkGray
}

$allFiles = @(Get-JournalFiles)
foreach ($file in $allFiles) {
    $script:KnownFiles[(Get-FileKey $file.FullName)] = $true
}

$candidateInfos = @()

if ($Follow -and $Follow.Count -gt 0) {
    $followSet = @($Follow | ForEach-Object { $_.ToLowerInvariant() })
    foreach ($file in $allFiles) {
        if ($followSet -contains $file.Name.ToLowerInvariant()) {
            $candidateInfos += New-JournalCandidate -File $file
        }
    }

    if ($candidateInfos.Count -eq 0) {
        Write-Host 'None of the requested journals were found.' -ForegroundColor Red
        exit 2
    }
}
else {
    $cutoff = (Get-Date).AddMinutes(-$ActiveWindowMinutes)
    $recentFiles = @($allFiles | Where-Object { $_.LastWriteTime -ge $cutoff } | Sort-Object LastWriteTime -Descending)

    foreach ($file in $recentFiles) {
        $candidateInfos += New-JournalCandidate -File $file
    }
}

if ($candidateInfos.Count -eq 0) {
    $newestFile = @($allFiles | Sort-Object LastWriteTime -Descending | Select-Object -First 1)
    if ($newestFile.Count -gt 0) {
        Write-TrackerLine -Message ('No journals modified in the last {0} minutes; following the newest journal in case a session is already open.' -f $ActiveWindowMinutes) -Color DarkYellow
        $candidateInfos = @(New-JournalCandidate -File $newestFile[0])
    }
    else {
        Write-TrackerLine -Message 'No journals found. Waiting for a new session...' -Color DarkYellow
    }
}

$candidateInfos = @($candidateInfos | Sort-Object LastWriteTime -Descending)
$selected = @()

if ($candidateInfos.Count -eq 1) {
    $selected = @($candidateInfos[0])
}
elseif ($candidateInfos.Count -gt 1) {
    if (($Follow -and $Follow.Count -gt 0) -or $FollowAll) {
        $selected = $candidateInfos
    }
    elseif (-not [Console]::IsInputRedirected) {
        Show-JournalCandidates -Candidates $candidateInfos
        $selected = @(Read-JournalSelection -Candidates $candidateInfos)
    }
    else {
        Write-TrackerLine -Message 'Multiple recently active journals found and input is not interactive; following all.' -Color DarkYellow
        $selected = $candidateInfos
    }
}

if ($script:PromptQuit) {
    Write-Host 'Nothing followed. Exiting.' -ForegroundColor DarkGray
    exit 0
}

if ($candidateInfos.Count -gt 1) {
    foreach ($candidate in $candidateInfos) {
        $isSelected = $false
        foreach ($item in $selected) {
            if ($item.FullName -eq $candidate.FullName) {
                $isSelected = $true
                break
            }
        }
        if (-not $isSelected) {
            $who = $candidate.Cmdr
            if (-not $who) {
                $who = '(unknown CMDR)'
            }
            Write-TrackerLine -Message ('Not following {0} ({1})' -f $who, $candidate.Name) -Color DarkGray
        }
    }
}

# Backfill oldest first so the newest known state wins for each carrier.
foreach ($candidate in @($selected | Sort-Object LastWriteTime, Name)) {
    Initialize-TrackedJournal -File $candidate.File -SilentBackfill
}

Write-Host ''
Write-Host 'Watching for carrier events. Press Ctrl+C to stop.' -ForegroundColor White

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------

$lastDiscovery = Get-Date

while ($true) {
    $now = Get-Date

    if (($now - $lastDiscovery).TotalMilliseconds -ge 2000) {
        $lastDiscovery = $now

        foreach ($file in @(Get-JournalFiles)) {
            $key = Get-FileKey $file.FullName
            if ($script:Tracked.ContainsKey($key)) {
                continue
            }
            if ($script:KnownFiles.ContainsKey($key)) {
                continue
            }

            Initialize-TrackedJournal -File $file
        }
    }

    foreach ($key in @($script:Tracked.Keys)) {
        $track = $script:Tracked[$key]

        if (-not (Test-Path -LiteralPath $track.Path -PathType Leaf)) {
            Write-TrackerLine -Message ('Journal disappeared: ' + $track.FileName) -Color DarkYellow
            $script:Tracked.Remove($key)
            continue
        }

        try {
            $result = Read-NextJournalLines -Path $track.Path -Offset $track.Offset -Remainder $track.Remainder
            $track.Offset = $result.Offset
            $track.Remainder = $result.Remainder

            foreach ($line in $result.Lines) {
                Process-JournalLine -Line $line -Track $track -Notify
            }
        }
        catch {
            Write-Warning ("Error reading {0}: {1}" -f $track.FileName, (Format-Exception $_.Exception))
        }
    }

    Start-Sleep -Milliseconds $PollMilliseconds
}
