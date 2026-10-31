# PatchManager — Gestion des mises à jour Windows en PowerShell

Solution simplifiée de **Patch Management** pour un parc Windows administré depuis un poste
central via **PowerShell Remoting / WinRM** (projet *Sécurité des systèmes*).

```
computers.txt ─► disponibilité (ICMP, TCP 5985, Test-WSMan) ─► PowerShell Remoting (Invoke-Command)
   ─► inventaire système ─► inventaire des correctifs (Get-HotFix) ─► contrôle de conformité
   ─► rapports CSV / HTML ─► journal PatchManager.log ─► notification si anomalie
```

## Arborescence

| Chemin | Rôle |
|---|---|
| `config/computers.txt` | Inventaire du parc `NOM;IP` |
| `config/required-patches.txt` | Politique : KB obligatoires |
| `config/settings.psd1` | Paramètres (connexion, chemins, notification, rétention) |
| `modules/PatchManager/` | Module commun (toute la logique) |
| `scripts/01-Test-Environment.ps1` | Partie 1 : disponibilité, WinRM, Test-WSMan, Invoke-Command |
| `scripts/Setup-ManagedHost.ps1` | Partie 1 : active le Remoting sur un poste supervisé, pare-feu restreint |
| `scripts/Setup-AdminHost.ps1` | Partie 1 : TrustedHosts sur le poste d'administration (hors domaine) |
| `scripts/02-Get-Inventory.ps1` | Partie 2 : inventaire → `output/Inventory.csv` |
| `scripts/03-Get-PatchInventory.ps1` | Partie 3 : correctifs → `output/PatchesInventory.csv` (`-Local` pour la machine locale) |
| `scripts/04-Test-Compliance.ps1` | Partie 4 : conformité → `output/ComplianceReport.csv` |
| `scripts/Invoke-PatchAudit.ps1` | **Script principal** parties 2 à 6 : rapport CSV/HTML, journal, notification, archive |
| `scripts/New-StoredCredential.ps1` | Identifiants chiffrés DPAPI (aucun mot de passe en clair) |
| `scripts/Register-PatchAuditTask.ps1` | Planification quotidienne |
| `security/Get-RemotingSecurityAudit.ps1` | Partie 7 : qui peut se connecter, authentification, pare-feu |
| `security/New-PatchAuditAccount.ps1` | Partie 7 : compte d'audit non administrateur |
| `security/JEA/Install-PatchAuditJEA.ps1` | Partie 7 : point de terminaison JEA `PatchAudit` |
| `security/Protect-PatchManagerOutput.ps1` | Partie 7 : ACL, intégrité SHA-256, rétention |
| `tests/Test-PatchManager.ps1` | 28 tests automatisés (mode simulation) |
| `tests/simulation.json` | Parc fictif pour les tests |
| `docs/RAPPORT.md` | Rapport du projet (réponses aux questions incluses) |

## Démarrage rapide

```powershell
# 0. Autoriser les scripts locaux (une fois, en administrateur)
Set-ExecutionPolicy RemoteSigned -Scope LocalMachine
Get-ChildItem -Recurse -Filter *.ps1 | Unblock-File   # si le projet a été téléchargé en .zip

# 1. Essai sans réseau : parc fictif
.\tests\Test-PatchManager.ps1
.\scripts\Invoke-PatchAudit.ps1 -Simulation -OpenReport

# 2. Sur chaque poste supervisé (administrateur)
.\scripts\Setup-ManagedHost.ps1 -AdminIP 192.168.10.10 -AllowPing

# 3. Sur le poste d'administration (administrateur, hors domaine)
.\scripts\Setup-AdminHost.ps1

# 4. Audit réel
$cred = Get-Credential            # compte admin local des postes (ou svc_patchaudit avec JEA)
.\scripts\01-Test-Environment.ps1 -Credential $cred
.\scripts\Invoke-PatchAudit.ps1   -Credential $cred -OpenReport
```

Compatible **Windows PowerShell 5.1** et **PowerShell 7**. Les fichiers `.ps1` sont encodés en
UTF-8 avec BOM pour que les accents s'affichent correctement sous Windows PowerShell 5.1.

Les résultats (`output/`) ne sont **pas** versionnés : ils décrivent l'état de sécurité du parc.
