# Lance l'audit complet tous les jours à l'heure choisie (tâche planifiée Windows)
# Le compte d'exécution doit créer lui-même ses fichiers d'identifiants avec New-StoredCredential.ps1
#Requires -RunAsAdministrator
param(
    [Parameter(Mandatory)][string]$RunAsUser,
    [string]$At = '07:30'
)

$script = Join-Path $PSScriptRoot 'Invoke-PatchAudit.ps1'
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy RemoteSigned -File `"$script`""
$trigger = New-ScheduledTaskTrigger -Daily -At $At
$account = Get-Credential -UserName $RunAsUser -Message "Compte d'exécution de la tâche"

Register-ScheduledTask -TaskName 'PatchManager - Audit quotidien' -Action $action -Trigger $trigger `
    -User $account.UserName -Password $account.GetNetworkCredential().Password -RunLevel Limited -Force
