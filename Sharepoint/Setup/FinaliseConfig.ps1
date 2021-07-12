<#
 /$$$$$$  /$$$$$$  /$$$$$$$$
|_  $$_/ /$$__  $$|_____ $$ 
  | $$  | $$  \ $$     /$$/ 
  | $$  | $$  | $$    /$$/  
  | $$  | $$  | $$   /$$/   
  | $$  | $$  | $$  /$$/    
 /$$$$$$|  $$$$$$/ /$$$$$$$$
|______/ \______/ |________/

###########################
#-------------------------#
#         IOZ AG          #
#  St. Georg-Strasse 2a   #
#      CH-6210 Sursee     #
#                         #
#       Version 1.0       #
#-------------------------#
###########################
#>


#Mit Hilfe von diesem Script kann die SharePoint Konfiguration abgeschlossen werden
#Alle Punkte welche benötigt werden, selectiv ausführen

#Start Schritt 1
$snapin = Get-PSSnapin Microsoft.SharePoint.Powershell -ErrorVariable err -ErrorAction SilentlyContinue
if($snapin -eq $null){
Add-PSSnapin Microsoft.SharePoint.Powershell 
}
#Stop Schritt 1

#Berechtigungen setzen, damit alle Services richtig funktionieren
#----------------------------------------------------------------

#Berechtigung für Visio Services
$WebApp = Get-SPWebApplication -Identity https://abc.xyz.ch #Root oder andere WebApp
$WebApp.GrantAccessToProcessIdentity("XXX\sa-spservices")

#Berechtigung für MySite Newsfeed
$WebApp = Get-SPWebApplication -Identity https://applications.XXX.ch #andere WebApp
$WebApp.GrantAccessToProcessIdentity("XXX\sa-spapppool") #Service Account von MySite
$WebApp = Get-SPWebApplication -Identity https://collab.XXX.ch #andere WebApp
$WebApp.GrantAccessToProcessIdentity("XXX\sa-spapppool") #Service Account von MySite


#Healt Roles Disablen
#--------------------
#The server farm account should not be used for other services
Disable-SPHealthAnalysisRule -Identity 'FarmAccountIsSharedWithUserServices' -Confirm:$false
#Databases exist on servers running SharePoint Foundation
Disable-SPHealthAnalysisRule -Identity 'DatabasesAreOnAppServers' -Confirm:$false
#Database has large amounts of unused space
Disable-SPHealthAnalysisRule -Identity 'DatabaseCanBeShrinked' -Confirm:$false
#Built-in accounts are used as application pool or service identities
Disable-SPHealthAnalysisRule -Identity 'BuiltInAccountsUsedAsProcessIdentities' -Confirm:$false
#Accounts used by application pools or services identities are in the local ma-chine Administrators group
Disable-SPHealthAnalysisRule -Identity 'AdminAccountsUsedAsProcessIdentities' -Confirm:$false
#Drives are at risk of running out of free space. 
Disable-SPHealthAnalysisRule -Identity 'AppServerDrivesAreNearlyFullWarning' -Confirm:$false

Get-SPHealthAnalysisRule | where {!$_.Enabled} | select Summary


#Set Log Settings
#----------------
Set-SPLogLevel -TraceSeverity Unexpected
Set-SPLogLevel -EventSeverity ErrorCritical
Set-SPDiagnosticConfig -LogLocation "D:\Microsoft Office Servers\16.0\Logs" 
Set-SPDiagnosticConfig -LogMaxDiskSpaceUsageEnabled
Set-SPDiagnosticConfig -LogDiskSpaceUsageGB 1


#Berechtingen setzen für HeatingUpScript (SharePointWarmUpHelper)
#----------------------------------------------------------------

#For all WebApps
$userOrGroup = "XXX\sa-spadmin" #Entsprechender Service Account, unter welchem das HeatingUpScript ausgeführt wird
$displayName = "HeatingUpScript Account" 
Get-SPWebApplication | foreach { 
    $webApp = $_ 
    $policy = $webApp.Policies.Add($userOrGroup, $displayName) 
    $policyRole = $webApp.PolicyRoles.GetSpecialRole([Microsoft.SharePoint.Administration.SPPolicyRoleType]::FullControl) 
    $policy.PolicyRoleBindings.Add($policyRole) 
    $webApp.Update() 
}

#Set the HeatingUpScript Account to one WebApps
$userOrGroup = "XXX\sa-spsetup" #Entsprechender Service Account, unter welchem das HeatingUpScript ausgeführt wird
$displayName = "HeatingUpScript Account" 

$webApp = Get-SPWebApplication -Identity "https://abc.xyz.ch"
$policy = $webApp.Policies.Add($userOrGroup, $displayName) 
$policyRole = $webApp.PolicyRoles.GetSpecialRole([Microsoft.SharePoint.Administration.SPPolicyRoleType]::FullRead) 
$policy.PolicyRoleBindings.Add($policyRole) 
$webApp.Update() 


