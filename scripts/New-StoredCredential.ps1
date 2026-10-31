# Enregistre un identifiant chiffré (compte d'audit ou compte SMTP) pour ne jamais écrire de mot de passe en clair
# Le fichier n'est lisible que par le même utilisateur sur le même poste (chiffrement DPAPI)
# Exemple : .\New-StoredCredential.ps1 -Path ..\config\smtp.cred.xml
param([Parameter(Mandatory)][string]$Path)

Get-Credential | Export-Clixml -Path $Path

# Seuls l'utilisateur courant et SYSTEM peuvent lire le fichier
icacls $Path /inheritance:r /grant:r "$env:USERDOMAIN\${env:USERNAME}:(R,W)" "*S-1-5-18:(F)" | Out-Null

Write-Host "Identifiants enregistrés dans $Path. Indiquez ce chemin dans config\settings.psd1 (CredentialFile)."
