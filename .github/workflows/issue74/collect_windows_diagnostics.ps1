[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [DateTime] $StartUtc,

    [Parameter(Mandatory = $true)]
    [string] $OutputDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$eventDirectory = Join-Path $OutputDirectory 'event-logs'
$werDirectory = Join-Path $OutputDirectory 'wer'
New-Item -ItemType Directory -Force -Path $eventDirectory, $werDirectory | Out-Null

$startUtcValue = $StartUtc.ToUniversalTime()
$startLocal = $startUtcValue.ToLocalTime()
$processPattern = '(?i)\b(?:ld|ld\.lld|lld-link|collect2|gcc|g\+\+|clang|clang\+\+|cc1|cc1plus|lto1|lto-wrapper|as|v)\.exe\b'
$collectionReport = Join-Path $OutputDirectory 'collection.txt'
@(
    "start_utc=$($startUtcValue.ToString('o'))"
    "collection_utc=$([DateTime]::UtcNow.ToString('o'))"
    "computer=$env:COMPUTERNAME"
    "os=$([Environment]::OSVersion.VersionString)"
    'WER dumps are intentionally not uploaded; their size and SHA-256 are recorded when accessible.'
) | Set-Content -Encoding UTF8 -Path $collectionReport

$eventLogs = @(
    'Application'
    'Microsoft-Windows-Windows Defender/Operational'
    'Microsoft-Windows-CodeIntegrity/Operational'
)

foreach ($logName in $eventLogs) {
    $safeName = $logName -replace '[^A-Za-z0-9._-]', '_'
    $eventOutput = Join-Path $eventDirectory "$safeName.txt"
    try {
        $matchingEvents = @(
            Get-WinEvent -FilterHashtable @{ LogName = $logName; StartTime = $startLocal } -ErrorAction Stop |
                Where-Object {
                    $message = $_.Message
                    $null -ne $message -and $message -match $processPattern
                }
        )
        if ($matchingEvents.Count -eq 0) {
            "No matching compiler/linker events since $($startUtcValue.ToString('o'))." |
                Set-Content -Encoding UTF8 -Path $eventOutput
            continue
        }
        $matchingEvents |
            Select-Object TimeCreated, Id, LevelDisplayName, ProviderName, LogName, RecordId, Message |
            Format-List |
            Out-String -Width 4096 |
            Set-Content -Encoding UTF8 -Path $eventOutput
    } catch {
        "Event log query failed: $($_.Exception.Message)" |
            Set-Content -Encoding UTF8 -Path $eventOutput
    }
}

$werRoots = @(
    (Join-Path $env:ProgramData 'Microsoft\Windows\WER\ReportArchive')
    (Join-Path $env:ProgramData 'Microsoft\Windows\WER\ReportQueue')
    (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\WER\ReportArchive')
    (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\WER\ReportQueue')
) | Select-Object -Unique

$werManifest = Join-Path $werDirectory 'manifest.txt'
"WER reports matching compiler/linker processes since $($startUtcValue.ToString('o'))" |
    Set-Content -Encoding UTF8 -Path $werManifest
$reportIndex = 0

foreach ($werRoot in $werRoots) {
    if (-not (Test-Path -LiteralPath $werRoot)) {
        "root_missing=$werRoot" | Add-Content -Encoding UTF8 -Path $werManifest
        continue
    }
    try {
        $reportFiles = @(
            Get-ChildItem -LiteralPath $werRoot -Filter 'Report.wer' -File -Recurse -ErrorAction Stop |
                Where-Object { $_.LastWriteTimeUtc -ge $startUtcValue }
        )
    } catch {
        "root_query_failed=$werRoot :: $($_.Exception.Message)" |
            Add-Content -Encoding UTF8 -Path $werManifest
        continue
    }

    foreach ($reportFile in $reportFiles) {
        try {
            $reportContent = Get-Content -LiteralPath $reportFile.FullName -Raw -ErrorAction Stop
            if ($reportContent -notmatch $processPattern) {
                continue
            }
            $reportIndex++
            $reportParent = Split-Path -Parent $reportFile.FullName
            $reportLeaf = (Split-Path -Leaf $reportParent) -replace '[^A-Za-z0-9._-]', '_'
            $destination = Join-Path $werDirectory ('{0:D3}_{1}' -f $reportIndex, $reportLeaf)
            New-Item -ItemType Directory -Force -Path $destination | Out-Null
            Copy-Item -LiteralPath $reportFile.FullName -Destination $destination -Force
            $metadataFiles = @(
                Get-ChildItem -LiteralPath $reportParent -File -ErrorAction SilentlyContinue |
                    Where-Object { $_.Extension -in @('.xml', '.txt') }
            )
            foreach ($metadataFile in $metadataFiles) {
                Copy-Item -LiteralPath $metadataFile.FullName -Destination $destination -Force -ErrorAction SilentlyContinue
            }
            "report=$($reportFile.FullName)" | Add-Content -Encoding UTF8 -Path $werManifest

            foreach ($dumpFile in (Get-ChildItem -LiteralPath $reportParent -Filter '*.dmp' -File -ErrorAction SilentlyContinue)) {
                try {
                    $dumpHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $dumpFile.FullName).Hash
                    "dump_not_copied=$($dumpFile.FullName) size=$($dumpFile.Length) sha256=$dumpHash" |
                        Add-Content -Encoding UTF8 -Path $werManifest
                } catch {
                    "dump_not_copied=$($dumpFile.FullName) metadata_error=$($_.Exception.Message)" |
                        Add-Content -Encoding UTF8 -Path $werManifest
                }
            }
        } catch {
            "report_read_failed=$($reportFile.FullName) :: $($_.Exception.Message)" |
                Add-Content -Encoding UTF8 -Path $werManifest
        }
    }
}

"matching_report_count=$reportIndex" | Add-Content -Encoding UTF8 -Path $werManifest
