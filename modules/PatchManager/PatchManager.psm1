# Module PatchManager : fonctions communes à tous les scripts du projet

$ProjectRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$Settings = $null
$Simulation = $null
$Credential = $null
$ProgressPreference = 'SilentlyContinue'


# ---------- Configuration ----------

function Resolve-PMPath($Path) {
    if ([System.IO.Path]::IsPathRooted($Path)) { return $Path }
    $Path = $Path -replace '[\\/]', [System.IO.Path]::DirectorySeparatorChar
    return Join-Path $ProjectRoot $Path
}

function Initialize-PatchManager {
    param(
        [System.Management.Automation.PSCredential]$Credential,
        [switch]$Simulation
    )

    $script:Settings = Import-PowerShellDataFile (Resolve-PMPath 'config\settings.psd1')

    foreach ($folder in $Settings.OutputDirectory, $Settings.ArchiveDirectory) {
        $path = Resolve-PMPath $folder
        if (-not (Test-Path $path)) { New-Item -ItemType Directory -Path $path | Out-Null }
    }

    if ($Credential) {
        $script:Credential = $Credential
    }
    elseif ($Settings.CredentialFile) {
        $script:Credential = Import-Clixml (Resolve-PMPath $Settings.CredentialFile)
    }
    else {
        $script:Credential = $null
    }

    $script:Simulation = $null
    if ($Simulation) {
        $data = Get-Content (Resolve-PMPath 'tests\simulation.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $script:Simulation = @{}
        foreach ($machine in $data.Machines) {
            $script:Simulation[$machine.Name] = $machine
        }
        Write-Host '*** MODE SIMULATION : aucune connexion réseau, données de tests\simulation.json ***' -ForegroundColor Magenta
    }
}

function Get-PMSetting($Name) {
    if (-not $Settings) { Initialize-PatchManager }
    return $Settings[$Name]
}

function Get-PMOutputPath($FileName) {
    return Join-Path (Resolve-PMPath (Get-PMSetting 'OutputDirectory')) $FileName
}


# ---------- Journal ----------

function Write-PMLog {
    param(
        [string[]]$Message,
        [string]$Level = 'Info'
    )
    $date = Get-Date -Format 'dd/MM/yyyy HH:mm:ss'
    $line = "$date ; " + ($Message -join ' ; ')
    Add-Content -Path (Resolve-PMPath (Get-PMSetting 'LogFile')) -Value $line -Encoding UTF8

    if ($Level -eq 'Error') { Write-Host $line -ForegroundColor Red }
    if ($Level -eq 'Warning') { Write-Host $line -ForegroundColor Yellow }
}


# ---------- Fichiers d'entrée ----------

function Get-PMComputer {
    param([string]$Path = (Resolve-PMPath (Get-PMSetting 'ComputersFile')))

    $computers = @()
    foreach ($line in Get-Content $Path -Encoding UTF8) {
        $line = $line.Trim()
        if ($line -eq '' -or $line.StartsWith('#')) { continue }

        $parts = $line.Split(';')
        $ip = $null
        if ($parts.Count -lt 2 -or -not [System.Net.IPAddress]::TryParse($parts[1].Trim(), [ref]$ip)) {
            Write-Warning "Ligne ignorée dans computers.txt : $line"
            continue
        }

        $computers += [pscustomobject]@{
            Name = $parts[0].Trim().ToUpper()
            IP   = $parts[1].Trim()
        }
    }
    return $computers
}

function ConvertTo-PMKB($Text) {
    # Accepte "KB5043080", "kb5043080" ou "5043080"
    if ($Text -match '^(KB)?(\d{6,8})$') { return 'KB' + $Matches[2] }
    return $null
}

function Get-PMRequiredPatch {
    param([string]$Path = (Resolve-PMPath (Get-PMSetting 'RequiredPatchesFile')))

    $patches = @()
    foreach ($line in Get-Content $Path -Encoding UTF8) {
        $line = $line.Trim()
        if ($line -eq '' -or $line.StartsWith('#')) { continue }

        $kb = ConvertTo-PMKB ($line.Split(' ')[0].ToUpper())
        if (-not $kb) {
            Write-Warning "Ligne ignorée dans required-patches.txt : $line"
        }
        elseif ($patches -notcontains $kb) {
            $patches += $kb
        }
    }
    return $patches
}


# ---------- Disponibilité des postes ----------

function Test-PMTcpPort($Address, $Port) {
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $connection = $client.ConnectAsync($Address, $Port)
        return $connection.Wait(1500) -and $client.Connected
    }
    catch {
        return $false
    }
    finally {
        $client.Dispose()
    }
}

