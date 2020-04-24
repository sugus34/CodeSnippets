# Install Chocolatey
Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://chocolatey.org/install.ps1'))

# Chocolatey Globally Auto confirm every action
choco feature enable -n allowGlobalConfirmation