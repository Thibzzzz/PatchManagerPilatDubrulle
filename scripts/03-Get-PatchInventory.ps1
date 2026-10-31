# Partie 3 : correctifs installés sur chaque poste, exportés dans output\PatchesInventory.csv
# -Local affiche seulement les correctifs de la machine locale
param(
    [switch]$Local,
    [System.Management.Automation.PSCredential]$Credential,
    [switch]$Simulation
)

if ($Local) {
    Get-HotFix | Sort-Object InstalledOn -Descending |
        Format-Table @{ n = 'KB'; e = { $_.HotFixID } }, Description,
            @{ n = "Date d'installation"; e = { $_.InstalledOn } },
            @{ n = 'Installé par'; e = { $_.InstalledBy } }
    return
}

Import-Module "$PSScriptRoot\..\modules\PatchManager" -Force
Initialize-PatchManager -Credential $Credential -Simulation:$Simulation
Write-PMLog "Début de l'inventaire des correctifs"

$computers = Get-PMComputer | Test-PMComputer
foreach ($computer in $computers) {
    if ($computer.Status -ne 'Accessible') {
        Write-PMLog $computer.Name, $computer.Status -Level Warning
    }
}

$patches = Get-PMPatchInventory $computers

Write-Host "`n=== Correctifs recensés (par poste, date décroissante) ===" -ForegroundColor Cyan
$patches.Rows | Format-PMDateColumn | Format-Table Poste,
    @{ n = 'Adresse IP'; e = { $_.AdresseIP } }, KB, Description,
    @{ n = "Date d'installation"; e = { $_.DateInstallation } },
    @{ n = 'Installé par'; e = { $_.InstallePar } } | Out-Host

$csv = Get-PMOutputPath 'PatchesInventory.csv'
Export-PMCsv $patches.Rows $csv

Write-Host "=== Synthèse par poste ===" -ForegroundColor Cyan
Get-PMPatchSummary $patches.Rows $computers $patches.Status | Format-PMDateColumn | Format-Table Poste,
    @{ n = 'Adresse IP'; e = { $_.AdresseIP } },
    @{ n = 'État'; e = { $_.Etat } },
    @{ n = 'Nb correctifs'; e = { $_.NbCorrectifs } },
    @{ n = 'Correctif le plus récent'; e = { $_.DernierCorrectif } },
    @{ n = 'Dernier KB'; e = { $_.DernierKB } } | Out-Host

Write-Host "Inventaire des correctifs exporté : $csv" -ForegroundColor Green
Write-PMLog 'Inventaire des correctifs exporté dans PatchesInventory.csv'
