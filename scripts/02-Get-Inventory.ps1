# Partie 2 : inventaire du parc, exporté dans output\Inventory.csv
param(
    [System.Management.Automation.PSCredential]$Credential,
    [switch]$Simulation
)

Import-Module "$PSScriptRoot\..\modules\PatchManager" -Force
Initialize-PatchManager -Credential $Credential -Simulation:$Simulation
Write-PMLog "Début de l'inventaire du parc"

$computers = Get-PMComputer | Test-PMComputer
foreach ($computer in $computers) {
    Write-PMLog $computer.Name, $computer.Status
}

$inventory = Get-PMInventory $computers

$inventory | Format-PMDateColumn | Format-Table Poste,
    @{ n = 'Adresse IP'; e = { $_.AdresseIP } }, Windows, Architecture,
    @{ n = 'Dernier démarrage'; e = { $_.DernierDemarrage } },
    @{ n = 'Windows Update'; e = { $_.WindowsUpdate } },
    @{ n = 'État'; e = { $_.Etat } } | Out-Host

$inventory | Format-PMDateColumn | Format-Table Poste, Modele, BIOS,
    @{ n = 'RAM (Go)'; e = { $_.RAM_Go } },
    @{ n = 'Libre (Go)'; e = { $_.DisqueLibre_Go } },
    @{ n = 'Nb MAJ'; e = { $_.NbMisesAJour } },
    @{ n = 'Dernière MAJ'; e = { $_.DerniereMiseAJour } }, Erreur | Out-Host

$csv = Get-PMOutputPath 'Inventory.csv'
Export-PMCsv $inventory $csv
Write-Host "Inventaire exporté : $csv" -ForegroundColor Green
Write-PMLog 'Inventaire exporté dans Inventory.csv'
