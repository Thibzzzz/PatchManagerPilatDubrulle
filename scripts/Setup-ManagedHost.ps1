# Partie 1 : à lancer en administrateur sur chaque poste supervisé
# Exemple : .\Setup-ManagedHost.ps1 -AdminIP 192.168.10.10 -AllowPing
#Requires -RunAsAdministrator
param(
    [Parameter(Mandatory)][string]$AdminIP,
    [switch]$AllowPing
)

# Enable-PSRemoting refuse de configurer le pare-feu si le réseau est en profil Public
Get-NetConnectionProfile | Where-Object NetworkCategory -eq 'Public' | ForEach-Object {
    Set-NetConnectionProfile -InterfaceIndex $_.InterfaceIndex -NetworkCategory Private
}

Enable-PSRemoting -Force
Set-Service WinRM -StartupType Automatic
Start-Service WinRM

# WinRM n'est accepté que depuis le poste d'administration
$rules = Get-NetFirewallRule -DisplayGroup 'Windows Remote Management', 'Gestion à distance de Windows' -ErrorAction SilentlyContinue
foreach ($rule in $rules) {
    if ($rule.Direction -eq 'Inbound' -and $rule.Enabled -eq 'True') {
        Set-NetFirewallRule -Name $rule.Name -RemoteAddress $AdminIP
        Write-Host "Règle '$($rule.DisplayName)' limitée à $AdminIP"
    }
}

if ($AllowPing -and -not (Get-NetFirewallRule -Name 'PatchManager-Ping' -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -Name 'PatchManager-Ping' -DisplayName 'PatchManager - Ping depuis le poste admin' `
        -Protocol ICMPv4 -IcmpType 8 -Direction Inbound -Action Allow -RemoteAddress $AdminIP | Out-Null
}

Get-Service WinRM | Format-Table Name, Status, StartType
winrm enumerate winrm/config/listener
Test-WSMan -ComputerName localhost
