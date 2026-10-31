@{
    # Fichiers d'entrée et de sortie (chemins relatifs au dossier du projet)
    ComputersFile        = 'config\computers.txt'
    RequiredPatchesFile  = 'config\required-patches.txt'
    OutputDirectory      = 'output'
    LogFile              = 'output\PatchManager.log'
    ArchiveDirectory     = 'output\archive'
    RetentionDays        = 365

    # Connexion : 'IP' (groupe de travail, NTLM) ou 'Name' (domaine, Kerberos)
    ConnectBy            = 'IP'
    UseSSL               = $false
    CredentialFile       = 'config\audit.cred.xml'
    JEAConfigurationName = ''

    Notification = @{
        Enabled         = $true
        # 'PickupDirectory' écrit un fichier .eml (tests), 'Network' envoie vraiment le courriel
        DeliveryMethod  = 'PickupDirectory'
        PickupDirectory = 'output\mail'
        SmtpServer      = 'smtp.entreprise.local'
        Port            = 587
        UseSsl          = $true
        From            = 'patchmanager@entreprise.local'
        To              = @('admin@entreprise.local')
        CredentialFile  = ''
    }
}
