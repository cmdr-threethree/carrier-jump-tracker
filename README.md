# Carrier Jump Tracker

Follows Elite Dangerous journals and reports fleet carrier jumps:

- **Jump plotted** — `CarrierJumpRequest`
- **Jump cancelled** — `CarrierJumpCancelled`
- **Jump confirmed** — `CarrierJump` (only written when you are aboard the carrier)

Multiple journals are supported, so multiboxed clients with different
commanders are tagged and reported separately.

```
[18:08:41] [OneThree / 3701044480] Jump plotted -> Praea Euq VO-A d42 (depart 21:10 local)
[20:37:55] [threethree / 3714708224] Jump CANCELLED (was Col 285 Sector LG-F b27-0, due 22:51 local)
[19:00:41] [OneThree / 3701044480] JUMP CONFIRMED -> Praea Euq VO-A d42 (JBH-G9Q)
```

## Requirements

- Windows 10 or 11 with Windows PowerShell 5.1 (installed by default)
- Elite Dangerous running for new journal events to appear
- No modules, services, or installers

## Running

Double-click `start.cmd`, or:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\carrier-watch.ps1
```

The default journal folder is:

```
%USERPROFILE%\Saved Games\Frontier Developments\Elite Dangerous
```

Optional parameters:

| Parameter | Default | Meaning |
|---|---|---|
| `-JournalPath <dirs>` | Saved Games path | One or more journal folders |
| `-ActiveWindowMinutes <n>` | `15` | How recent a journal must be to be offered at startup |
| `-PollMilliseconds <n>` | `500` | Journal polling interval |
| `-FollowAll` | off | Follow every recent journal without prompting |
| `-Follow <names>` | none | Follow specific journal file names |
| `-ActionScript <path>` | `carrier-actions.ps1` | Custom action definitions |
| `-ShowPaths` | off | Show full paths and full exception messages |

Examples:

```powershell
.\carrier-watch.ps1 -FollowAll
.\carrier-watch.ps1 -ActiveWindowMinutes 60
.\carrier-watch.ps1 -JournalPath "D:\ED\Journals" -FollowAll
.\carrier-watch.ps1 -Follow "Journal.2026-10-31T142543.01.log"
.\carrier-watch.ps1 -Follow "Journal.2026-10-31T142543.01.log,Journal.2026-10-31T094507.01.log"
.\carrier-watch.ps1 -JournalPath "C:\ED\AccountA,C:\ED\AccountB" -FollowAll
.\carrier-watch.ps1 -ShowPaths
```

When the script is launched through `powershell.exe -File` (which is what
`start.cmd` does), list parameters are passed as one comma-separated string.
Without a comma, a second value would be bound to the next parameter.

## Paths in output

Journal paths are shortened by default so console output and screenshots do
not expose the Windows account name:

```
Elite Dangerous carrier jump tracker
Journal folder: %USERPROFILE%\Saved Games\Frontier Developments\Elite Dangerous
```

- The default folder appears as `%USERPROFILE%\...`.
- Paths under `%APPDATA%`, `%LOCALAPPDATA%`, `%TEMP%` use those variable names.
- Other profile paths show the account component as `<user>`.
- Any other custom folder is reduced to `...\<folder name>`.
- Paths in warnings are shown through the same shortening.
- Warnings that report exceptions show only the exception type; `-ShowPaths`
  restores the full message.

Use `-ShowPaths` when debugging and you need the real full paths. It also
restores full exception messages in warnings. The console window title is set
to a fixed, path-free value.

The tool cannot change a PowerShell prompt or the command you typed before
starting it. Launch it through `start.cmd` in a fresh window when the whole
screen needs to be screenshot-safe. A parameter-binding error occurs before
the script runs and can still print the script's own path; keeping the tool
outside your user profile avoids that.

## Multiple clients / multiboxing

Journals from every commander in the watched folder are handled. Existing
content is read silently at startup to learn each commander and carrier state;
only events that arrive afterwards produce messages and actions.

If more than one journal was modified recently, startup shows a prompt:

```
Multiple recently active journals found:
  #   Journal file                           CMDR           Last write   Last event
  1   Journal.2026-11-01T17:02.01.log        OneThree       10:47        CarrierJumpRequest
  2   Journal.2026-11-01T17:40.01.log        threethree     10:46        LoadGame