function Test-PMComputer {
    param([Parameter(ValueFromPipeline)]$Computer)

    process {
        if ((Get-PMSetting 'ConnectBy') -eq 'Name') { $target = $Computer.Name } else { $target = $Computer.IP }
        $port = 5985
        if (Get-PMSetting 'UseSSL') { $port = 5986 }

        $ping = $false
        $portOpen = $false
        $wsman = $false

        if ($Simulation) {
            $machine = $Simulation[$Computer.Name]
            $ping = [bool]$machine.Ping
            $portOpen = [bool]$machine.WinRM
            $wsman = [bool]$machine.WinRM
        }
        else {
            $ping = Test-Connection -ComputerName $target -Count 1 -Quiet -ErrorAction SilentlyContinue
            $portOpen = Test-PMTcpPort $target $port
            if ($portOpen) {
                try {
                    Test-WSMan -ComputerName $target -UseSSL:(Get-PMSetting 'UseSSL') -ErrorAction Stop | Out-Null
                    $wsman = $true
                }
                catch { }
            }
        }

        # Le ping est souvent bloqué par le pare-feu : c'est Test-WSMan qui décide
        if ($wsman) {
            $status = 'Accessible'
            $errorText = ''
        }
        elseif ($ping -or $portOpen) {
            $status = 'WinRM inaccessible'
            $errorText = "Le poste répond mais WinRM n'est pas joignable (service arrêté, Remoting désactivé ou pare-feu)"
        }
        else {
            $status = 'Injoignable'
            $errorText = 'Aucune réponse ICMP ni WinRM (poste éteint, adresse erronée ou réseau)'
        }

        [pscustomobject]@{
            Name      = $Computer.Name
            IP        = $Computer.IP
            Target    = $target
            Ping      = [bool]$ping
            WinRMPort = $portOpen
            WSMan     = $wsman
            Status    = $status
            Error     = $errorText
        }
    }
}


# ---------- Commandes exécutées sur les postes distants ----------