#Berechtigungen setzen für Service Account SharePoint Admin mit ADFS / ACS
#-------------------------------------------------------------------------

#For all WebApps (Windows Autentication ADFS)
$user = "pt52-spsetup@iozdctest.ch" #Entsprechender Service Account
$claim = New-SPClaimsPrincipal -Identity $user -IdentityType WindowsSamAccountName
$claim.ToEncodedString()
$displayName = "SharePoint Admin" 

Get-SPWebApplication | foreach { 
    $webApp = $_ 
    $policy = $webApp.Policies.Add($claim.ToEncodedString(), $displayName) 
    $policyRole = $webApp.PolicyRoles.GetSpecialRole([Microsoft.SharePoint.Administration.SPPolicyRoleType]::FullControl) 
    $policy.PolicyRoleBindings.Add($policyRole) 
    $webApp.Update() 
}

#For all WebApps (mit ADFS)
$user = "pt52-spsetup@iozdctest.ch" #Entsprechender Service Account
$claim = New-SPClaimsPrincipal -ClaimValue $user -ClaimType Email -TrustedIdentityTokenIssuer "ADFS" -IdentifierClaim 
$claim.ToEncodedString()
$displayName = "SharePoint Admin" 

Get-SPWebApplication | foreach { 
    $webApp = $_ 
    $policy = $webApp.Policies.Add($claim.ToEncodedString(), $displayName) 
    $policyRole = $webApp.PolicyRoles.GetSpecialRole([Microsoft.SharePoint.Administration.SPPolicyRoleType]::FullControl) 
    $policy.PolicyRoleBindings.Add($policyRole) 
    $webApp.Update() 
}

#For all WebApps (mit ACS)
$user = "azure.admin@ckitchen.onmicrosoft.com" #Entsprechender Service Account
$claim = New-SPClaimsPrincipal -ClaimValue $user -ClaimType UPN -TrustedIdentityTokenIssuer "ACS" -IdentifierClaim 
$claim.ToEncodedString()
$displayName = "SharePoint Admin"
 
Get-SPWebApplication | foreach { 
    $webApp = $_ 
    $policy = $webApp.Policies.Add($userOrGroup, $displayName) 
    $policyRole = $webApp.PolicyRoles.GetSpecialRole([Microsoft.SharePoint.Administration.SPPolicyRoleType]::FullControl) 
    $policy.PolicyRoleBindings.Add($policyRole) 
    $webApp.Update() 
}


#Berechtingen setzen für SharePointAdmins Gruppe (optional)
#----------------------------------------------------------

#Add to Farm Admins
$caWebApp = Get-SPWebApplication -IncludeCentralAdministration | where-object {$_.DisplayName -eq "SharePoint Central Administration v4"} 
$caSite = $caWebApp.Sites[0] 
$caWeb = $caSite.RootWeb
$newFarmAdministrator = "XXX\SharePointAdmins" #AD Gruppe
$user = $caWeb.EnsureUser($newFarmAdministrator)

$farmAdministrators = $caWeb.SiteGroups["Farm Administrators"] 
$farmAdministrators.AddUser($user)
$farmAdministrators.Update()
$caWeb.Update()
$caWeb.Dispose() 
$caSite.Dispose() 

#For all WebApps
Write-Host "get Claims ID over GUI and copy it into Variable userOrGroup" -ForegroundColor red
$userOrGroup = "c:0+.w|XXX" #AD Gruppe SharePointAdmins
$displayName = "SharePointAdmins" 
Get-SPWebApplication | foreach { 
    $webApp = $_ 
    $policy = $webApp.Policies.Add($userOrGroup, $displayName) 
    $policyRole = $webApp.PolicyRoles.GetSpecialRole([Microsoft.SharePoint.Administration.SPPolicyRoleType]::FullControl) 
    $policy.PolicyRoleBindings.Add($policyRole) 
    $webApp.Update() 
}


#Berechtigung für Publishing Feater auf WebApp setzen (dies wird nur für SharePoint Server Standard/Enterprise benötigt)
#-----------------------------------------------------------------------------------------------------------------------

#Set the CacheSuperReader Account to one WebApps
$userOrGroup = "XXX\SP_CacheSuperReader"
$displayName = "CacheSuperReader" 

$webApp = Get-SPWebApplication -Identity "https://abc.xyz.ch"
$policy = $webApp.Policies.Add($userOrGroup, $displayName) 
$policyRole = $webApp.PolicyRoles.GetSpecialRole([Microsoft.SharePoint.Administration.SPPolicyRoleType]::FullRead) 
$policy.PolicyRoleBindings.Add($policyRole) 
$webApp.Update()

