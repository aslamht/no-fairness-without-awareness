param([ValidateSet('clean', 'preexisting')][string]$Scenario)

$ErrorActionPreference = 'Continue'
$root = (Resolve-Path "$PSScriptRoot\..\..").Path
$qs = Join-Path $root 'QuickStart'
$results = [System.Collections.Generic.List[object]]::new()

function Check([string]$Name, [scriptblock]$Test) {
    try { $ok = [bool](& $Test) } catch { $ok = $false; Write-Host "  exception: $($_.Exception.Message)" }
    $results.Add([pscustomobject]@{ Check = $Name; Result = $(if ($ok) { 'PASS' } else { 'FAIL' }) })
    Write-Host ("[{0}] {1}" -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $Name) -ForegroundColor $(if ($ok) { 'Green' } else { 'Red' })
}
function Step([string]$t) { Write-Host "`n===== $t =====" -ForegroundColor Cyan }

. "$qs\Manifest.ps1"; . "$qs\Install.ps1"; . "$qs\Uninstall.ps1"
. "$qs\RtoolsRenviron.ps1"; . "$qs\PositronSettings.ps1"; . "$qs\Menu.ps1"

# CI-runner draait als admin; Scoop weigert dat zonder -RunAsAdmin. Echte gebruikers zijn geen admin.
function Install-Scoop {
    Write-Host "Scoop installeren (CI: -RunAsAdmin)..." -ForegroundColor Cyan
    Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser -Force
    Invoke-Expression "& {$(Invoke-RestMethod -Uri https://get.scoop.sh)} -RunAsAdmin"
}
# Geen interactieve prompts in CI
$script:YesNoAnswer = $true
function Read-YesNo { param([string]$Prompt) Write-Host "$Prompt -> $script:YesNoAnswer"; return $script:YesNoAnswer }

$scoopApps = "$env:USERPROFILE\scoop\apps"

if ($Scenario -eq 'preexisting') {
    Step 'Voorbereiding: Scoop + git staan al (vóór QuickStart)'
    Install-Scoop
    scoop install git
    Check 'Scoop + git vooraf aanwezig' { Test-Path "$scoopApps\git" }
}

Step 'Eerste installatie (Invoke-InstallFlow)'
Check 'Scoop nog niet aanwezig vóór install (clean)' { $Scenario -ne 'clean' -or -not (Test-ScoopInstalled) }
Invoke-WithErrorLogging { Invoke-InstallFlow -ProjectRoot $root }

Check 'state.json aangemaakt' { Test-PreviousSetup }
Check 'error.log leeg/afwezig' { -not (Test-Path $Script:ErrorLogPath) }
Check 'scoop in PATH van dezelfde sessie' { [bool](Get-Command scoop -ErrorAction SilentlyContinue) }
foreach ($a in 'r', 'rtools', 'quarto', 'positron', 'git', '7zip', 'aria2') {
    Check "app '$a' geinstalleerd" { Test-Path "$scoopApps\$a\current" }
}
Check 'R 4.6.2 aanwezig' { Test-Path "$scoopApps\r\4.6.2\bin\x64\R.exe" }
$m = Get-SetupManifest
Check 'Rtools bin-pad uit manifest bestaat' { Test-Path $m.rtoolsRenvironPath }
Check 'make.exe in Rtools bin-pad' { Test-Path (Join-Path $m.rtoolsRenvironPath 'make.exe') }
Check '.Renviron bevat Rtools-regel' { (Get-Content "$root\.Renviron") -match '^PATH=.*rtools' }
Check 'settings.json wijst naar bestaande R.exe' {
    $s = Get-Content "$root\.vscode\settings.json" -Raw | ConvertFrom-Json
    Test-Path ($s.'positron.r.customBinaries'[0] -replace '/', '\')
}
Check 'quarto --version werkt' { $v = & quarto --version; Write-Host "  quarto $v"; $LASTEXITCODE -eq 0 }
Check 'positron-shim bestaat' { [bool](Get-Command positron -ErrorAction SilentlyContinue) }

Step 'R vindt Rtools via project-.Renviron en kan C compileren'
Push-Location $root
$rscript = "$scoopApps\r\4.6.2\bin\x64\Rscript.exe"
& $rscript -e "cat('R:', R.version.string, '\n'); cat('make:', Sys.which('make'), '\n')"
Set-Content "$env:TEMP\hello.c" '#include <R.h>
void hello(int *x){ *x = 42; }'
Check 'R CMD SHLIB compileert (Rtools werkt)' {
    $env:R_ENVIRON_USER = "$root\.Renviron"
    & "$scoopApps\r\4.6.2\bin\x64\R.exe" CMD SHLIB "$env:TEMP\hello.c"; $LASTEXITCODE -eq 0
}
Remove-Item Env:R_ENVIRON_USER
Check 'Rscript in projectmap ziet make (zonder hulp)' {
    $p = & $rscript -e "cat(nzchar(Sys.which('make')))"; $p -eq 'TRUE'
}
Pop-Location

Step 'Tweede run (herinstalleer / repareer) is idempotent'
Invoke-WithErrorLogging { Invoke-InstallFlow -ProjectRoot $root }
Check '.Renviron heeft precies 1 Rtools-regel' { @((Get-Content "$root\.Renviron") -match '^PATH=.*rtools').Count -eq 1 }
Check 'error.log nog steeds leeg' { -not (Test-Path $Script:ErrorLogPath) }

Step 'Uninstall'
$script:YesNoAnswer = ($Scenario -eq 'clean')   # preexisting: Scoop laten staan
Invoke-WithErrorLogging { Invoke-UninstallFlow -ProjectRoot $root }
Check 'state.json verwijderd' { -not (Test-PreviousSetup) }
Check '.Renviron zonder Rtools-regel' { -not ((Get-Content "$root\.Renviron" -ErrorAction SilentlyContinue) -match 'rtools') }
Check 'customBinaries uit settings.json' {
    $s = Get-Content "$root\.vscode\settings.json" -Raw | ConvertFrom-Json
    -not ($s.PSObject.Properties.Name -contains 'positron.r.customBinaries')
}
foreach ($a in 'r', 'rtools', 'quarto', 'positron') { Check "app '$a' verwijderd" { -not (Test-Path "$scoopApps\$a") } }
if ($Scenario -eq 'clean') {
    Check 'Scoop zelf verwijderd' { -not (Test-Path "$env:USERPROFILE\scoop\shims\scoop.ps1") }
} else {
    Check 'Scoop blijft staan' { Test-Path "$env:USERPROFILE\scoop\shims\scoop.ps1" }
    Check 'vooraf aanwezige git blijft staan' { Test-Path "$scoopApps\git" }
    Check "vooraf aanwezige bucket 'main' werkt nog" { (scoop bucket list | Out-String) -match 'main' }
}

Step 'Resultaat'
$results | Format-Table -AutoSize | Out-String | Write-Host
if (Test-Path $Script:ErrorLogPath) { Write-Host "error.log:"; Get-Content $Script:ErrorLogPath }
$results | ConvertTo-Json | Set-Content "$env:GITHUB_WORKSPACE\results-$Scenario.json"
if ($results.Result -contains 'FAIL') { exit 1 }
