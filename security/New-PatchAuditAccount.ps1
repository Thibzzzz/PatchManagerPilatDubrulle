# Partie 7 : compte dédié à l'audit, sans droits d'administrateur
# À lancer en administrateur sur chaque poste supervisé. Le groupe PatchAuditors n'a accès qu'au point JEA "PatchAudit".
#Requires -RunAsAdministrator
param(
    [string]$UserName = 'svc_patchaudit',
    [string]$GroupName = 'PatchAuditors'
)

if (-not (Get-LocalGroup -Name $GroupName -ErrorAction SilentlyContinue)) {
    New-LocalGroup -Name $GroupName -Description 'Accès au point de terminaison JEA PatchAudit' | Out-Null
}

if (-not (Get-LocalUser -Name $UserName -ErrorAction SilentlyContinue)) {
    $password = Read-Host -AsSecureString "Mot de passe pour $UserName"
    New-LocalUser -Name $UserName -Password $password -PasswordNeverExpires -Description 'Compte d''audit Patch Management' | Out-Null
}

Add-LocalGroupMember -Group $GroupName -Member $UserName -ErrorAction SilentlyContinue

# Le compte ne doit être ni administrateur ni utilisateur de gestion à distance
foreach ($sid in 'S-1-5-32-544', 'S-1-5-32-580') {
    $group = Get-LocalGroup -SID $sid
    if (Get-LocalGroupMember -Group $group | Where-Object Name -like "*\$UserName") {
        Write-Warning "$UserName est membre de '$($group.Name)' : il faut le retirer."
    }
}

Get-LocalGroupMember -Group $GroupName
