# Partie 7 : protection des rapports et journaux
#   -Apply     droits limités sur config\ et output\ + audit des suppressions
#   -Verify    vérifie les empreintes SHA-256 de chaque audit archivé
#   -Retention compresse en lecture seule les archives plus vieilles que RetentionDays
# Exemple : .\Protect-PatchManagerOutput.ps1 -Apply -RunAsAccount 'PCADMIN\svc_patchaudit'
#Requires -RunAsAdministrator
param(
    [switch]$Apply,
    [string]$RunAsAccount,
    [switch]$Verify,
    [switch]$Retention
)

Import-Module "$PSScriptRoot\..\modules\PatchManager" -Force
Initialize-PatchManager

$folders = (Resolve-PMPath 'config'), (Resolve-PMPath (Get-PMSetting 'OutputDirectory'))
$archiveFolder = Resolve-PMPath (Get-PMSetting 'ArchiveDirectory')

if ($Apply) {
    foreach ($folder in $folders) {
        # Administrateurs et SYSTEM en contrôle total, compte d'exécution en modification, personne d'autre
        $rights = '*S-1-5-32-544:(OI)(CI)F', '*S-1-5-18:(OI)(CI)F'
        if ($RunAsAccount) { $rights += "${RunAsAccount}:(OI)(CI)M" }
        icacls $folder /inheritance:r /grant:r $rights | Out-Null

        $acl = Get-Acl $folder
        $auditRule = New-Object System.Security.AccessControl.FileSystemAuditRule('Everyone',
            'Delete,DeleteSubdirectoriesAndFiles,WriteData,ChangePermissions', 'ContainerInherit,ObjectInherit', 'None', 'Success,Failure')
        $acl.AddAuditRule($auditRule)
        Set-Acl -Path $folder -AclObject $acl
        Write-Host "Droits restreints sur $folder" -ForegroundColor Green
    }
    # Active l'audit "Système de fichiers" pour que les suppressions apparaissent dans le journal Sécurité
    auditpol /set /subcategory:"{0CCE921D-69AE-11D9-BED3-505054503030}" /success:enable /failure:enable | Out-Null
}

if ($Verify) {
    foreach ($audit in Get-ChildItem $archiveFolder -Directory) {
        $hashFile = Join-Path $audit.FullName 'SHA256SUMS.txt'
        if (-not (Test-Path $hashFile)) {
            Write-Warning "$($audit.Name) : pas de fichier d'empreintes"
            continue
        }

        $altered = @()
        foreach ($line in Get-Content $hashFile) {
            $hash, $name = $line -split '\s+', 2
            $file = Join-Path $audit.FullName $name
            if (-not (Test-Path $file) -or (Get-FileHash $file -Algorithm SHA256).Hash -ne $hash) {
                $altered += $name
            }
        }

        if ($altered.Count -gt 0) {
            Write-Host "$($audit.Name) : ALTÉRÉ ou supprimé -> $($altered -join ', ')" -ForegroundColor Red
            Write-PMLog 'ERREUR', "Intégrité de l'archive $($audit.Name)", ($altered -join ', ') -Level Error
        }
        else {
            Write-Host "$($audit.Name) : intègre" -ForegroundColor Green
        }
    }
}

if ($Retention) {
    $limit = (Get-Date).AddDays(-(Get-PMSetting 'RetentionDays'))
    foreach ($audit in Get-ChildItem $archiveFolder -Directory | Where-Object CreationTime -lt $limit) {
        $zip = "$($audit.FullName).zip"
        Compress-Archive -Path "$($audit.FullName)\*" -DestinationPath $zip -Force
        Set-ItemProperty $zip -Name IsReadOnly -Value $true
        Remove-Item $audit.FullName -Recurse -Force
        Write-PMLog "Archive $($audit.Name) compressée (rétention)"
    }
}

foreach ($folder in $folders) {
    Write-Host "`n$folder" -ForegroundColor Cyan
    (Get-Acl $folder).Access | Format-Table IdentityReference, FileSystemRights, AccessControlType | Out-Host
}
