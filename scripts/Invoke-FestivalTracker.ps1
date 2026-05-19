param(
    [ValidateSet("Lineups", "Availability", "All")]
    [string]$Mode = "All",

    [string]$ConfigPath = (Join-Path (Get-Location) "config/festivals.json"),
    [string]$AuthorizedSourcesPath = (Join-Path (Get-Location) "config/authorized_sources.json"),
    [string]$StateDir = (Join-Path (Get-Location) ".tracker"),

    [switch]$UseNotion,
    [switch]$RespectFestivalWindows,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"
$modulePath = Join-Path $PSScriptRoot "..\src\FestivalTracker.psm1"
Import-Module $modulePath -Force

Invoke-FestivalTracker `
    -Mode $Mode `
    -ConfigPath $ConfigPath `
    -AuthorizedSourcesPath $AuthorizedSourcesPath `
    -StateDir $StateDir `
    -UseNotion:$UseNotion `
    -RespectFestivalWindows:$RespectFestivalWindows `
    -DryRun:$DryRun
