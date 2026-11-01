# Actions for carrier-watch.ps1
#
# This file is dot-sourced at startup. Register handlers with:
#
#   Register-CarrierAction -Event JumpPlotted|JumpCancelled|JumpConfirmed -Action { param($Context) ... }
#
# Every handler receives one object with these fields:
#
#   Event          'JumpPlotted', 'JumpCancelled' or 'JumpConfirmed'
#   JournalEvent   Raw journal event name (e.g. 'CarrierJumpRequest')
#   Cmdr           Commander name, if known
#   FID            Frontier account id, if known
#   CarrierID      Carrier market id
#   CarrierType    e.g. 'FleetCarrier'
#   SystemName     Destination system (for a cancel: the cancelled destination)
#   Body           Destination body, when present
#   DepartureTime  [DateTimeOffset] (UTC), when known
#   Timestamp      [DateTimeOffset] (UTC) of the journal event
#   StationName    Carrier callsign, present on confirmed jumps
#   JournalFile    Full path of the journal that produced the event
#   Raw            The parsed journal object
#
# Handler errors are caught and reported as warnings; they do not stop the
# watcher. All three events are delivered in addition to the built-in console
# output.

# --- Examples -------------------------------------------------------------
#
# Play a system sound on a confirmed jump:
#
# Register-CarrierAction -Event JumpConfirmed -Action {
#     param($Context)
#     [System.Media.SystemSounds]::Exclamation.Play()
# }
#
# Post to a Discord webhook:
#
# Register-CarrierAction -Event JumpPlotted -Action {
#     param($Context)
#     $payload = @{ content = "Carrier jump plotted: $($Context.SystemName)" } | ConvertTo-Json -Compress
#     Invoke-RestMethod -Uri 'https://discord.com/api/webhooks/REPLACE_ME' `
#         -Method Post -Body $payload -ContentType 'application/json'
# }
#
# Append to a log file:
#
# Register-CarrierAction -Event JumpConfirmed -Action {
#     param($Context)
#     '{0:o} {1} confirmed -> {2}' -f $Context.Timestamp, $Context.Cmdr, $Context.SystemName |
#         Add-Content -Path "$env:USERPROFILE\carrier-jumps.log"
# }
