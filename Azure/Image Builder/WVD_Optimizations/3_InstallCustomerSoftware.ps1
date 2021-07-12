# Custom Software Installation
Write-Host 'AIB Customization: Installation Custom Software'
$rootName = 'Work'
$drive = 'C:\'
New-Item -Path $drive -Name $rootName  -ItemType Directory -ErrorAction SilentlyContinue
$LocalPath = $drive + '\' + $rootName 
Set-Location $LocalPath
$osOptURL = 'https://stordigaaib01s.blob.core.windows.net/scripts/Software/CUST_Software.zip?sp=rl&st=2021-07-02T07:19:02Z&se=2025-07-03T07:19:00Z&sv=2020-02-10&sr=b&sig=BOEH1FXrxE5POynaOuOfDEbhispUVTX9yZPS7dXVdPc%3D'
$osOptURLexe = 'CUST_Software.zip'
$outputPath = $LocalPath + '\' + $osOptURLexe
Write-Host 'AIB Customization: Downloading Custom Software'
Invoke-WebRequest -Uri $osOptURL -OutFile $outputPath
Write-Host 'AIB Customization: Extracting Custom Software'
Expand-Archive -LiteralPath 'C:\\Work\\CUST_Software.zip' -DestinationPath $Localpath -Force -Verbose
Set-Location -Path C:\\Work\\

# run script
Write-Host 'AIB Customization: Starting Custom Software Installation'
.\install_wvd.ps1 -Verbose
Write-Host 'AIB Customization: Finished Custom Software Installation'