<#
.SYNOPSIS
    Tests automatisés de la logique du module (sans réseau, exécutables partout : pwsh ou Windows PowerShell).
.EXAMPLE
    .\tests\Test-PatchManager.ps1
#>
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'modules\PatchManager') -Force
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("pm-tests-" + [guid]::NewGuid())
New-Item -ItemType Directory $tmp | Out-Null

$script:passed = 0; $script:failed = 0
function Assert([string]$Name, [scriptblock]$Condition) {
    try { $ok = [bool](& $Condition) } catch { $ok = $false; $Name += " (exception : $($_.Exception.Message))" }
    if ($ok) { $script:passed++; Write-Host "[OK]    $Name" -ForegroundColor Green }
    else     { $script:failed++; Write-Host "[ÉCHEC] $Name" -ForegroundColor Red }
}

Initialize-PatchManager -Simulation

# --- Lecture des fichiers d'entrée ---
$f = Join-Path $tmp 'computers.txt'
Set-Content $f -Encoding UTF8 -Value "# commentaire", "pc01;192.168.10.11", "", "PC02 ; 192.168.10.12", "MAUVAISE-LIGNE", "PC09;999.1.1.1"
$computers = @(Get-PMComputer -Path $f 3>$null)
Assert 'computers.txt : 2 postes valides lus, commentaires/lignes invalides ignorés' { $computers.Count -eq 2 }
Assert 'computers.txt : nom normalisé en majuscules et espaces supprimés' { $computers[0].Name -eq 'PC01' -and $computers[1].IP -eq '192.168.10.12' }

$r = Join-Path $tmp 'required.txt'
Set-Content $r -Encoding UTF8 -Value "# politique", "kb5043080  libellé", "5044033", "KB5043080", "texte invalide"
$required = @(Get-PMRequiredPatch -Path $r 3>$null)
Assert 'required-patches.txt : KB normalisées et dédoublonnées' { ($required -join ',') -eq 'KB5043080,KB5044033' }

# --- Disponibilité (simulation) ---
# Parc fictif propre aux tests : indépendant du config\computers.txt du parc réel
$simComputers = Join-Path $tmp 'sim-computers.txt'
Set-Content $simComputers -Encoding UTF8 -Value 'PC01;192.168.10.11', 'PC02;192.168.10.12', 'PC03;192.168.10.13', 'PC04;192.168.10.14'
$avail = @(Get-PMComputer -Path $simComputers | Test-PMComputer)
Assert 'PC01 accessible' { ($avail | Where-Object Name -eq 'PC01').Status -eq 'Accessible' }
Assert 'PC03 injoignable (ni ping ni WinRM)' { ($avail | Where-Object Name -eq 'PC03').Status -eq 'Injoignable' }
Assert 'PC04 "WinRM inaccessible" (ping OK, WinRM KO)' { ($avail | Where-Object Name -eq 'PC04').Status -eq 'WinRM inaccessible' }

# --- Inventaires ---
$inv = @(Get-PMInventory -Availability $avail)
Assert 'Inventaire : une ligne par poste, y compris inaccessibles' { $inv.Count -eq 4 }
Assert "Inventaire : l'erreur d'un poste inaccessible est enregistrée" { ($inv | Where-Object Poste -eq 'PC03').Erreur -ne '' }
Assert 'Inventaire : dernier démarrage converti en date' { ($inv | Where-Object Poste -eq 'PC01').DernierDemarrage -is [datetime] }

$patches = Get-PMPatchInventory -Availability $avail
Assert 'Correctifs : 8 lignes (5 + 3), postes inaccessibles ignorés' { $patches.Rows.Count -eq 8 }
Assert "Correctifs : tri par poste puis date décroissante" {
    $pc1 = @($patches.Rows | Where-Object Poste -eq 'PC01')
    $patches.Rows[0].Poste -eq 'PC01' -and $pc1[0].DateInstallation -ge $pc1[1].DateInstallation -and $null -eq $pc1[-1].DateInstallation
}
$sum = @(Get-PMPatchSummary -Rows $patches.Rows -Availability $avail -Status $patches.Status)
Assert 'Synthèse correctifs : PC01 = 5 correctifs, dernier KB5043080' { $s = $sum | Where-Object Poste -eq 'PC01'; $s.NbCorrectifs -eq 5 -and $s.DernierKB -eq 'KB5043080' }

