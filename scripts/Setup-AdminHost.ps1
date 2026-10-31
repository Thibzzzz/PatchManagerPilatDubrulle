# Partie 1 : à lancer en administrateur sur le poste d'administration (hors domaine)
# Sans Kerberos, WinRM n'accepte que les machines listées dans TrustedHosts : on y met uniquement le parc
#Requires -RunAsAdministrator

Import-Module "$PSScriptRoot\..\modules\PatchManager" -Force
Initialize-PatchManager

Start-Service WinRM

$targets = Get-PMComputer | ForEach-Object {
    if ((Get-PMSetting 'ConnectBy') -eq 'Name') { $_.Name } else { $_.IP }
}
Set-Item WSMan:\localhost\Client\TrustedHosts -Value ($targets -join ',') -Force

Write-Host "TrustedHosts = $((Get-Item WSMan:\localhost\Client\TrustedHosts).Value)"
