# Partie 1 : disponibilité des postes de computers.txt et test de PowerShell Remoting
param(
    [System.Management.Automation.PSCredential]$Credential,
    [switch]$Simulation
)

Import-Module "$PSScriptRoot\..\modules\PatchManager" -Force
Initialize-PatchManager -Credential $Credential -Simulation:$Simulation

if (-not $Simulation) {
    Write-Host "`n=== Poste d'administration ===" -ForegroundColor Cyan
    Get-Service WinRM | Format-Table Name, Status, StartType | Out-Host
    Write-Host "TrustedHosts : $((Get-Item WSMan:\localhost\Client\TrustedHosts).Value)"
}

Write-Host "`n=== Disponibilité des postes (computers.txt) ===" -ForegroundColor Cyan
$computers = Get-PMComputer | Test-PMComputer

$computers | Format-Table @{ n = 'Poste'; e = { $_.Name } },
    @{ n = 'Adresse IP'; e = { $_.IP } },
    @{ n = 'Ping'; e = { if ($_.Ping) { 'OK' } else { 'KO' } } },
    @{ n = 'Port WinRM'; e = { if ($_.WinRMPort) { 'Ouvert' } else { 'Fermé' } } },
    @{ n = 'Test-WSMan'; e = { if ($_.WSMan) { 'OK' } else { 'KO' } } },
    @{ n = 'État'; e = { $_.Status } } | Out-Host

Write-Host "=== Exécution distante non interactive (Invoke-Command) ===" -ForegroundColor Cyan
$testCommand = {
    "$env:COMPUTERNAME - $((Get-CimInstance Win32_OperatingSystem).Caption) - WinRM $((Get-Service WinRM).Status)"
}

foreach ($computer in $computers) {
    if ($computer.Status -ne 'Accessible') {
        Write-Host "[$($computer.Name)] ignoré ($($computer.Status)) : $($computer.Error)" -ForegroundColor Yellow
        continue
    }
    try {
        $answer = Invoke-PMRemote $computer $testCommand 'Get-PMRemoteInventory' 'Inventory'
        if ($Simulation) { $answer = "$($answer.ComputerName) - $($answer.OSCaption) - WinRM Running" }
        Write-Host "[$($computer.Name)] OK : $answer" -ForegroundColor Green
    }
    catch {
        Write-Host "[$($computer.Name)] ÉCHEC : $($_.Exception.Message)" -ForegroundColor Red
    }
}

Write-Host "`nPour une session interactive :" -ForegroundColor Cyan
Write-Host '  Enter-PSSession -ComputerName <IP> -Credential (Get-Credential)'