# --- Conformité ---
$policy = @('KB5043080', 'KB5044033', 'KB5043937')
$comp = @(Test-PMCompliance -Availability $avail -PatchInventory $patches -RequiredPatches $policy)
Assert 'PC01 CONFORME' { ($comp | Where-Object Poste -eq 'PC01').Etat -eq 'CONFORME' }
Assert 'PC02 NON CONFORME, KB5043080 manquante' { $c = $comp | Where-Object Poste -eq 'PC02'; $c.Etat -eq 'NON CONFORME' -and $c.ListeKBManquantes -eq 'KB5043080' }
Assert 'PC03 et PC04 INACCESSIBLE' { @($comp | Where-Object Etat -eq 'INACCESSIBLE').Count -eq 2 }
Assert 'Taux de conformité = 50 % (inaccessibles exclus)' { (Get-PMComplianceRate $comp) -eq 50 }
Assert 'Taux non calculable si aucun poste évalué' { $null -eq (Get-PMComplianceRate @($comp | Where-Object Etat -eq 'INACCESSIBLE')) }
$comp2 = @(Test-PMCompliance -Availability $avail -PatchInventory $patches -RequiredPatches @('KB5044033'))
Assert 'Politique réduite à KB5044033 : PC01 et PC02 conformes' { @($comp2 | Where-Object Etat -eq 'CONFORME').Count -eq 2 }

# --- Rapport et notification ---
$report = New-PMSecurityReport -Inventory $inv -Compliance $comp -Simulation
Assert 'Rapport : fichiers CSV et HTML produits' { (Test-Path $report.CsvPath) -and (Test-Path $report.HtmlPath) }
Assert 'Rapport : synthèse cohérente (4 / 2 / 2 / 1 / 1 / 1)' {
    $s = $report.Summary
    "$($s.TotalPostes)/$($s.PostesAccessibles)/$($s.PostesInaccessibles)/$($s.PostesConformes)/$($s.PostesNonConformes)/$($s.TotalKBManquantes)" -eq '4/2/2/1/1/1'
}
Assert 'Rapport : 3 postes nécessitant une intervention' { $report.ToFix.Count -eq 3 }
Assert 'Rapport HTML : contient la section des interventions' { (Get-Content $report.HtmlPath -Raw) -match 'nécessitant une intervention' }
$okAvail = @($avail | Where-Object { $_.Status -eq 'Accessible' })
$okComp  = @(Test-PMCompliance -Availability $okAvail -PatchInventory $patches -RequiredPatches @('KB5044033'))
$allOk   = New-PMSecurityReport -Inventory @($inv | Where-Object { $_.Etat -eq 'Accessible' }) -Compliance $okComp
Assert 'Rapport : parc 100 % conforme (0 KB manquante, aucune intervention)' { $allOk.Summary.TotalKBManquantes -eq 0 -and $allOk.Summary.TauxConformite -eq 100 -and $allOk.ToFix.Count -eq 0 }
$body = New-PMNotificationBody $report
Assert 'Message : liste PC02 et la KB manquante' { $body -match 'PC02 : NON CONFORME' -and $body -match 'KB5043080 manquante' }

$okReport = [pscustomobject]@{ ToFix = @(); Summary = $report.Summary; HtmlPath = $report.HtmlPath }
Assert 'Aucune anomalie => aucune notification' { (Send-PMNotification -Report $okReport) -eq $false }
Assert 'Anomalie => notification déposée (PickupDirectory)' { (Send-PMNotification -Report $report) -eq $true }
$log = Get-Content (Resolve-PMPath (Get-PMSetting 'LogFile')) -Raw
Assert 'Journal : trace de la notification et de son absence' { $log -match 'Notification envoyée' -and $log -match 'pas de notification' }
Assert 'Journal : format "jj/mm/aaaa hh:mm:ss ; message"' { (Get-Content (Resolve-PMPath (Get-PMSetting 'LogFile')) | Select-Object -Last 1) -match '^\d{2}/\d{2}/\d{4} \d{2}:\d{2}:\d{2} ; ' }

Remove-Item $tmp -Recurse -Force
Write-Host "`n$script:passed test(s) réussi(s), $script:failed échec(s)" -ForegroundColor $(if ($script:failed) { 'Red' } else { 'Green' })
if ($script:failed) { exit 1 }
