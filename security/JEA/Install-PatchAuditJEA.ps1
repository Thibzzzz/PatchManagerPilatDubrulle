# Partie 7 : point de terminaison JEA "PatchAudit"
# Le groupe PatchAuditors ne peut lancer que deux fonctions de lecture (inventaire et correctifs),
# sous un compte virtuel temporaire, et chaque session est enregistrée.
# -Deploy installe le point de terminaison sur tous les postes accessibles de computers.txt.
# Ensuite, mettre JEAConfigurationName = 'PatchAudit' dans config\settings.psd1.
param(
    [switch]$Deploy,
    [System.Management.Automation.PSCredential]$Credential,
    [string]$GroupName = 'PatchAuditors'
)

Import-Module "$PSScriptRoot\..\..\modules\PatchManager" -Force
Initialize-PatchManager -Credential $Credential

# Les mêmes commandes que celles du module, envoyées sous forme de texte
$functions = @{}
foreach ($entry in (Get-PMRemoteBlock).GetEnumerator()) {
    $functions[$entry.Key] = $entry.Value.ToString()
}

$install = {
    param($Functions, $GroupName)

    $moduleFolder = "$env:ProgramFiles\WindowsPowerShell\Modules\PatchAuditJEA"
    New-Item -ItemType Directory -Path "$moduleFolder\RoleCapabilities" -Force | Out-Null
    New-ModuleManifest -Path "$moduleFolder\PatchAuditJEA.psd1"

    if (-not (Get-LocalGroup -Name $GroupName -ErrorAction SilentlyContinue)) {
        New-LocalGroup -Name $GroupName | Out-Null
    }

    $definitions = foreach ($name in $Functions.Keys) {
        @{ Name = $name; ScriptBlock = [scriptblock]::Create($Functions[$name]) }
    }

    New-PSRoleCapabilityFile -Path "$moduleFolder\RoleCapabilities\PatchAuditor.psrc" `
        -VisibleFunctions ([string[]]$Functions.Keys) `
        -FunctionDefinitions $definitions `
        -VisibleCmdlets 'Get-HotFix',
            @{ Name = 'Get-CimInstance'; Parameters = @{ Name = 'ClassName'; ValidateSet = 'Win32_ComputerSystem', 'Win32_BIOS', 'Win32_OperatingSystem', 'Win32_LogicalDisk' }, @{ Name = 'Filter' } },
            @{ Name = 'Get-Service'; Parameters = @{ Name = 'Name'; ValidateSet = 'wuauserv', 'WinRM' } }

    $configFile = "$env:ProgramData\PatchAudit.pssc"
    New-PSSessionConfigurationFile -Path $configFile `
        -SessionType RestrictedRemoteServer `
        -RunAsVirtualAccount `
        -TranscriptDirectory "$env:ProgramData\JEATranscripts" `
        -RoleDefinitions @{ "$env:COMPUTERNAME\$GroupName" = @{ RoleCapabilities = 'PatchAuditor' } }

    if (Get-PSSessionConfiguration -Name PatchAudit -ErrorAction SilentlyContinue) {
        Unregister-PSSessionConfiguration -Name PatchAudit -NoServiceRestart
    }
    Register-PSSessionConfiguration -Name PatchAudit -Path $configFile -NoServiceRestart -Force | Out-Null

    # Le redémarrage de WinRM coupe la session en cours, il est donc lancé quelques secondes plus tard
    Start-Process powershell.exe -WindowStyle Hidden -ArgumentList '-NoProfile -Command "Start-Sleep 3; Restart-Service WinRM"'
    "$env:COMPUTERNAME : point de terminaison PatchAudit installé"
}

if ($Deploy) {
    foreach ($computer in Get-PMComputer | Test-PMComputer) {
        if ($computer.Status -ne 'Accessible') {
            Write-Warning "$($computer.Name) ignoré : $($computer.Status)"
            continue
        }
        try {
            $options = @{ ComputerName = $computer.Target; ScriptBlock = $install; ArgumentList = $functions, $GroupName; ErrorAction = 'Stop' }
            if ($Credential) { $options.Credential = $Credential }
            Invoke-Command @options
        }
        catch {
            Write-Warning "$($computer.Name) : échec - $($_.Exception.Message)"
        }
    }
}
else {
    & $install $functions $GroupName
}

Write-Host @'

Test depuis le poste d'administration avec le compte svc_patchaudit :
  $c = Get-Credential PC01\svc_patchaudit
  Invoke-Command 192.168.10.11 -ConfigurationName PatchAudit -Credential $c { Get-Command }
  Invoke-Command 192.168.10.11 -ConfigurationName PatchAudit -Credential $c { Get-PMRemoteHotFix }
  Invoke-Command 192.168.10.11 -ConfigurationName PatchAudit -Credential $c { Stop-Service wuauserv }   # refusé
'@