$RemoteInventoryBlock = {
    $computer = Get-CimInstance Win32_ComputerSystem
    $bios = Get-CimInstance Win32_BIOS
    $os = Get-CimInstance Win32_OperatingSystem
    $disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$env:SystemDrive'"
    $hotfixes = @(Get-HotFix -ErrorAction SilentlyContinue | Where-Object { $_.InstalledOn } | Sort-Object InstalledOn -Descending)
    $service = Get-Service wuauserv -ErrorAction SilentlyContinue

    try { $displayVersion = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').DisplayVersion }
    catch { $displayVersion = '' }

    $lastDate = $null
    $lastKB = $null
    if ($hotfixes.Count -gt 0) {
        $lastDate = $hotfixes[0].InstalledOn
        $lastKB = $hotfixes[0].HotFixID
    }

    [pscustomobject]@{
        ComputerName       = $env:COMPUTERNAME
        Manufacturer       = $computer.Manufacturer
        Model              = $computer.Model
        BiosVersion        = $bios.SMBIOSBIOSVersion
        OSCaption          = $os.Caption
        OSBuild            = $os.BuildNumber
        OSDisplayVersion   = $displayVersion
        Architecture       = $os.OSArchitecture
        LastBootUpTime     = $os.LastBootUpTime
        RamGB              = [math]::Round($computer.TotalPhysicalMemory / 1GB, 1)
        SystemDrive        = $env:SystemDrive
        DiskFreeGB         = [math]::Round($disk.FreeSpace / 1GB, 1)
        HotFixCount        = @(Get-HotFix -ErrorAction SilentlyContinue).Count
        LastHotFixDate     = $lastDate
        LastHotFixId       = $lastKB
        WUServiceStatus    = [string]$service.Status
        WUServiceStartType = [string]$service.StartType
    }
}

$RemoteHotFixBlock = {
    Get-HotFix | Select-Object HotFixID, Description, InstalledOn, InstalledBy
}

function Get-PMRemoteBlock {
    # Utilisé par l'installation JEA pour publier les mêmes commandes
    return @{
        'Get-PMRemoteInventory' = $RemoteInventoryBlock
        'Get-PMRemoteHotFix'    = $RemoteHotFixBlock
    }
}

function Invoke-PMRemote {
    param($Computer, [scriptblock]$ScriptBlock, [string]$JEACommand, [string]$SimulationProperty)

    if ($Simulation) {
        return $Simulation[$Computer.Name].$SimulationProperty
    }

    $options = @{ ComputerName = $Computer.Target; ErrorAction = 'Stop'; ScriptBlock = $ScriptBlock }
    if ($Credential) { $options.Credential = $Credential }
    if (Get-PMSetting 'UseSSL') { $options.UseSSL = $true }

    # Avec JEA on ne peut pas envoyer de script : on appelle la fonction autorisée par son nom
    $jea = Get-PMSetting 'JEAConfigurationName'
    if ($jea) {
        $options.ConfigurationName = $jea
        $options.ScriptBlock = [scriptblock]::Create($JEACommand)
    }

    Invoke-Command @options
}

function ConvertTo-PMDate($Value) {
    if (-not $Value) { return $null }
    if ($Value -is [datetime]) { return $Value }
    return [datetime]::Parse($Value, [Globalization.CultureInfo]::InvariantCulture)
}


# ---------- Partie 2 : inventaire du parc ----------

function Get-PMInventory {
    param([object[]]$Availability)

    foreach ($computer in $Availability) {
        $row = [pscustomobject]@{
            Poste             = $computer.Name
            AdresseIP         = $computer.IP
            Etat              = $computer.Status
            NomReel           = $null
            Fabricant         = $null
            Modele            = $null
            BIOS              = $null
            Windows           = $null
            VersionWindows    = $null
            Architecture      = $null
            DernierDemarrage  = $null
            RAM_Go            = $null
            DisqueSysteme     = $null
            DisqueLibre_Go    = $null
            NbMisesAJour      = $null
            DerniereMiseAJour = $null
            DernierKB         = $null
            WindowsUpdate     = $null
            WUTypeDemarrage   = $null
            DateControle      = Get-Date
            Erreur            = $computer.Error
        }

        if ($computer.Status -eq 'Accessible') {
            try {
                $info = Invoke-PMRemote $computer $RemoteInventoryBlock 'Get-PMRemoteInventory' 'Inventory'

                $row.NomReel = $info.ComputerName
                $row.Fabricant = $info.Manufacturer
                $row.Modele = $info.Model
                $row.BIOS = $info.BiosVersion
                $row.Windows = $info.OSCaption -replace '^Microsoft ', ''
                $row.VersionWindows = "$($info.OSDisplayVersion) (build $($info.OSBuild))".Trim()
                $row.Architecture = $info.Architecture -replace '-bit', ' bits'
                $row.DernierDemarrage = ConvertTo-PMDate $info.LastBootUpTime
                $row.RAM_Go = $info.RamGB
                $row.DisqueSysteme = $info.SystemDrive
                $row.DisqueLibre_Go = $info.DiskFreeGB
                $row.NbMisesAJour = $info.HotFixCount
                $row.DerniereMiseAJour = ConvertTo-PMDate $info.LastHotFixDate
                $row.DernierKB = $info.LastHotFixId
                $row.WindowsUpdate = $info.WUServiceStatus
                $row.WUTypeDemarrage = $info.WUServiceStartType
                Write-PMLog $computer.Name, 'Inventaire collecté'
            }
            catch {
                $row.Etat = 'Erreur distante'
                $row.Erreur = "Invoke-Command : $($_.Exception.Message)"
                Write-PMLog $computer.Name, 'ERREUR inventaire', $_.Exception.Message -Level Error
            }
        }

        $row
    }
}


# ---------- Partie 3 : inventaire des correctifs ----------

function Get-PMPatchInventory {
    param([object[]]$Availability)

    $rows = @()
    $status = @{}

    foreach ($computer in $Availability) {
        if ($computer.Status -ne 'Accessible') {
            $status[$computer.Name] = [pscustomobject]@{ Collected = $false; Status = $computer.Status; Error = $computer.Error }
            continue
        }

        try {
            $hotfixes = @(Invoke-PMRemote $computer $RemoteHotFixBlock 'Get-PMRemoteHotFix' 'HotFixes')
            foreach ($hotfix in $hotfixes) {
                $rows += [pscustomobject]@{
                    Poste            = $computer.Name
                    AdresseIP        = $computer.IP
                    KB               = ([string]$hotfix.HotFixID).ToUpper()
                    Description      = $hotfix.Description
                    DateInstallation = ConvertTo-PMDate $hotfix.InstalledOn
                    InstallePar      = $hotfix.InstalledBy
                }
            }
            $status[$computer.Name] = [pscustomobject]@{ Collected = $true; Status = 'Accessible'; Error = '' }
            Write-PMLog $computer.Name, "$($hotfixes.Count) correctif(s) recensé(s)"
        }
        catch {
            $status[$computer.Name] = [pscustomobject]@{ Collected = $false; Status = 'Erreur distante'; Error = "Invoke-Command : $($_.Exception.Message)" }
            Write-PMLog $computer.Name, 'ERREUR inventaire correctifs', $_.Exception.Message -Level Error
        }
    }

    # Tri par poste puis par date décroissante, les dates inconnues à la fin
    $rows = @($rows | Sort-Object Poste, @{ Expression = { if ($_.DateInstallation) { $_.DateInstallation } else { [datetime]::MinValue } }; Descending = $true })

    return @{ Rows = $rows; Status = $status }
}

function Get-PMPatchSummary {
    param([object[]]$Rows, [object[]]$Availability, [hashtable]$Status)

    foreach ($computer in $Availability) {
        $patches = @($Rows | Where-Object { $_.Poste -eq $computer.Name })
        $dated = @($patches | Where-Object { $_.DateInstallation } | Sort-Object DateInstallation -Descending)
        $state = $Status[$computer.Name]

        $count = $null
        if ($state.Collected) { $count = $patches.Count }

        $lastDate = $null
        $lastKB = $null
        if ($dated.Count -gt 0) {
            $lastDate = $dated[0].DateInstallation
            $lastKB = $dated[0].KB
        }

        [pscustomobject]@{
            Poste            = $computer.Name
            AdresseIP        = $computer.IP
            Etat             = $state.Status
            NbCorrectifs     = $count
            DernierCorrectif = $lastDate
            DernierKB        = $lastKB
            Erreur           = $state.Error
        }
    }
}


# ---------- Partie 4 : conformité ----------

function Test-PMCompliance {
    param([object[]]$Availability, [hashtable]$PatchInventory, [string[]]$RequiredPatches)

    $controlDate = Get-Date

    foreach ($computer in $Availability) {
        $state = $PatchInventory.Status[$computer.Name]

        if (-not $state.Collected) {
            [pscustomobject]@{
                Poste             = $computer.Name
                AdresseIP         = $computer.IP
                KBRequises        = $RequiredPatches.Count
                KBManquantes      = $null
                ListeKBManquantes = ''
                Etat              = 'INACCESSIBLE'
                Detail            = $state.Error
                DateControle      = $controlDate
            }
            continue
        }

        $installed = $PatchInventory.Rows | Where-Object { $_.Poste -eq $computer.Name } | ForEach-Object { $_.KB }
        $missing = @($RequiredPatches | Where-Object { $installed -notcontains $_ })

        if ($missing.Count -eq 0) { $result = 'CONFORME' } else { $result = 'NON CONFORME' }

        [pscustomobject]@{
            Poste             = $computer.Name
            AdresseIP         = $computer.IP
            KBRequises        = $RequiredPatches.Count
            KBManquantes      = $missing.Count
            ListeKBManquantes = $missing -join ', '
            Etat              = $result
            Detail            = ''
            DateControle      = $controlDate
        }
    }
}

function Get-PMComplianceRate {
    param([object[]]$Compliance)

    # Les postes inaccessibles ne comptent pas : on ne connaît pas leur état
    $checked = @($Compliance | Where-Object { $_.Etat -ne 'INACCESSIBLE' })
    if ($checked.Count -eq 0) { return $null }

    $compliant = @($checked | Where-Object { $_.Etat -eq 'CONFORME' })
    return [math]::Round(100 * $compliant.Count / $checked.Count, 1)
}


# ---------- Partie 5 : rapport de sécurité ----------

function New-PMSecurityReport {
    param([object[]]$Inventory, [object[]]$Compliance, [switch]$Simulation)

    $rows = @()
    foreach ($check in $Compliance) {
        $info = $Inventory | Where-Object { $_.Poste -eq $check.Poste } | Select-Object -First 1

        $remark = $check.Detail
        if (-not $remark -and $info) { $remark = $info.Erreur }

        $rows += [pscustomobject]@{
            Poste            = $check.Poste
            AdresseIP        = $check.AdresseIP
            Accessibilite    = $info.Etat
            Windows          = $info.Windows
            DernierDemarrage = $info.DernierDemarrage
            WindowsUpdate    = $info.WindowsUpdate
            NbKBRequises     = $check.KBRequises
            NbKBManquantes   = $check.KBManquantes
            KBManquantes     = $check.ListeKBManquantes
            Conformite       = $check.Etat
            DateControle     = $check.DateControle
            Remarque         = $remark
        }
    }

    $totalMissing = 0
    foreach ($row in $rows) { $totalMissing += [int]$row.NbKBManquantes }

    $summary = [pscustomobject]@{
        DateControle        = $Compliance[0].DateControle
        TotalPostes         = $rows.Count
        PostesAccessibles   = @($rows | Where-Object { $_.Conformite -ne 'INACCESSIBLE' }).Count
        PostesInaccessibles = @($rows | Where-Object { $_.Conformite -eq 'INACCESSIBLE' }).Count
        PostesConformes     = @($rows | Where-Object { $_.Conformite -eq 'CONFORME' }).Count
        PostesNonConformes  = @($rows | Where-Object { $_.Conformite -eq 'NON CONFORME' }).Count
        TotalKBManquantes   = $totalMissing
        TauxConformite      = Get-PMComplianceRate $Compliance
    }

    $toFix = @($rows | Where-Object { $_.Conformite -ne 'CONFORME' })

    $stamp = Get-Date $summary.DateControle -Format 'yyyyMMdd_HHmmss'
    $csvPath = Get-PMOutputPath "SecurityReport_$stamp.csv"
    $htmlPath = Get-PMOutputPath "SecurityReport_$stamp.html"

    Export-PMCsv $rows $csvPath
    New-PMHtmlReport $rows $summary $toFix $Simulation | Set-Content $htmlPath -Encoding UTF8
    Copy-Item $csvPath (Get-PMOutputPath 'SecurityReport.csv') -Force
    Copy-Item $htmlPath (Get-PMOutputPath 'SecurityReport.html') -Force

    return [pscustomobject]@{
        Rows     = $rows
        Summary  = $summary
        ToFix    = $toFix
        CsvPath  = $csvPath
        HtmlPath = $htmlPath
    }
}

function New-PMHtmlReport($Rows, $Summary, $ToFix, $Simulation) {
    $style = @'
<style>
 body { font-family: Segoe UI, Arial, sans-serif; margin: 24px; color: #1f2933; background: #f7f8fa; }
 h2 { margin-top: 32px; border-bottom: 2px solid #d0d7de; }
 table { border-collapse: collapse; width: 100%; background: #fff; font-size: 13px; }
 th, td { border: 1px solid #d0d7de; padding: 6px 8px; text-align: left; }
 th { background: #eef1f4; }
 .ok { background: #d3f9d8; } .ko { background: #ffe3e3; } .na { background: #fff3bf; }
 .sim { background: #f3d9fa; padding: 8px; }
</style>
'@

    if ($null -ne $Summary.TauxConformite) { $rate = "$($Summary.TauxConformite) %" } else { $rate = 'n/a' }

    $synthesis = [pscustomobject]@{
        'Postes au total'          = $Summary.TotalPostes
        'Postes accessibles'       = $Summary.PostesAccessibles
        'Postes inaccessibles'     = $Summary.PostesInaccessibles
        'Postes conformes'         = $Summary.PostesConformes
        'Postes non conformes'     = $Summary.PostesNonConformes
        'Correctifs manquants'     = $Summary.TotalKBManquantes
        'Taux de conformité'       = $rate
    }

    $actions = foreach ($row in $ToFix) {
        if ($row.Conformite -eq 'NON CONFORME') { $action = "Installer : $($row.KBManquantes)" }
        else { $action = "Rétablir l'accès : $($row.Remarque)" }
        [pscustomobject]@{ Poste = $row.Poste; 'Adresse IP' = $row.AdresseIP; 'État' = $row.Conformite; 'Action requise' = $action }
    }

    $details = $Rows | Select-Object Poste, @{ n = 'Adresse IP'; e = { $_.AdresseIP } }, @{ n = 'Accessibilité'; e = { $_.Accessibilite } },
        Windows, @{ n = 'Dernier démarrage'; e = { Format-PMDate $_.DernierDemarrage } }, @{ n = 'Windows Update'; e = { $_.WindowsUpdate } },
        @{ n = 'KB requises'; e = { $_.NbKBRequises } }, @{ n = 'KB manquantes'; e = { $_.NbKBManquantes } },
        @{ n = 'Liste des KB manquantes'; e = { $_.KBManquantes } }, @{ n = 'Conformité'; e = { $_.Conformite } },
        @{ n = 'Date du contrôle'; e = { Format-PMDate $_.DateControle } }

    $html = '<h1>Rapport de sécurité — Patch Management</h1>'
    $html += "<p>Contrôle du $(Format-PMDate $Summary.DateControle) — généré sur $([Environment]::MachineName)</p>"
    if ($Simulation) { $html += "<p class='sim'>Rapport généré en MODE SIMULATION (données fictives de test).</p>" }
    $html += '<h2>Synthèse du parc</h2>' + ($synthesis | ConvertTo-Html -As List -Fragment)
    $html += '<h2>Postes nécessitant une intervention</h2>'
    if ($actions) { $html += ($actions | ConvertTo-Html -Fragment) }
    else { $html += '<p>Aucune intervention nécessaire : tous les postes contrôlés sont conformes.</p>' }
    $html += '<h2>Détail par poste</h2>' + ($details | ConvertTo-Html -Fragment)

    # ConvertTo-Html encode déjà les valeurs, on ajoute seulement les couleurs
    $html = $html -replace '<td>CONFORME</td>', '<td class="ok">CONFORME</td>'
    $html = $html -replace '<td>NON CONFORME</td>', '<td class="ko">NON CONFORME</td>'
    $html = $html -replace '<td>INACCESSIBLE</td>', '<td class="na">INACCESSIBLE</td>'

    return "<!DOCTYPE html><html lang='fr'><head><meta charset='utf-8'><title>Rapport de sécurité</title>$style</head><body>$html</body></html>"
}


# ---------- Partie 6 : notification ----------

function New-PMNotificationBody($Report) {
    $s = $Report.Summary
    if ($null -ne $s.TauxConformite) { $rate = "$($s.TauxConformite) %" } else { $rate = 'n/a' }

    $text = "Date du contrôle : $(Format-PMDate $s.DateControle)`r`n`r`n"
    $text += "Postes contrôlés            : $($s.TotalPostes)`r`n"
    $text += "Postes non conformes        : $($s.PostesNonConformes)`r`n"
    $text += "Postes inaccessibles        : $($s.PostesInaccessibles)`r`n"
    $text += "Taux de conformité          : $rate`r`n`r`n"

    foreach ($row in $Report.ToFix) {
        $text += "$($row.Poste) : $($row.Conformite)`r`n"
        if ($row.Conformite -eq 'NON CONFORME') {
            foreach ($kb in $row.KBManquantes -split ', ') { $text += "       $kb manquante`r`n" }
        }
        else {
            $text += "       $($row.Remarque)`r`n"
        }
        $text += "`r`n"
    }
    $text += 'Le rapport complet est joint à ce message.'
    return $text
}

function Send-PMNotification {
    param($Report)

    $config = Get-PMSetting 'Notification'
    if (-not $config.Enabled) {
        Write-PMLog 'Notification désactivée dans settings.psd1'
        return $false
    }
    if ($Report.ToFix.Count -eq 0) {
        Write-PMLog 'Aucune anomalie détectée : pas de notification'
        return $false
    }

    $recipients = $config.To -join ', '
    try {
        $mail = New-Object System.Net.Mail.MailMessage
        $mail.From = $config.From
        foreach ($address in $config.To) { $mail.To.Add($address) }
        $mail.Subject = '[PATCH MANAGEMENT] Anomalies détectées'
        $mail.Body = New-PMNotificationBody $Report
        $mail.Attachments.Add((New-Object System.Net.Mail.Attachment($Report.HtmlPath)))

        $smtp = New-Object System.Net.Mail.SmtpClient($config.SmtpServer, $config.Port)
        if ($config.DeliveryMethod -eq 'PickupDirectory') {
            # Mode test : le message est écrit dans un fichier .eml au lieu d'être envoyé
            $folder = Resolve-PMPath $config.PickupDirectory
            if (-not (Test-Path $folder)) { New-Item -ItemType Directory -Path $folder | Out-Null }
            $smtp.DeliveryMethod = 'SpecifiedPickupDirectory'
            $smtp.PickupDirectoryLocation = $folder
        }
        else {
            $smtp.EnableSsl = $config.UseSsl
            if ($config.CredentialFile) {
                $smtp.Credentials = (Import-Clixml (Resolve-PMPath $config.CredentialFile)).GetNetworkCredential()
            }
        }

        $smtp.Send($mail)
        $mail.Dispose()
        $smtp.Dispose()

        if ($config.DeliveryMethod -eq 'PickupDirectory') {
            Write-PMLog "Notification envoyée à $recipients (fichier .eml déposé dans $($config.PickupDirectory))"
        }
        else {
            Write-PMLog "Notification envoyée à $recipients"
        }
        return $true
    }
    catch {
        Write-PMLog 'ERREUR', 'Notification non envoyée', $_.Exception.Message -Level Error
        return $false
    }
}


# ---------- Affichage et export ----------

function Format-PMDate($Date, $Format = 'dd/MM/yyyy HH:mm:ss') {
    if ($Date -is [datetime]) { return $Date.ToString($Format) }
    return $Date
}

function Export-PMCsv($Objects, $Path) {
    # Séparateur ";" et UTF-8 avec BOM pour qu'Excel en français ouvre le fichier correctement
    $lines = foreach ($object in $Objects) {
        $copy = [ordered]@{}
        foreach ($property in $object.PSObject.Properties) {
            $copy[$property.Name] = Format-PMDate $property.Value
        }
        [pscustomobject]$copy
    }

    if ($PSVersionTable.PSVersion.Major -ge 6) { $encoding = 'utf8BOM' } else { $encoding = 'UTF8' }
    @($lines) | Export-Csv -Path $Path -Delimiter ';' -NoTypeInformation -Encoding $encoding
}

function Format-PMDateColumn {
    # Pour l'affichage console : dates courtes et "—" quand la valeur est vide
    param([Parameter(ValueFromPipeline)]$InputObject)
    process {
        $copy = [ordered]@{}
        foreach ($property in $InputObject.PSObject.Properties) {
            $value = $property.Value
            if ($value -is [datetime]) { $value = $value.ToString('dd/MM/yyyy') }
            elseif ($null -eq $value -or "$value" -eq '') { $value = '—' }
            $copy[$property.Name] = $value
        }
        [pscustomobject]$copy
    }
}

Export-ModuleMember -Function *
