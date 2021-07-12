 # OS Optimizations for WVD
 write-host 'AIB Customization: OS Optimizations for WVD'
 $appName = 'optimize'
 $drive = 'C:\'
 New-Item -Path $drive -Name $appName  -ItemType Directory -ErrorAction SilentlyContinue
 $LocalPath = $drive + '\' + $appName 
 set-Location $LocalPath
 $osOptURL = 'https://github.com/The-Virtual-Desktop-Team/Virtual-Desktop-Optimization-Tool/archive/main.zip'
 $osOptURLexe = 'Windows_10_VDI_Optimize-main.zip'
 $outputPath = $LocalPath + '\' + $osOptURLexe
 Invoke-WebRequest -Uri $osOptURL -OutFile $outputPath
 write-host 'AIB Customization: Downloading OS Optimizations script'
 Expand-Archive -LiteralPath 'C:\\Optimize\\Windows_10_VDI_Optimize-main.zip' -DestinationPath $Localpath -Force -Verbose
 Set-Location -Path C:\\Optimize\\Virtual-Desktop-Optimization-Tool-main
 
 # Patch: overide the Win10_VirtualDesktop_Optimize.ps1 - setting 'Set-NetAdapterAdvancedProperty'(see readme.md)
 Write-Host 'Patch: Disabling Set-NetAdapterAdvancedProperty'
 $updatePath= "C:\optimize\Virtual-Desktop-Optimization-Tool-main\Win10_VirtualDesktop_Optimize.ps1"
 ((Get-Content -path $updatePath -Raw) -replace 'Set-NetAdapterAdvancedProperty -DisplayName "Send Buffer Size" -DisplayValue 4MB','#Set-NetAdapterAdvancedProperty -DisplayName "Send Buffer Size" -DisplayValue 4MB') | Set-Content -Path $updatePath

  # Patch: Override 
  Write-host 'AIB Customization: Patching AppxPackages JSON'
  $AppxPackagesJson = "C:\optimize\Virtual-Desktop-Optimization-Tool-main\2009\ConfigurationFiles\AppxPackages.json"
  $AppxPackages_convert = Get-Content -Path $AppxPackagesJson -Raw | ConvertFrom-Json
  $AppxPackages_convertnew = $AppxPackages_convert | where { $_.AppxPackage -ne "Microsoft.Windows.Photos" -and $_.AppxPackage -ne "Microsoft.WindowsCalculator" } 
  $AppxPackages_convertnew | ConvertTo-Json -Depth 100 | Out-File $AppxPackagesJson -Force

  # run script
# .\optimize -WindowsVersion 2004 -Verbose
  write-host 'AIB Customization: Starting OS Optimizations script'
  .\Win10_VirtualDesktop_Optimize.ps1 -WindowsVersion 2009 -AcceptEULA -Verbose
  write-host 'AIB Customization: Finished OS Optimizations script'