# Builds the manual-install zip for a release.
#
# Do NOT use Compress-Archive: it writes backslash path separators into the
# entry names, which Linux-side tooling (and Thunderstore's validator) reject,
# and PowerShell 5.1's default encoding would put a UTF-8 BOM in any text file
# written alongside it. .NET's ZipArchive lets us name entries explicitly.
#
#   .\makezip.ps1 [outputPath]

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$out = $args[0]
if (-not $out) { $out = Join-Path $root "RotVitals.zip" }
if (Test-Path $out) { Remove-Item $out -Force }

# local path -> entry name (entry names must use forward slashes)
$pairs = @(
    @("Mods\RotVitals\enabled.txt",                "Mods/RotVitals/enabled.txt"),
    @("Mods\RotVitals\Scripts\main.lua",           "Mods/RotVitals/Scripts/main.lua"),
    @("UE4SS_Signatures\FName_Constructor.lua",    "UE4SS_Signatures/FName_Constructor.lua"),
    @("UE4SS_Signatures\GNatives.lua",             "UE4SS_Signatures/GNatives.lua"),
    @("UE4SS_Signatures\GUObjectHashTables.lua",   "UE4SS_Signatures/GUObjectHashTables.lua"),
    @("README.md",                                 "README.md")
)

$zip = [System.IO.Compression.ZipFile]::Open($out, [System.IO.Compression.ZipArchiveMode]::Create)
try {
    foreach ($p in $pairs) {
        $src = Join-Path $root $p[0]
        if (-not (Test-Path $src)) { throw ("missing " + $p[0]) }
        [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
            $zip, $src, $p[1], [System.IO.Compression.CompressionLevel]::Optimal) | Out-Null
        Write-Output ("  + " + $p[1])
    }
} finally {
    $zip.Dispose()
}
Write-Output "wrote $out ($((Get-Item $out).Length) bytes)"
