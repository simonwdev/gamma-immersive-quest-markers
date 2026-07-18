# Creates (or removes) a junction that exposes this repo as an MO2 mod, so the
# working copy is playable in-game without copying files. A junction (not a
# symlink) because it needs no admin rights / Developer Mode and MO2's VFS
# follows it transparently.
#
#   .\scripts\link-mo2-mod.ps1 -ModsDir "D:\gamma0.9.5\GAMMA\mods"
#   .\scripts\link-mo2-mod.ps1 -ModsDir "D:\gamma0.9.5\GAMMA\mods" -Remove
[CmdletBinding()]
param(
    # MO2 mods folder to link into (e.g. D:\gamma0.9.5\GAMMA\mods)
    [Parameter(Mandatory)]
    [string]$ModsDir,

    # Remove the junction instead of creating it
    [switch]$Remove,

    # Mod folder name as it appears in MO2
    [string]$Name = "Immersive Quest Markers"
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $ModsDir -PathType Container)) {
    throw "Mods folder not found: $ModsDir"
}

# The script lives in scripts\; the mod root is the repo root one level up.
$target = Split-Path $PSScriptRoot -Parent
$link   = Join-Path $ModsDir $Name

if ($Remove) {
    if (-not (Test-Path -LiteralPath $link)) {
        Write-Host "Nothing to remove: $link does not exist."
        return
    }
    $item = Get-Item -LiteralPath $link -Force
    # Only ever delete a reparse point: a real directory here is an installed
    # copy of the mod, and deleting it would destroy files.
    if (-not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "$link is a real directory, not a junction - refusing to delete it."
    }
    # Deletes the junction itself; the target's contents are untouched.
    $item.Delete()
    Write-Host "Removed junction: $link"
    return
}

if (Test-Path -LiteralPath $link) {
    $item = Get-Item -LiteralPath $link -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -and $item.Target -eq $target) {
        Write-Host "Already linked: $link -> $target"
        return
    }
    throw "$link already exists and is not a junction to this repo - remove it in MO2 first."
}

New-Item -ItemType Junction -Path $link -Target $target | Out-Null
Write-Host "Created junction: $link -> $target"
Write-Host "Refresh MO2 (F5) and enable '$Name' in the left pane."