#Set the CacheSuperUser Account to one WebApps
$userOrGroup = "XXX\SP_CacheSuperUser"
$displayName = "CacheSuperUser" 

$webApp = Get-SPWebApplication -Identity "https://abc.xyz.ch"
$policy = $webApp.Policies.Add($userOrGroup, $displayName) 
$policyRole = $webApp.PolicyRoles.GetSpecialRole([Microsoft.SharePoint.Administration.SPPolicyRoleType]::FullControl) 
$policy.PolicyRoleBindings.Add($policyRole) 
$webApp.Update()


#Set PeoplePicker auf alle WebApps
#Es benötigt dafür eine AD Gruppe, wo alle entsprechenden Accounts inkl. Service Accounts Mitglied sein müssen
#---------------------------------

$adfilter = "(&(objectCategory=Person)(objectClass=User)(memberOf=CN=pt39-spusers,OU=Users,OU=Prototype39,OU=Playground,DC=iozdctest,DC=ch))" 
foreach($webapp in Get-SPWebApplication){ 
    $url = $webapp.Url 
    stsadm -o setproperty -url $url -pn peoplepicker-searchadcustomfilter -pv $adfilter 
} 

#Bei mehreren Forest müssen diese berechtigt werden damit die User gefunden werden

stsadm -o setproperty -url http://root.kundenserver.ch -pn peoplepicker-searchadforests -pv "forest:kunde1.ch;forest:kunde2.ch"

# beispiel...."forest:gict.ch;forest:emmen.ch"


#SP2016: so wie es scheint, benötigt es dies nicht mehr
#Allow PDF to open direct in Browser (Permissive) inkl. RecycleBin auf 40 Tage setzen
#------------------------------------------------------------------------------------
$webapps = Get-SPWebApplication
foreach ($webapp in $webapps) 
{ 
    $webapp.AllowedInlineDownloadedMimeTypes.Add("application/pdf") 
	$webapp.AllowedInlineDownloadedMimeTypes.Add("text/html") 
    $webapp.RecycleBinRetentionPeriod = 40
    $webapp.Update() 
}


#SP2016: so wie es scheint, benötigt es dies nicht mehr
# Minimal Download Strategy (MDS) Für alle Sites in allen WebApplications deaktivieren
#----------------------------------------
$snapin = Get-PSSnapin Microsoft.SharePoint.Powershell -ErrorVariable err -ErrorAction SilentlyContinue
if($snapin -eq $null){
Add-PSSnapin Microsoft.SharePoint.Powershell 
}
# Get All Web Applications
$WebApps=Get-SPWebApplication
foreach($webApp in $WebApps)
{
    foreach ($SPsite in $webApp.Sites)
    {
       # get the collection of webs
       foreach($SPweb in $SPsite.AllWebs)
        {
        $feature = Get-SPFeature -Web $SPweb | Where-Object {$_.DisplayName -eq "MDSFeature"}
        if ($feature -eq $null)
            {
                Write-Host -ForegroundColor Yellow 'MDS already disabled on site : ' $SPweb.title ":" $spweb.URL;
            }
        else
            {
                Write-Host -ForegroundColor Green 'Disable MDS on site : ' $SPweb.title ":" $spweb.URL;
                Disable-SPFeature MDSFeature -url $spweb.URL -Confirm:$false
            }
        }
    }
}


#Office Web Apps Bindings
#------------------------
New-SPWOPIBinding –ServerName officewebapps.xyz.ch
Set-SPWopiZone –Zone “internal-https”


#Neue WebApp inkl. Extend
#------------------------

#New WebApp (with HostHeader)
$webappname = "SP_XYZ"
$webappaccount = "XXX\sa-spxyz" #have to be managed account
$spadmin = "XXX\sa-spadmin"
$webappport = "443"
$webappurl = "https://abc.xyz.ch"
$hostheader = "abc.xyz.ch"
$webSitePfad = "D:\wea\webs\SP_XYZ"
$dbserver = "SQLALIAS"
$webappdbname = "SP_Content_XYZ"
$ap = New-SPAuthenticationProvider
$rootsitename = "XYZ"
$templatename = "STS#0" #Team Site
$lcid = "1031" # 1031 Deutsch; 1033 English; 1036 French; 1040 Italian

New-SPWebApplication -Name $webappname -SecureSocketsLayer -ApplicationPool $webappname -ApplicationPoolAccount (Get-SPManagedAccount $webappaccount) -Port $webappport -Url $webappurl -Path $webSitePfad  -DatabaseServer $dbserver -DatabaseName $webappdbname -AuthenticationProvider $ap -HostHeader $hostheader -Verbose
New-SPSite -url $webappurl -OwnerAlias $webappaccount -SecondaryOwnerAlias $spadmin -Name $rootsitename -Template $templatename -language $lcid | Out-Null
Start-Process "$webappurl" -WindowStyle Minimized

