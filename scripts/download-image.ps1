<#
.SYNOPSIS
    Download a filamind-iotbox release, verify SHA-256 at every stage, and
    reassemble the .img -- native Windows / PowerShell. No WSL or bash needed.

.DESCRIPTION
    Mirrors scripts/download-image.sh but uses Get-FileHash for verification
    and `cmd /c copy /b` for binary concatenation, so it runs on a stock
    Windows install with only `gh` and `zstd` as external dependencies.

.PARAMETER Version
    Release tag to download (e.g. "v1.0.0"). Default: "latest".

.PARAMETER OutputDir
    Local folder to write artifacts into. Default: ".\iotbox-image".

.PARAMETER Repo
    GitHub repository in <owner>/<name> form. Default: filamind-app/filamind-iotbox.

.EXAMPLE
    .\download-image.ps1
    Downloads the latest release into .\iotbox-image\

.EXAMPLE
    .\download-image.ps1 -Version v1.2.0 -OutputDir D:\images
    Downloads v1.2.0 into D:\images\

.NOTES
    Prerequisites:
      * GitHub CLI :  winget install --id GitHub.cli
      * zstd       :  winget install --id Facebook.Zstandard
                       (or: scoop install zstd)
                       (alternative: 7-Zip 22+ unpacks .zst manually)

    The script verifies SHA-256 three times -- on the parts, on the
    concatenated .zst, and on the final .img -- so a corrupted download is
    caught before you flash to an SD card.
#>

[CmdletBinding()]
param(
    [string]$Version    = "latest",
    [string]$OutputDir  = ".\iotbox-image",
    [string]$Repo       = "filamind-app/filamind-iotbox"
)

$ErrorActionPreference = "Stop"

function Step($msg) { Write-Host ">> $msg" -ForegroundColor Cyan }
function OK  ($msg) { Write-Host "   $msg" -ForegroundColor Green }
function Die ($msg) { Write-Host "ERROR: $msg" -ForegroundColor Red; exit 1 }

# ---- 1. Pre-flight checks -----------------------------------------------
if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    Die "GitHub CLI (gh) not found. Install with: winget install --id GitHub.cli"
}
$zstdAvailable = [bool](Get-Command zstd -ErrorAction SilentlyContinue)
if (-not $zstdAvailable) {
    Write-Warning "zstd not found on PATH -- will skip decompression at the end."
    Write-Warning "Install: winget install --id Facebook.Zstandard"
    Write-Warning "(or extract the .img.zst manually with 7-Zip 22+)"
}

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
$resolved = (Resolve-Path $OutputDir).Path
Push-Location $resolved
try {

    # ---- 2. Download release assets via gh ------------------------------
    Step "Downloading $Version from $Repo"
    if ($Version -eq 'latest') {
        & gh release download `
            --repo $Repo `
            --pattern '*.part' --pattern 'MANIFEST.sha256' --clobber
    } else {
        & gh release download $Version `
            --repo $Repo `
            --pattern '*.part' --pattern 'MANIFEST.sha256' --clobber
    }
    if ($LASTEXITCODE -ne 0) { Die "gh release download failed" }

    if (-not (Test-Path 'MANIFEST.sha256')) {
        Die "MANIFEST.sha256 missing from release"
    }

    # ---- 3. Parse the manifest into a hash table {filename = hash} ------
    $manifest = @{}
    foreach ($line in Get-Content 'MANIFEST.sha256') {
        if ($line -match '^\s*#' -or -not $line.Trim()) { continue }
        if ($line -match '^([0-9a-fA-F]{64})\s+\*?(\S+)\s*$') {
            $manifest[$matches[2]] = $matches[1].ToUpper()
        }
    }

    # ---- 4. Verify each .part -------------------------------------------
    Step "Verifying parts"
    $parts = Get-ChildItem -Filter '*.part' | Sort-Object Name
    if ($parts.Count -eq 0) { Die "no .part files downloaded" }
    foreach ($p in $parts) {
        $expected = $manifest[$p.Name]
        if (-not $expected) { Die "no manifest entry for $($p.Name)" }
        $actual = (Get-FileHash -Algorithm SHA256 -Path $p.FullName).Hash
        if ($actual -ne $expected) {
            Die "SHA-256 mismatch on $($p.Name)`nexpected $expected`ngot      $actual"
        }
        OK "$($p.Name)"
    }

    # ---- 5. Concatenate parts into the .zst -----------------------------
    $base = $parts[0].Name -replace '\.\d+\.part$',''
    Step "Concatenating $($parts.Count) part(s) -> $base"
    # cmd /c copy /b is the fastest binary concat on Windows
    $copyArg = ($parts | ForEach-Object { $_.Name }) -join '+'
    cmd /c "copy /b $copyArg `"$base`"" | Out-Null
    if (-not (Test-Path $base)) { Die "concat failed: $base not produced" }

    # ---- 6. Verify the compressed .zst ----------------------------------
    Step "Verifying compressed image"
    $expected = $manifest[$base]
    if (-not $expected) { Die "no manifest entry for $base" }
    $actual = (Get-FileHash -Algorithm SHA256 -Path $base).Hash
    if ($actual -ne $expected) {
        Die "SHA-256 mismatch on $base -- concat corrupted"
    }
    OK $base

    # ---- 7. Decompress (if zstd is available) ---------------------------
    $final = $base -replace '\.zst$',''
    if ($zstdAvailable) {
        Step "Decompressing $base -> $final"
        & zstd -d --long=27 -f $base -o $final
        if ($LASTEXITCODE -ne 0) { Die "zstd decompression failed" }

        # ---- 8. Verify final .img ---------------------------------------
        Step "Verifying final image"
        $expected = $manifest[$final]
        if (-not $expected) {
            Write-Warning "no manifest entry for $final -- skipping final hash check"
        } else {
            $actual = (Get-FileHash -Algorithm SHA256 -Path $final).Hash
            if ($actual -ne $expected) {
                Die "SHA-256 mismatch on $final -- bad zstd output"
            }
            OK $final
        }

        # ---- 9. Cleanup intermediate artifacts --------------------------
        Remove-Item -Force -Path *.part, $base
        Step "Done"
        Get-Item $final
        Write-Host ""
        Write-Host "Flash with:" -ForegroundColor Yellow
        Write-Host "    Raspberry Pi Imager -> 'Use custom' -> $((Get-Item $final).FullName)"
        Write-Host ""
    } else {
        Step "Stopping before decompression -- install zstd to finish"
        Get-Item $base
        Write-Host ""
        Write-Host "To finish manually:" -ForegroundColor Yellow
        Write-Host "  1. winget install --id Facebook.Zstandard"
        Write-Host "  2. zstd -d --long=27 -f $base -o $final"
        Write-Host "  3. Flash $final with Raspberry Pi Imager"
        Write-Host ""
    }

}
finally {
    Pop-Location
}
