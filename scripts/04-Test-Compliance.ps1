# Partie 4 : comparaison avec required-patches.txt, résultat dans output\ComplianceReport.csv
param(
    [System.Management.Automation.PSCredential]$Credential,
    [switch]$Simulation
)

Import-Module "$PSScriptRoot\..\modules\PatchManager" -Force
Initialize-PatchManager -Credential $Credential -Simulation:$Simulation
Write-PMLog 'Début du contrôle de conformité'

$required = Get-PMRequiredPatch
Write-Host "Politique : $($required.Count) correctif(s) obligatoire(s) : $($required -join ', ')" -ForegroundColor Cyan

$computers = Get-PMComputer | Test-PMComputer
$patches = Get-PMPatchInventory $computers
$compliance = Test-PMCompliance $computers $patches $required

Write-Host "`nContrôle du $(Format-PMDate $compliance[0].DateControle)"
$compliance | Format-Table Poste,
    @{ n = 'KB requises'; e = { $_.KBRequises } },
    @{ n = 'KB manquantes'; e = { if ($null -eq $_.KBManquantes) { '—' } else { $_.KBManquantes } } },
    @{ n = 'État'; e = { $_.Etat } } | Out-Host

foreach ($result in $compliance) {
    if ($result.Etat -eq 'NON CONFORME') {
        Write-Host "$($result.Poste) : NON CONFORME - correctifs manquants : $($result.ListeKBManquantes)" -ForegroundColor Red
    }
    if ($result.ListeKBManquantes) { Write-PMLog $result.Poste, $result.Etat, $result.ListeKBManquantes }
    else { Write-PMLog $result.Poste, $result.Etat }
}

$rate = Get-PMComplianceRate $compliance
if ($null -eq $rate) { $rate = 'n/a' } else { $rate = "$rate %" }
Write-Host "Taux global de conformité (hors inaccessibles) : $rate" -ForegroundColor Cyan

$csv = Get-PMOutputPath 'ComplianceReport.csv'
Export-PMCsv $compliance $csv
Write-Host "Résultats exportés : $csv" -ForegroundColor Green