#Extend WebApp
$webappurl = "https://abc.xyz.ch"
$ExtendName = "SP_XYZ_80"
$ExtendPath = "D:\wea\webs\SP_XYZ_80"
$Extendhostheader = "abc.xyz.ch"
$ExtendZone = "Intranet"
$ExtendURL = "http://abc.xyz.ch"
$ExtPort = "80"
$ntlm = New-SPAuthenticationProvider -UseWindowsIntegratedAuthentication -DisableKerberos 
Get-SPWebApplication -Identity $webappurl | New-SPWebApplicationExtension -Name $ExtendName  -Zone $ExtendZone -URL $ExtendURL -Port $ExtPort -AuthenticationProvider $ntlm -Verbose -Path $ExtendPath -HostHeader $Extendhostheader


#Neue WebApp für MySite
#------------------------

#New WebApp (with HostHeader)
$webappname = "SP_MySite"
$webappaccount = "XXX\sa-spmysite" #have to be managed account
$spadmin = "XXX\sa-spadmin"
$webappport = "443"
$webappurl = "https://mysite.xyz.ch"
$hostheader = "mysite.xyz.ch"
$webSitePfad = "D:\wea\webs\SP_MySite"
$dbserver = "SQLALIAS"
$webappdbname = "SP_Content_MySite"
$ap = New-SPAuthenticationProvider
$rootsitename = "MySite Host"
$templatename = "SPSMSITEHOST#0" #Team Site
$lcid = "1031" # 1031 Deutsch; 1033 English; 1036 French; 1040 Italian

New-SPWebApplication -Name $webappname -SecureSocketsLayer -ApplicationPool $webappname -ApplicationPoolAccount (Get-SPManagedAccount $webappaccount) -Port $webappport -Url $webappurl -Path $webSitePfad  -DatabaseServer $dbserver -DatabaseName $webappdbname -AuthenticationProvider $ap -HostHeader $hostheader -Verbose
New-SPSite -url $webappurl -OwnerAlias $webappaccount -SecondaryOwnerAlias $spadmin -Name $rootsitename -Template $templatename -language $lcid | Out-Null
Start-Process "$webappurl" -WindowStyle Minimized

#Extend WebApp
$webappurl = "https://mysite.xyz.ch"
$ExtendName = "SP_MySite_80"
$ExtendPath = "D:\wea\webs\SP_MySite_80"
$Extendhostheader = "mysite.xyz.ch"
$ExtendZone = "Intranet"
$ExtendURL = "http://mysite.xyz.ch"
$ExtPort = "80"
$ntlm = New-SPAuthenticationProvider -UseWindowsIntegratedAuthentication -DisableKerberos 
Get-SPWebApplication -Identity $webappurl | New-SPWebApplicationExtension -Name $ExtendName  -Zone $ExtendZone -URL $ExtendURL -Port $ExtPort -AuthenticationProvider $ntlm -Verbose -Path $ExtendPath -HostHeader $Extendhostheader


#Set Content DB Limits
#---------------------
$dbs = Get-SPContentDatabase | where{$_.Name -ne "SP_Content_XYZ"}
foreach ($db in $dbs) {
    $db.MaximumSiteCount = 1
    $db.WarningSiteCount = 0
    $db.Update()
}


#Business Data Connectivity Service (BDC) Anpassungen
#----------------------------------------------------

#BDC - Enable revert to self
#Damit wird mit dem Service Account von der entsprechenden WebApp auf die Dritt-DB zugegriffen 
$bdc = Get-SPServiceApplication | where {$_ -match “Business Data Connectivity”};
$bdc.RevertToSelfAllowed = $true;
$bdc.Update();  


#Nach SharePoint Update werden folgende DB's nicht aktualisiert
#Mit folgendem Befehl können die DB's aktualisiert werden
#--------------------------------------------------------------- 

#BDC DB Update
(Get-SPDatabase | ?{$_.type -eq "Microsoft.SharePoint.BusinessData.SharedService.BdcServiceDatabase"}).Provision() 

#Secure Store DB Update
$db = (Get-SPDatabase | ?{$_.type -eq "Microsoft.Office.SecureStoreService.Server.SecureStoreServiceDatabase"}).Provision() 
$db.NeedsUpgrade


#Distributed Cache
#-----------------

#Check Cache Cluster Health
Use-CacheCluster
Get-CacheClusterHealth
Get-CacheHost

#Manueller Neustart vom Distributed Cache
Restart-CacheCluster

#Distributed Chache entfernen 
Stop-SPDistributedCacheServiceInstance –Graceful
Remove-SPDistributedCacheServiceInstance