Follow: [a]ll (default) / 1,2 / [n]ewest / [q]uit >
```

- `a` or Enter follows everything
- `1,2` follows the listed files
- `n` follows only the newest
- `q` exits

If input is redirected (for example a scheduled task or `Start-Process`),
all candidates are followed. A brand-new journal created while the watcher is
running is picked up automatically.

If nothing was written within the active window, the newest journal is followed
in case a session is already open; otherwise the watcher waits for a new
session to appear. When starting late with several idle clients, widen
`-ActiveWindowMinutes` or name the journals with `-Follow`.

Use `-JournalPath` more than once if multiboxed clients run under different
Windows profiles and both journal folders are readable.

## Actions

`carrier-actions.ps1` is dot-sourced at startup. Handlers run for all three
events in addition to the console output, and receive a context object with
the commander, carrier, destination, departure time and raw journal event.

```powershell
# Play a sound on a confirmed jump
Register-CarrierAction -Event JumpConfirmed -Action {
    param($Context)
    [System.Media.SystemSounds]::Exclamation.Play()
}
```

See `carrier-actions.ps1` for the full field list and Discord/log examples.
A failing handler is reported as a warning and does not stop the watcher.
Handlers run inline, so keep them quick; a slow action only delays reading,
and later events remain in the journal to be processed afterwards.

## Testing without the game

The repository includes a seed journal in `testdata`. Start the watcher on it:

```powershell
.\carrier-watch.ps1 -JournalPath .\testdata -Follow "Journal.2026-11-01T120000.01.log"
```

Then, from a second PowerShell window, append events to exercise each trigger:

```powershell
$journal = '.\testdata\Journal.2026-11-01T120000.01.log'

# Plot
'{ "timestamp":"2026-11-01T12:05:00Z", "event":"CarrierJumpRequest", "CarrierType":"FleetCarrier", "CarrierID":3701044480, "SystemName":"Praea Euq VO-A d42", "Body":"Praea Euq VO-A d42 A", "SystemAddress":1453603211651, "BodyID":1, "DepartureTime":"2026-11-01T12:20:10Z" }' |
    Add-Content -Path $journal

# Cancel (uses the remembered destination)
'{ "timestamp":"2026-11-01T12:06:00Z", "event":"CarrierJumpCancelled", "CarrierType":"FleetCarrier", "CarrierID":3701044480 }' |
    Add-Content -Path $journal

# Plot again, then confirm
'{ "timestamp":"2026-11-01T12:07:00Z", "event":"CarrierJumpRequest", "CarrierType":"FleetCarrier", "CarrierID":3701044480, "SystemName":"HIP 57478", "DepartureTime":"2026-11-01T12:22:10Z" }' |
    Add-Content -Path $journal

'{ "timestamp":"2026-11-01T12:22:12Z", "event":"CarrierJump", "Docked":true, "StationName":"JBH-G9Q", "StationType":"FleetCarrier", "MarketID":3701044480, "StarSystem":"HIP 57478", "SystemAddress":84325798410, "Body":"HIP 57478", "BodyID":0 }' |
    Add-Content -Path $journal
```

Restart the watcher after deleting the test journal's appended lines if you
want a clean demo.

## Limitations

- `CarrierJump` exists only if the player is online and docked aboard the
  carrier when it jumps. Plotted/cancelled events are always captured while
  the owning client is running.
- Journals are only written while the game is running. The tracker cannot
  report a jump that happened while every client was closed.
- The tracker does not fire a reminder at `DepartureTime`; it reports the
  three journal events only.
- If the watcher is restarted between a plot and a cancel, the cancelled
  destination is only enriched when the plot is in the same journal that is
  backfilled.
- Only the newest journal folder level is scanned; subfolders such as `old`
  are ignored.
