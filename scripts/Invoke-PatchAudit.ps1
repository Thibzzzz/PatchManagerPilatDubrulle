# Script principal : audit complet du parc (parties 2 à 6)
# Exemples : .\Invoke-PatchAudit.ps1 -Simulation
#            .\Invoke-PatchAudit.ps1 -Credential (Get-Credential) -OpenReport
param(
    [System.Management.Automation.PSCredential]$Credential,
    [switch]$NoNotification,
    [switch]$Simulation,
    [switch]$OpenReport
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Import-Module "$PSScriptRoot\..\modules\PatchManager" -Force
Initialize-PatchManager -Credential $Credential -Simulation:$Simulation

Write-PMLog "Début de l'audit"
try {
    $required = Get-PMRequiredPatch
    $computers = Get-PMComputer
    Write-Host "Parc : $($computers.Count) poste(s) - politique : $($required.Count) KB obligatoire(s)" -ForegroundColor Cyan

    # Disponibilité
    $computers = $computers | Test-PMComputer
    foreach ($computer in $computers) {
        if ($computer.Status -eq 'Accessible') { Write-PMLog $computer.Name, $computer.Status }
        else { Write-PMLog $computer.Name, $computer.Status -Level Warning }
    }

    # Inventaire, correctifs et conformité
    $inventory = Get-PMInventory $computers
    Export-PMCsv $inventory (Get-PMOutputPath 'Inventory.csv')

    $patches = Get-PMPatchInventory $computers
    Export-PMCsv $patches.Rows (Get-PMOutputPath 'PatchesInventory.csv')

    $compliance = Test-PMCompliance $computers $patches $required
    Export-PMCsv $compliance (Get-PMOutputPath 'ComplianceReport.csv')

    foreach ($result in $compliance) {
        if ($result.Etat -eq 'CONFORME') {
            Write-PMLog $result.Poste, 'Conforme'
        }
        elseif ($result.Etat -eq 'NON CONFORME') {
            Write-PMLog $result.Poste, 'Non conforme', $result.ListeKBManquantes -Level Warning
        }
        else {
            Write-PMLog $result.Poste, 'Inaccessible', $result.Detail -Level Warning
        }
    }

    # Rapport
    $report = New-PMSecurityReport $inventory $compliance -Simulation:$Simulation
    Write-PMLog 'Rapport généré', (Split-Path $report.HtmlPath -Leaf)

    $s = $report.Summary
    if ($null -eq $s.TauxConformite) { $rate = 'n/a' } else { $rate = "$($s.TauxConformite) %" }

    Write-Host "`n=== Synthèse du parc ===" -ForegroundColor Cyan
    Write-Host "Nombre total de postes                : $($s.TotalPostes)"
    Write-Host "Nombre de postes accessibles          : $($s.PostesAccessibles)"
    Write-Host "Nombre de postes inaccessibles        : $($s.PostesInaccessibles)"
    Write-Host "Nombre de postes conformes            : $($s.PostesConformes)"
    Write-Host "Nombre de postes non conformes        : $($s.PostesNonConformes)"
    Write-Host "Nombre total de correctifs manquants  : $($s.TotalKBManquantes)"
    Write-Host "Taux de conformité                    : $rate"

    Write-Host "`n=== Postes nécessitant une intervention ===" -ForegroundColor Cyan
    if ($report.ToFix.Count -gt 0) {
        $report.ToFix | Format-Table Poste, AdresseIP, Conformite, KBManquantes, Remarque | Out-Host
    }
    else {
        Write-Host 'Aucun.' -ForegroundColor Green
    }

    $report.Rows | Format-PMDateColumn | Format-Table Poste, AdresseIP, Accessibilite, Windows,
        DernierDemarrage, WindowsUpdate, NbKBRequises, NbKBManquantes, Conformite | Out-Host

    # Notification uniquement si un poste pose problème
    if (-not $NoNotification) {
        Send-PMNotification $report | Out-Null
    }

    # Copie horodatée de l'audit avec l'empreinte SHA-256 de chaque fichier (partie 7)
    $archive = Join-Path (Resolve-PMPath (Get-PMSetting 'ArchiveDirectory')) (Get-Date $s.DateControle -Format 'yyyyMMdd_HHmmss')
    New-Item -ItemType Directory -Path $archive -Force | Out-Null
    foreach ($file in 'Inventory.csv', 'PatchesInventory.csv', 'ComplianceReport.csv') {
        Copy-Item (Get-PMOutputPath $file) $archive
    }
    Copy-Item $report.CsvPath, $report.HtmlPath $archive

    $hashes = Get-ChildItem $archive -File | Get-FileHash -Algorithm SHA256
    $hashes | ForEach-Object { "$($_.Hash)  $(Split-Path $_.Path -Leaf)" } | Set-Content "$archive\SHA256SUMS.txt" -Encoding UTF8

    Write-Host "`nRapport HTML : $($report.HtmlPath)" -ForegroundColor Green
    if ($OpenReport) { Invoke-Item $report.HtmlPath }
}
catch {
    Write-PMLog 'ERREUR', "Audit interrompu : $($_.Exception.Message)" -Level Error
    throw
}
finally {
    Write-PMLog "Fin de l'audit"
}
