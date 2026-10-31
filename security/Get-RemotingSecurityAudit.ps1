# Partie 7 : qui peut se connecter, quelle authentification est utilisée, et ce que le pare-feu autorise
# Résultat dans output\RemotingSecurityAudit.csv
param(
    [System.Management.Automation.PSCredential]$Credential,
    [switch]$IncludeLocal
)

Import-Module "$PSScriptRoot\..\modules\PatchManager" -Force
Initialize-PatchManager -Credential $Credential

$auditCommand = {
    $admins = (Get-LocalGroupMember -SID 'S-1-5-32-544' | ForEach-Object Name) -join ', '
    $remoteUsers = (Get-LocalGroupMember -SID 'S-1-5-32-580' | ForEach-Object Name) -join ', '
    $endpoints = (Get-PSSessionConfiguration | ForEach-Object { "$($_.Name) : $($_.Permission)" }) -join ' | '
    $auth = (Get-ChildItem WSMan:\localhost\Service\Auth | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join ', '

    $firewall = Get-NetFirewallRule -DisplayGroup 'Windows Remote Management', 'Gestion à distance de Windows' -ErrorAction SilentlyContinue |
        Where-Object { $_.Direction -eq 'Inbound' -and $_.Enabled -eq 'True' } |
        ForEach-Object { "$($_.DisplayName) depuis $(($_ | Get-NetFirewallAddressFilter).RemoteAddress -join ',')" }

    $policy = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -ErrorAction SilentlyContinue

    [pscustomobject]@{
        Poste                         = $env:COMPUTERNAME
        CompteSession                 = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        AuthentificationSession       = [Security.Principal.WindowsIdentity]::GetCurrent().AuthenticationType
        Administrateurs               = $admins
        UtilisateursGestionDistante   = $remoteUsers
        PointsDeTerminaison           = $endpoints
        AuthWinRM                     = $auth
        AllowUnencrypted              = (Get-Item WSMan:\localhost\Service\AllowUnencrypted).Value
        ReglesPareFeu                 = $firewall -join ' | '
        LocalAccountTokenFilterPolicy = $policy.LocalAccountTokenFilterPolicy
    }
}

$results = @()
if ($IncludeLocal) { $results += & $auditCommand }

foreach ($computer in Get-PMComputer | Test-PMComputer) {
    if ($computer.Status -ne 'Accessible') {
        Write-Warning "$($computer.Name) : $($computer.Status)"
        continue
    }
    try {
        $options = @{ ComputerName = $computer.Target; ScriptBlock = $auditCommand; ErrorAction = 'Stop' }
        if ($Credential) { $options.Credential = $Credential }
        $results += Invoke-Command @options | Select-Object * -ExcludeProperty PSComputerName, RunspaceId, PSShowComputerName
    }
    catch {
        Write-Warning "$($computer.Name) : audit impossible - $($_.Exception.Message)"
    }
}

foreach ($result in $results) {
    Write-Host "`n=== $($result.Poste) ===" -ForegroundColor Cyan
    $result | Format-List | Out-Host

    if ($result.AuthentificationSession -match 'NTLM') { Write-Host '  [!] Session en NTLM : préférer Kerberos (domaine) ou HTTPS' -ForegroundColor Yellow }
    if ($result.AuthWinRM -match 'Basic=true') { Write-Host '  [!] Authentification Basic activée' -ForegroundColor Red }
    if ($result.AuthWinRM -match 'CredSSP=true') { Write-Host '  [!] CredSSP activé : le mot de passe est délégué au serveur' -ForegroundColor Red }
    if ($result.AllowUnencrypted -eq 'true') { Write-Host '  [!] Trafic WinRM non chiffré autorisé' -ForegroundColor Red }
    if ($result.ReglesPareFeu -match 'depuis Any') { Write-Host '  [!] WinRM ouvert à toutes les adresses' -ForegroundColor Red }
    if ($result.LocalAccountTokenFilterPolicy -eq 1) { Write-Host '  [!] Les comptes admin locaux sont utilisables à distance' -ForegroundColor Yellow }
}

$csv = Get-PMOutputPath 'RemotingSecurityAudit.csv'
Export-PMCsv $results $csv
Write-Host "`nAudit exporté : $csv" -ForegroundColor Green
