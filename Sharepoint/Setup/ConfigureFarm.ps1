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


#Start Schritt 1
$snapin = Get-PSSnapin Microsoft.SharePoint.Powershell -ErrorVariable err -ErrorAction SilentlyContinue
if($snapin -eq $null){
Add-PSSnapin Microsoft.SharePoint.Powershell 
}

$account = whoami
if(!$account.Contains("farm")){
    Write-Host -ForegroundColor red "You need to run the ConfigureFarm Script under the sp-farm Account! The Script will exit automatically :-)"
    sleep 30
    exit
}

#function for: create and configure IIS website and define folder permissions
function Create-IISSite($pfad, $WebsiteName, $Sites, $HostHeaderURL, $SiteURL){

	if(!([string]$Sites.name -match $WebsiteName)){
		$indexNumber = $_.url.LastIndexOf(":")
		try{
			Write-Host -ForegroundColor green  $WebsiteName "wird erstellt..." -NoNewline
			#Create and configure IIS-website
			New-Website -Name $WebsiteName -Port 80 -PhysicalPath $pfad -HostHeader $_.url.Substring(8) | Out-Null
			Set-WebConfiguration system.webServer/httpRedirect "IIS:\sites\$WebsiteName" -Value @{enabled="true";destination=$_.url;exactDestination="false";httpResponseStatus="Permanent"} | Out-Null
			
			#Create and set folder permissions   
			$Acl = Get-ACL $pfad
			
			if((Get-WmiObject Win32_OperatingSystem).OSlanguage -eq "1031")
			{
				$AccessRule= New-Object System.Security.AccessControl.FileSystemAccessRule("Jeder","ReadAndExecute","ContainerInherit,Objectinherit","none","Allow")
			}
			
			else{
				$AccessRule= New-Object System.Security.AccessControl.FileSystemAccessRule("everyone","ReadAndExecute","ContainerInherit,Objectinherit","none","Allow")
			}
	
			$Acl.AddAccessRule($AccessRule)
			Set-Acl $pfad $Acl
			Write-Host -ForegroundColo Black "done" -BackgroundColor Yellow 
		}
		catch{
			Write-Host -ForegroundColor DarkYellow "Bitte kontrollieren Sie das XML und deren Syntax!" 
			Write-Error $_
		}  
	}
}


function Write-Info([string]$msg){
    Write-Host "$($global:indent)[$([System.DateTime]::Now)] $msg"
}

function Get-ConfigurationSettings() {
    Write-Info "Loading configuration file."
    [xml]$config = Get-Content ".\Configurations.xml"

    if ($? -eq $false) {
        Write-Info "Cannot load configuration source XML $config."
        return $null
    }
    return $config.Configurations
}

function Trace([string]$desc, $code) {
    trap {
        Write-Error $_.Exception
        if ($_.Exception.InnerException -ne $null) {
            Write-Error "Inner Exception: $($_.Exception.InnerException)"
        }
        break
    }
    $desc = $desc.TrimEnd(".")
    Write-Info "BEGIN: $desc..."
    Set-Indent 1
    &$code
    Set-Indent -1
    Write-Info "Stop: $desc."
}

function Set-Indent([int]$incrementLevel)
{
    if ($incrementLevel -eq 0) {$global:indent = ""; return}
    
    if ($incrementLevel -gt 0) {
        for ($i = 0; $i -lt $incrementLevel; $i++) {
            $global:indent = "$($global:indent)`t"
        }
    } else {
        if (($global:indent).Length + $incrementLevel -ge 0) {
            $global:indent = ($global:indent).Remove(($global:indent).Length + $incrementLevel, -$incrementLevel)
        } else {
            $global:indent = ""
        }
    }
}

#Region Security-Related
# ====================================================================================
# Func: Get-AdministratorsGroup
# Desc: Returns the actual (localized) name of the built-in Administrators group
# From: Proposed by Codeplex user Sheppounet at http://autospinstaller.codeplex.com/discussions/265749
# ====================================================================================
Function Get-AdministratorsGroup
{
    If(!$builtinAdminGroup)
    {
        $builtinAdminGroup = (Get-WmiObject -Class Win32_Group -computername $env:COMPUTERNAME -Filter "SID='S-1-5-32-544' AND LocalAccount='True'" -errorAction "Stop").Name
    }
    Return $builtinAdminGroup
}

#Region Add Managed Accounts
# ===================================================================================
# FUNC: AddManagedAccounts
# DESC: Adds existing accounts to SharePoint managed accounts and creates local profiles for each
# TODO: Make this more robust, prompt for blank values etc.
# ===================================================================================
Function AddManagedAccounts([System.Xml.XmlElement]$xmlinput)
{
    #WriteLine
    Write-Host -ForegroundColor White " - Adding Managed Accounts"
    If ($xmlinput.Accounts)
    {
        # Get the members of the local Administrators group
        $builtinAdminGroup = Get-AdministratorsGroup
        $adminGroup = ([ADSI]"WinNT://$env:COMPUTERNAME/$builtinAdminGroup,group")
        # This syntax comes from Ying Li (http://myitforum.com/cs2/blogs/yli628/archive/2007/08/30/powershell-script-to-add-remove-a-domain-user-to-the-local-administrators-group-on-a-remote-machine.aspx)
        $localAdmins = $adminGroup.psbase.invoke("Members") | ForEach-Object {$_.GetType().InvokeMember("Name", 'GetProperty', $null, $_, $null)}
        # Ensure Secondary Logon service is enabled and started
        If (!((Get-Service -Name seclogon).Status -eq "Running"))
        {
            Write-Host -ForegroundColor White " - Enabling Secondary Logon service..."
            Set-Service -Name seclogon -StartupType Manual
            Write-Host -ForegroundColor White " - Starting Secondary Logon service..."
            Start-Service -Name seclogon
        }

        ForEach ($account in $xmlinput.Accounts.Account)
        {
            $username = $account.name
            $password = $account.Password
            $password = ConvertTo-SecureString "$password" -AsPlaintext -Force
            # The following was suggested by Matthias Einig (http://www.codeplex.com/site/users/view/matein78)
            # And inspired by http://todd-carter.com/post/2010/05/03/Give-your-Application-Pool-Accounts-A-Profile.aspx & http://blog.brainlitter.com/archive/2010/06/08/how-to-revolve-event-id-1511-windows-cannot-find-the-local-profile-on-windows-server-2008.aspx
            Try
            {
                Write-Host -ForegroundColor White " - Creating local profile for $username..." -NoNewline
                $credAccount = New-Object System.Management.Automation.PsCredential $username,$password
                $managedAccountDomain,$managedAccountUser = $username -Split "\\"
                # Add managed account to local admins (very) temporarily so it can log in and create its profile
                If (!($localAdmins -contains $managedAccountUser))
                {
                    $builtinAdminGroup = Get-AdministratorsGroup
                    ([ADSI]"WinNT://$env:COMPUTERNAME/$builtinAdminGroup,group").Add("WinNT://$managedAccountDomain/$managedAccountUser")
                }
                Else
                {
                    $alreadyAdmin = $true
                }
                # Spawn a command window using the managed account's credentials, create the profile, and exit immediately
                Start-Process -WorkingDirectory "$env:SYSTEMROOT\System32\" -FilePath "cmd.exe" -ArgumentList "/C" -LoadUserProfile -NoNewWindow -Credential $credAccount
                # Remove managed account from local admins unless it was already there
                $builtinAdminGroup = Get-AdministratorsGroup
                If ($alreadyAdmin) {
                    if ($username -contains $config.Accounts.Account[0].Name) {
                    }
                    else {
                    ([ADSI]"WinNT://$env:COMPUTERNAME/$builtinAdminGroup,group").Remove("WinNT://$managedAccountDomain/$managedAccountUser")
                    }
                }
                Write-Host -BackgroundColor Blue -ForegroundColor Black "Done."
            }
            Catch
            {
                $_
                Write-Host -ForegroundColor White "."
                Write-Warning "Could not create local user profile for $username"
                break
            }
            $managedAccount = Get-SPManagedAccount | Where-Object {$_.UserName -eq $username}
            If ($managedAccount -eq $null)
            {
                Write-Host -ForegroundColor White " - Registering managed account $username..."
                If ($username -eq $null -or $password -eq $null)
                {
                    Write-Host -BackgroundColor Gray -ForegroundColor DarkBlue " - Prompting for Account: "
                    $credAccount = $host.ui.PromptForCredential("Managed Account", "Enter Account Credentials:", "", "NetBiosUserName" )
                }
                Else
                {
                    $credAccount = New-Object System.Management.Automation.PsCredential $username,$password
                }
                New-SPManagedAccount -Credential $credAccount | Out-Null
                If (-not $?) { Throw " - Failed to create managed account" }
            }
            Else
            {
                Write-Host -ForegroundColor White " - Managed account $username already exists."
            }
        }
    }
    Write-Host -ForegroundColor White " - Done Adding Managed Accounts"
    #WriteLine
}
#StopRegion

function Get-Account([System.Xml.XmlElement]$accountNode){
    while (![string]::IsNullOrEmpty($accountNode.Ref)) {
        $accountNode = $accountNode.PSBase.OwnerDocument.SelectSingleNode("//Accounts/Account[@ID='$($accountNode.Ref)']")
    }

    if ($accountNode.Password.Length -gt 0) {
        $accountCred = New-Object System.Management.Automation.PSCredential $accountNode.Name, (ConvertTo-SecureString $accountNode.Password -AsPlainText -force)
    } else {
        Write-Info "Please specify the credentials for" $accountNode.Name
        $accountCred = Get-Credential $accountNode.Name
    }
    return $accountCred    
}
 
function Get-InstallOnCurrentServer([System.Xml.XmlElement]$node) 
{
    if ($node -eq $null -or $node.Server -eq $null) {
        return $false
    }
    $dbserver = $node.Server | where { (Get-ServerName $_).ToLower() -eq $env:ComputerName.ToLower() }
    if ($dbserver -eq $null -or $dbserver.Count -eq 0) {
        return $false
    }
    return $true
}

function Get-ServerName([System.Xml.XmlElement]$node)
{
    while (![string]::IsNullOrEmpty($node.Ref)) {
        $node = $node.PSBase.OwnerDocument.SelectSingleNode("//Servers/Server[@ID='$($node.Ref)']")
    }
    if ($node -eq $null -or $node.Name -eq $null) { throw "Unable to locate server name!" }
    return $node.Name
}

function New-SPQuotaTemplate {
    <#
    .Example
        C:\PS>New-SPQuotaTemplate -Name "Custom" -StorageMaximumLevel 2GB -StorageWarningLevel 1GB -UserCodeMaximiumLevel 100 -UserCodeWarningLevel 75
     
        This example creates an SP Quota Template called Custom with a maximum size
        of 2GB and a warning size of 1GB. Sandboxed solutions are 
        limited to 100, with a warning level of 75.
    .Example
        C:\PS>New-SPQuotaTemplate -Name "Custom" -StorageMaximumLevel 4GB -StorageWarningLevel 3GB
     
        This example creates an SP Quota Template called Custom with a maximum size
        of 4GB and a warning size of 3GB
    #>
    [CmdletBinding()]
    Param(
    [Parameter(Mandatory=$true)][String]$Name,
    [Parameter(Mandatory=$true)][Int64]$StorageMaximumLevel,
    [Parameter(Mandatory=$true)][Int64]$StorageWarningLevel,
    [Parameter(Mandatory=$false)][System.Double]$UserCodeMaximumLevel,
    [Parameter(Mandatory=$false)][System.Double]$UserCodeWarningLevel
    )
    # Instantiate an instance of an SPQuotaTemplate class #
    Write-Verbose "Instantiating an instance of an SPQuotaTemplate class"
    $Quota = New-Object Microsoft.SharePoint.Administration.SPQuotaTemplate
    # Set the Properties #
    Write-Verbose "Setting properties on the Quota object"
    $Quota.Name = $Name
    $Quota.StorageMaximumLevel = $StorageMaximumLevel
    $Quota.StorageWarningLevel = $StorageWarningLevel
    $Quota.UserCodeMaximumLevel = $UserCodeMaximumLevel
    $Quota.UserCodeWarningLevel = $UserCodeWarningLevel
    # Get an Instance of the SPWebService Class #
    Write-Verbose "Getting an instance of an SPWebService class"
    $Service = [Microsoft.SharePoint.Administration.SPWebService]::ContentService
    # Use the Add() method to add the quota template to the collection #
    Write-Verbose "Adding the $($Name) Quota Template to the Quota Templates Collection"
    $Service.QuotaTemplates.Add($Quota)
    # Call the Update() method to commit the changes #
    $Service.Update()
}

[System.Xml.XmlElement]$config = Get-ConfigurationSettings

if ($config -eq $null) {
    return $false
}

#Variabeln
$dbserver = $config.Farm.DatabaseServer

AddManagedAccounts $config
#Stop Schritt 1

#Start Schritt 2
Trace "Configure WebApplication" { 

    $spadmin = $config.WebApplications.spadmin

	foreach($item in $config.WebApplications.WebApplication){
		$webappname=$item.Name
	 	$webappport=$item.Port
        $webSitePfad=$item.WebSitePath + $webappname
        $webappdbname=$item.WebAppDBName
		$webappurl=$item.url
		$webappaccount=Get-Account($item.Account)
        $ap = New-SPAuthenticationProvider
        $apppoolname = $item.AppPoolName

        if($item.hostnamesc -eq "yes"){
            #Host Named WebApplication with Host Header Site Collections
            #############################################################
		 
            if($webappport -eq "443"){
                #HTTPS
                ######

		        #WebApp
                New-SPWebApplication -Name $webappname -SecureSocketsLayer -ApplicationPool $apppoolname -ApplicationPoolAccount (Get-SPManagedAccount $webappaccount.UserName) -Port $webappport -Url $webappurl -Path $webSitePfad  -DatabaseServer $dbserver -DatabaseName $webappdbname -AuthenticationProvider $ap | Out-Null
                New-SPSite -url $webappurl -OwnerAlias $spadmin -Name "Root" -Template $item.template -language $item.language | Out-Null
                Set-SPContentDatabase -Identity $webappdbname -MaxSiteCount 1 -WarningSiteCount 0
                Write-Host -ForegroundColor Yellow "Bind the coresponding SSL Certificate to the IIS WebSite"

                #Managed Paths
                foreach($mpath in $item.ManagedPaths.Path){
                    if($mpath.Type -eq "explicit"){
                        New-SPManagedPath -Explicit $mpath.Name -HostHeader 
                    }elseif($mpath.Type -eq "wildcard"){
                        New-SPManagedPath  -RelativeURL $mpath.Name -HostHeader
                    }
                }

		        #SC's
                $webapp = Get-SPWebApplication $webappname
                foreach($sc in $item.SiteCollections.SiteCollection){
                    $contentdb = New-SPContentDatabase -Name $sc.contentDB -WebApplication $webapp.url -MaxSiteCount 1 -WarningSiteCount 0
                    New-SPSite -url $sc.url -OwnerAlias $spadmin -Name $sc.name -Template $sc.template -language $sc.language -HostHeaderWebApplication $webapp.url -ContentDatabase $contentdb | Out-Null
                } 
		    }else{
                #HTTP
                #####

		        #WebApp
                New-SPWebApplication -Name $webappname -ApplicationPool $apppoolname -ApplicationPoolAccount (Get-SPManagedAccount $webappaccount.UserName) -Port $webappport -Url $webappurl -Path $webSitePfad  -DatabaseServer $dbserver -DatabaseName $webappdbname -AuthenticationProvider $ap | Out-Null
                New-SPSite -url $webappurl -OwnerAlias $spadmin -Name "Root" -Template $item.template -language $item.language | Out-Null
                Get-SPContentDatabase $webappdbname | Set-SPContentDatabase -MaxSiteCount 1 -WarningSiteCount 0

                #Managed Paths
                foreach($mpath in $item.ManagedPaths.Path){
                    if($mpath.Type -eq "explicit"){
                        New-SPManagedPath -Explicit $mpath.Name -HostHeader 
                    }elseif($mpath.Type -eq "wildcard"){
                        New-SPManagedPath  -RelativeURL $mpath.Name -HostHeader
                    }
                }

		        #SC's
                $webapp = Get-SPWebApplication $webappname
                foreach($sc in $item.SiteCollections.SiteCollection){
                    $contentdb = New-SPContentDatabase -Name $sc.contentDB -WebApplication $webapp.url -MaxSiteCount 1 -WarningSiteCount 0
                    New-SPSite -url $sc.url -OwnerAlias $spadmin -Name $sc.name -Template $sc.template -language $sc.language -HostHeaderWebApplication $webapp.url -ContentDatabase $contentdb | Out-Null
                } 
            }
        }elseif($item.hostnamesc -eq "no"){
            #Managed Path WebApplication with Managed Path Site Collections
            #############################################################

		    if($webappport -eq "443"){
                #HTTPS
                ######
                
                #WebApp
                $pool = [Microsoft.SharePoint.Administration.SPWebService]::ContentService.ApplicationPools | where {$_.Name -eq $apppoolname}
                if($pool -eq $null){
                    New-SPWebApplication -Name $webappname -SecureSocketsLayer -ApplicationPool $apppoolname -ApplicationPoolAccount (Get-SPManagedAccount $webappaccount.UserName) -Port $webappport -Url $webappurl -Path $webSitePfad  -DatabaseServer $dbserver -DatabaseName $webappdbname -AuthenticationProvider $ap -HostHeader $item.hostheaderurl | Out-Null
                }else{
                    New-SPWebApplication -Name $webappname -SecureSocketsLayer -ApplicationPool $pool.Name -Port $webappport -Url $webappurl -Path $webSitePfad  -DatabaseServer $dbserver -DatabaseName $webappdbname -AuthenticationProvider $ap -HostHeader $item.hostheaderurl | Out-Null
                }

                #SiteCollection
                New-SPSite -url $webappurl -OwnerAlias $spadmin -Name $item.SCName -Template $item.template -language $item.language | Out-Null
                Set-SPContentDatabase -Identity $webappdbname -MaxSiteCount 1 -WarningSiteCount 0
                Write-Host -ForegroundColor Yellow "Bind the coresponding SSL Certificate to the IIS WebSite"

                #Managed Paths
                $webapp = Get-SPWebApplication $webappurl 
                foreach($mpath in $item.ManagedPaths.Path){
                    if($mpath.Type -eq "explicit"){
                        New-SPManagedPath -WebApplication $webapp -Explicit $mpath.Name  
                    }elseif($mpath.Type -eq "wildcard"){
                        New-SPManagedPath -WebApplication $webapp -RelativeURL $mpath.Name
                    }
                }

                #SC's
                foreach($sc in $item.SiteCollections.SiteCollection){
                    $contentdb = New-SPContentDatabase -Name $sc.contentDB -WebApplication $webapp.url -MaxSiteCount 1 -WarningSiteCount 0
                    New-SPSite -url $sc.url -OwnerAlias $spadmin -Name $sc.name -Template $sc.template -language $sc.language -ContentDatabase $contentdb | Out-Null
                }
		    }else{
               #HTTP
               #####

                #WebApp
                $pool = [Microsoft.SharePoint.Administration.SPWebService]::ContentService.ApplicationPools | where {$_.Name -eq $apppoolname}
                if($pool -eq $null){
                    New-SPWebApplication -Name $webappname -ApplicationPool $apppoolname -ApplicationPoolAccount (Get-SPManagedAccount $webappaccount.UserName) -Port $webappport -Url $webappurl -Path $webSitePfad  -DatabaseServer $dbserver -DatabaseName $webappdbname -AuthenticationProvider $ap -HostHeader $item.hostheaderurl | Out-Null
                }else{
                    New-SPWebApplication -Name $webappname  -ApplicationPool $pool.Name -Port $webappport -Url $webappurl -Path $webSitePfad  -DatabaseServer $dbserver -DatabaseName $webappdbname -AuthenticationProvider $ap -HostHeader $item.hostheaderurl | Out-Null
                }

                #SiteCollection
                New-SPSite -url $webappurl -OwnerAlias $spadmin -Name $item.SCName -Template $item.template -language $item.language | Out-Null
                Set-SPContentDatabase -Identity $webappdbname -MaxSiteCount 1 -WarningSiteCount 0

                #Managed Paths
                $webapp = Get-SPWebApplication $webappurl 
                foreach($mpath in $item.ManagedPaths.Path){
                    if($mpath.Type -eq "explicit"){
                        New-SPManagedPath -WebApplication $webapp -Explicit $mpath.Name  
                    }elseif($mpath.Type -eq "wildcard"){
                        New-SPManagedPath -WebApplication $webapp -RelativeURL $mpath.Name
                    }
                }

                #SC's
                foreach($sc in $item.SiteCollections.SiteCollection){
                    $contentdb = New-SPContentDatabase -Name $sc.contentDB -WebApplication $webapp.url -MaxSiteCount 1 -WarningSiteCount 0
                    New-SPSite -url $sc.url -OwnerAlias $spadmin -Name $sc.name -Template $sc.template -language $sc.language -ContentDatabase $contentdb | Out-Null
                }
            }
        }
   }
}

Trace "Set Site Collection Quotas" { 
	try
	{
        Write-Host "Set Site Collection Quotas"
        
        foreach($item in $config.WebApplications.WebApplication){
            foreach($quota in $item.quotas){
                if($quota -ne ""){
                    $StorageMax = $quota.StorageMax 
                    $StorageWarning = $quota.StorageWarning
                    New-SPQuotaTemplate -Name $quota.Name -StorageMaximumLevel $StorageMax -StorageWarningLevel $StorageWarning -UserCodeMaximumLevel $quota.UserCodeMax -UserCodeWarningLevel $quota.UserCodeWarning
                    foreach($url in $item.quotas.urls.url){
                        $url = $url.Name
                        $urls = Get-SPWebApplication -Identity $url | Get-SPSite | where {$_.Url -like $url+"*"} 
                        foreach($sc in $urls){
                            write-host "Set Quota Template"$quota.Name "on SiteCollection"$sc.Url
                            Set-SPSite -Identity $sc -QuotaTemplate $quota.Name 
                        }
                    }
                    if($item.quotas.AssignWebApp -eq "True"){
                        write-host "Set Quota Template"$quota.Name "on WebApp "$item.Name
                        Set-SPWebApplication -Identity $item.Name -DefaultQuotaTemplate $quota.Name
                    }
                }
            }
        }

	}
	catch
	{	Write-Output $_
	}
}
#Stop Schritt 2

#Start Schritt 3
Trace "Configure UsageApplicationService" { 
	try
	{
		Write-Host -ForegroundColor Yellow "- Creating WSS Usage Application..."
        New-SPUsageApplication -Name "Usage and Health data collection Service" -DatabaseServer $dbserver -DatabaseName $config.Services.UsageApplicationService.collectioDB | Out-Null
        $ua = Get-SPServiceApplicationProxy | where {$_.DisplayName -eq "Usage and Health data collection Service"}
        $ua.Provision()
        Set-SPUsageService -LoggingEnabled 1 -Verbose
        Set-SPUsageService -UsageLogLocation $config.Services.UsageApplicationService.LogPfad -Verbose

        Write-Host "Enabling Heatlth Data Collection..."
        [void][System.Reflection.Assembly]::LoadWithPartialName("Microsoft.SharePoint.Diagnostics") 
        [void][System.Reflection.Assembly]::LoadWithPartialName("Microsoft.SharePoint.Administration")
        $localFarm = [Microsoft.SharePoint.Administration.SPFarm]::Local
        [Microsoft.SharePoint.Diagnostics.SPDiagnosticsProvider]::EnableAll($localFarm)

	    Write-Host -ForegroundColor Yellow "- Done Creating WSS Usage Application."

        Get-SPUsageDefinition | ForEach-Object {Set-SPUsageDefinition -Identity $_.name -Enable:$False}
        Set-SPUsageDefinition -Identity "Analytics Usage" -Enable:$True
        Set-SPUsageDefinition -Identity "Page Requests" -Enable:$True
        Set-SPUsageDefinition -Identity "Task Use" -Enable:$True
        Set-SPUsageDefinition -Identity "Web Part Use" -Enable:$True

	}
	catch
	{	Write-Output $_
	}
}

Trace "Microsoft SharePoint Foundation User Code Service" {
    $UserCodeService = Get-SPService | Where {$_.TypeName -eq "Microsoft SharePoint Foundation Sandboxed Code Service" -or $_.TypeName -eq "Microsoft SharePoint Foundation-Sandkasten-Codedienst"} 
    If ($UserCodeService.AutoProvision -eq $False) 
    {
    	try
    	{
    		Write-Host "- Starting Microsoft SharePoint Foundation User Code Service..."
    		$UserCodeService | Start-SPService | Out-Null
    		If (-not $?) {throw}
    	}
    	catch {"- An error occurred starting the Microsoft SharePoint Foundation User Code Service"}
    }
}

Trace "Configure State Service" { 
	try
	{
        Write-Host -ForegroundColor Yellow "Creating State Service Application..."
        New-SPStateServiceDatabase -name $config.Services.StateService.DBName | Out-Null
        New-SPStateServiceApplication -Name "State Service Application" -Database $config.Services.StateService.DBName  | Out-Null
        Get-SPStateServiceDatabase | Initialize-SPStateServiceDatabase | Out-Null
        Get-SPStateServiceApplication | New-SPStateServiceApplicationProxy -Name "State Service Application"  -DefaultProxyGroup | Out-Null
	    Write-Host -ForegroundColor Yellow "Done Creating State Service Application."
	}
	catch
	{	Write-Output $_
	}
}
#Stop Schritt 3

#Start Schritt 4
Trace "Unlimit SP_Content_People Content DBs" { 
	try
	{
        Write-Host "Set SiteCollection Limit to 5000 and 2000"
        $dbs = Get-SPContentDatabase | where{$_.Name -like "SP_Content_People*"}
        foreach($db in $dbs){
            Set-SPContentDatabase $db -MaxSiteCount 5000 -WarningSiteCount 2000
        }
	}
	catch
	{	Write-Output $_
	}
}

Trace "Preconfigure Managet Metadata Service" { 
	try
{

      #App Pool     
      $ApplicationPool = Get-SPServiceApplicationPool $config.Services.ManagedMetadata.AppPoolName -ea SilentlyContinue
      if($ApplicationPool -eq $null)
	  { 
            $appoolname=$config.ServiceAppPool.Name
			$appooluser=Get-Account($config.ServiceAppPool.Account)
            $ApplicationPool = New-SPServiceApplicationPool -name $appoolname -account (Get-SPManagedAccount $appooluser.username) 
      }

      #Create a Metadata Service Application
      if((Get-SPServiceApplication |?{$_.TypeName -eq "Managed Metadata Service"})-eq $null)
	  {      
			Write-Host -ForegroundColor Yellow "- Creating Managed Metadata Service:"

            #Create Service App
   			Write-Host -ForegroundColor Yellow " - Creating Managed Metadata Service Application..."
            $MetaDataServiceApp  = New-SPMetadataServiceApplication -Name $config.Services.ManagedMetadata.Name -ApplicationPool $ApplicationPool -DatabaseName $config.Services.ManagedMetadata.DBName -HubUri $config.Services.ManagedMetadata.CTHubUrl
            if (-not $?) { throw "- Failed to create Managed Metadata Service Application" }

            #Create Proxy
			Write-Host -ForegroundColor Yellow " - Creating Managed Metadata Service Application Proxy..."
            $MetaDataServiceAppProxy  = New-SPMetadataServiceApplicationProxy -Name $config.Services.ManagedMetadata.Name -ServiceApplication $MetaDataServiceApp -DefaultProxyGroup
            if (-not $?) { throw "- Failed to create Managed Metadata Service Application Proxy" }
            
			Write-Host -ForegroundColor Yellow "- Done creating Managed Metadata Service."

            #Get the service instance
            $MetadataServiceInstance = (Get-SPService |?{$_.TypeName -eq "Managed Metadata Web Service" -or $_.TypeName -eq "Verwalteter Metadatenwebdienst"})
            if (-not $?) { throw "- Failed to find Managed Metadata Service instance" }

             #Start Service instance
            if($MetadataserviceInstance.AutoProvision -eq $false)
			{ 
                  Write-Host -ForegroundColor Yellow " - Starting Managed Metadata Service Instance..."
                  $MetadataServiceInstance | Start-SPService | Out-Null
                  if (-not $?) { throw "- Failed to start Managed Metadata Service instance" }
            } 

            #Wait
			Write-Host -ForegroundColor Yellow " - Waiting for Managed Metadata Service to provision" -NoNewline
			While ($MetadataserviceInstance.AutoProvision -ne $true) 
			{
				Write-Host -ForegroundColor Yellow "." -NoNewline
				sleep 1
				$MetadataServiceInstance = (Get-SPService |?{$_.TypeName -eq "Managed Metadata Web Service" -or $_.TypeName -eq "Verwalteter Metadatenwebdienst"})
			}
			Write-Host -BackgroundColor Yellow -ForegroundColor Black "Started!"
      }
	  Else {Write-Host "- Managed Metadata Service already exists."}
}

 catch
 {
	Write-Output $_ 
 }
}

Trace "Preconfigure User Profile Service" { 
	try
    {
        #get coresponding accounts 
        $accounts = $config.Services.UserProfileService.Account
        foreach($account in $accounts){
            if($account.Ref -eq "SPFarm"){
                $spfarm = Get-Account($account)
            }elseif($account.Ref -eq "SPASSearchAdmin"){
                $spassearchadmin = Get-Account($account)
            }elseif($account.Ref -eq "SPASServices"){
                $spasservices = Get-Account($account)
            }
        }
        
      #App Pool     
      $ApplicationPool = Get-SPServiceApplicationPool $config.Services.UserProfileService.AppPoolName -ea SilentlyContinue
      if($ApplicationPool -eq $null)
	  { 
            $appoolname=$config.ServiceAppPool.Name
			$appooluser=Get-Account($config.ServiceAppPool.Account)
            $ApplicationPool = New-SPServiceApplicationPool -name $appoolname -account (Get-SPManagedAccount $appooluser.username) 
      }

      #Create a User Profile Service Application
      if((Get-SPServiceApplication |?{$_.TypeName -eq "User Profile Service"})-eq $null)
	  {      
            Write-Host -ForegroundColor Yellow "- Creating User Profile Service"
            #Create Service App
   			Write-Host -ForegroundColor Yellow " - Creating User Profile Service Application..."
            $UserProfileServiceApp  = New-SPProfileServiceApplication -Name $config.Services.UserProfileService.Name -ApplicationPool $ApplicationPool -ProfileDBName $config.Services.UserProfileService.DB.Profile -ProfileSyncDBName $config.Services.UserProfileService.DB.Sync -SocialDBName $config.Services.UserProfileService.DB.Social -MySiteHostLocation $config.Services.UserProfileService.MySiteURL
            if (-not $?) { throw "- Failed to create User Profile Service Application" }

            #Create Proxy
			Write-Host -ForegroundColor Yellow " - Creating User Profile Service Application Proxy..."
            $UserProfileServiceAppProxy  = New-SPProfileServiceApplicationProxy -Name $config.Services.UserProfileService.Name -ServiceApplication $UserProfileServiceApp -DefaultProxyGroup
            if (-not $?) { throw "- Failed to create User Profile Service Application Proxy" }
            
			Write-Host -ForegroundColor Yellow "- Done creating User Profile Service."

            #Get the service instance
            $UserProfileServiceInstance = (Get-SPService |?{$_.TypeName -eq "User Profile Service" -or $_.TypeName -eq "Benutzerprofildienst"})
            if (-not $?) { throw "- Failed to find User Profile Service Instance" }

             #Start Service instance
            if($UserProfileServiceInstance.AutoProvision -eq $false)
			{ 
                  Write-Host -ForegroundColor Yellow " - Starting User Profile Service Instance..."
                  $UserProfileServiceInstance | Start-SPService | Out-Null
                  if (-not $?) { throw "- Failed to start User Profile Service Instance" }
            } 

            #Wait
			Write-Host -ForegroundColor Yellow " - Waiting for User Profile Service to provision" -NoNewline
			While ($UserProfileServiceInstance.AutoProvision -ne $true) 
			{
				Write-Host -ForegroundColor Yellow "." -NoNewline
				sleep 1
				$UserProfileServiceInstance = (Get-SPService |?{$_.TypeName -eq "User Profile Service" -or $_.TypeName -eq "Benutzerprofildienst"})
			}
			Write-Host -BackgroundColor Yellow -ForegroundColor Black "Started!"

      }
	  Else {Write-Host "- User Profile Service already exists."}

      #IIS Reset
      Write-Host "Resetting IIS"
      cmd.exe /c "iisreset /noforce"

      #Set Administrators for User Profile Service
      $UserProfileServiceApplication = (Get-SPServiceApplication |?{$_.TypeName -eq "User Profile Service Application" -or $_.TypeName -eq "Benutzerprofildienst-Anwendung"})
      $UserProfileServiceApplicationSecurity = Get-SPServiceApplicationSecurity $UserProfileServiceApplication -Admin
      $UserProfileServiceApplicationPrincipalUser1 = New-SPClaimsPrincipal -Identity $spassearchadmin.UserName -IdentityType WindowsSamAccountName
      Grant-SPObjectSecurity $UserProfileServiceApplicationSecurity -Principal $UserProfileServiceApplicationPrincipalUser1 -Rights "Retrieve People Data for Search Crawlers"
      Set-SPServiceApplicationSecurity $UserProfileServiceApplication -ObjectSecurity $UserProfileServiceApplicationSecurity -Admin

      #Set Full Control for sa-spservices on Connection Permissions
      $claimType = "http://schemas.microsoft.com/sharepoint/2009/08/claims/userlogonname"
      $claimValue = $spasservices.UserName
      $claim = New-Object Microsoft.SharePoint.Administration.Claims.SPClaim($claimType, $claimValue, "http://www.w3.org/2001/XMLSchema#string", [Microsoft.SharePoint.Administration.Claims.SPOriginalIssuers]::Format("Windows"))
      $claim.ToEncodedString()
 
      $permission = [Microsoft.SharePoint.Administration.AccessControl.SPIisWebServiceApplicationRights]"FullControl"
 
      $SPAclAccessRule = [Type]"Microsoft.SharePoint.Administration.AccessControl.SPAclAccessRule``1"
      $specificSPAclAccessRule = $SPAclAccessRule.MakeGenericType([Type]"Microsoft.SharePoint.Administration.AccessControl.SPIisWebServiceApplicationRights")
      $ctor = $SpecificSPAclAccessRule.GetConstructor(@([Type]"Microsoft.SharePoint.Administration.Claims.SPClaim",[Type]"Microsoft.SharePoint.Administration.AccessControl.SPIisWebServiceApplicationRights"))
      $accessRule = $ctor.Invoke(@([Microsoft.SharePoint.Administration.Claims.SPClaim]$claim, $permission))
 
      $ups = Get-SPServiceApplication | ? { $_.TypeName -eq "User Profile Service Application" -or $_.TypeName -eq "Benutzerprofildienst-Anwendung"}
      $accessControl = $ups.GetAccessControl()
      $accessControl.AddAccessRule($accessRule)
      $ups.SetAccessControl($accessControl)
      $ups.Update()

}

 catch
 {
	Write-Output $_ 
 }
}
#Stop Schritt 4

#Start Schritt 5
#############################################################
# Dieser Schritt muss nur ausfeführt werden, wenn die      !#
# Web Applications unter https laufen                      !#
# Dieses Script wird auf allen Front-End-Servern ausgeführt!#
#############################################################
Trace "Create IIS redirect"{

    #Get XML File
    $webApps = $config.WebApplications.WebApplication
    $webApps | ForEach-Object {
        <#
        variables include the following: 
        1. Sitecollections
        2. All WebApplications in XML File
        3. The Existing IIS-Websites on the Host
        4. The physical path of the new IIS-Website (all are paths are default the same)  
        #>
        $collections = $webApps.SiteCollections.ChildNodes
        $webApps = $config.Configurations.WebApplications.WebApplication
        $existingSites = Get-Website
        $webAppPath = $_.WebSitePath
		
        if($_.hostnamesc -eq "yes"){

		    $_.SiteCollections.ChildNodes | Where-Object {$_.redirect -eq $true} | ForEach-Object {

		        $path = $webAppPath + "SP_" + $_.name + "_Redirect"
		        $iisName = "SP_" + $_.name + "_Redirect"

		        if(!(Test-Path -Path $path )){
		            New-Item -ItemType directory -Path $path 
		        }
                Create-IISSite $path $iisName $existingSites $SiteURL
		    }
        }
        if($_.hostnamesc -eq "no"){
            <#
            Variables include the following: 
            1. The Name of the created IIS-Website
            2. The Physical Path and the Name of the new IIS-Website 
            #>        
            $WebAppIssName = $_.name + "_Redirect"
            $WebAppPhyiscalPath = $webAppPath + $WebAppIssName

            if($_.redirect -eq $true){
                if(!(Test-Path -Path $WebAppPhyiscalPath )){
                        New-Item -ItemType directory -Path $WebAppPhyiscalPath
                }
                Create-IISSite $WebAppPhyiscalPath $WebAppIssName $existingSites $HostHeaderURL 
            }
        }
    }      
}
#Stop Schritt 5

#Start Schritt 6
########################################################################
# Dieser Schritt muss zwingend auf dem Search Server ausgeführt werden!#
########################################################################
Trace "Configure Search Service Application" { 
	try
	{
        #Get ServerName
        $searchServerName= $config.Servers.Server[3].Name

        #Create an Empty Direcotry for the Index
        $IndexLocation=$config.Services.EnterpriseSearch.IndexLocation
        New-Item $IndexLocation -type directory
        if(Test-Path $IndexLocation!=true){
            Write-Host -ForegroundColor Yellow "Create an Empty Index Direcotry Index under D:\Microsoft Office Servers\15.0\Data\Office Server\Applications"
            exit
        }        

        #Start earchService and SearchQueryAndSiteSettingsService Instances
        Start-SPEnterpriseSearchServiceInstance $searchServerName
        Start-SPEnterpriseSearchQueryAndSiteSettingsServiceInstance $searchServerName

        sleep 60

		Write-Host -ForegroundColor Yellow "- Creating Search Application Pool"
        $app = Get-SPServiceApplicationPool -Identity $config.Services.EnterpriseSearch.AppPoolName -ErrorVariable err -ErrorAction SilentlyContinue
        if($app.Name -eq $null){
            $appoolname=$config.Services.EnterpriseSearch.AppPoolName
    		$appooluser=Get-Account($config.Services.EnterpriseSearch.Account[0])
            $app = New-SPServiceApplicationPool -name $appoolname -account (Get-SPManagedAccount $appooluser.username) 
        }

        Write-Host -ForegroundColor Yellow "- Creating Search Application"
        $searchapp = New-SPEnterpriseSearchServiceApplication -name "Search Service Application" -ApplicationPool $app -databaseName  $config.Services.EnterpriseSearch.DBName -DatabaseServer $dbserver
        $proxy = New-SPEnterpriseSearchServiceApplicationProxy -name "Search Service Application Proxy" -SearchApplication "Search Service Application"
        
        #Set Default Crawl Account
        $crawlaccount=Get-Account($config.Services.EnterpriseSearch.Account[1])
        $searchApp | Set-SPEnterpriseSearchServiceApplication -DefaultContentAccessAccountName $crawlaccount.Username -DefaultContentAccessAccountPassword $crawlaccount.Password
        
        #Get Search Instance
        $searchInstance = Get-SPEnterpriseSearchServiceInstance $searchServerName
        
        #Get Serach Topology
        $InitialSearchTopology = $searchapp | Get-SPEnterpriseSearchTopology -Active 

        #New Search Topology
        $SearchTopology = $searchapp | New-SPEnterpriseSearchTopology 

        #Create Administration Component and Processing Component
        New-SPEnterpriseSearchAdminComponent -SearchTopology $SearchTopology -SearchServiceInstance $searchInstance
        New-SPEnterpriseSearchAnalyticsProcessingComponent -SearchTopology $SearchTopology -SearchServiceInstance $searchInstance
        New-SPEnterpriseSearchContentProcessingComponent -SearchTopology $SearchTopology -SearchServiceInstance $searchInstance
        New-SPEnterpriseSearchQueryProcessingComponent -SearchTopology $SearchTopology -SearchServiceInstance $searchInstance

        #New Crawl Component
        New-SPEnterpriseSearchCrawlComponent -SearchTopology $SearchTopology -SearchServiceInstance $searchInstance 

        #Index (Query) Component
        New-SPEnterpriseSearchIndexComponent -SearchTopology $SearchTopology -SearchServiceInstance $searchInstance -RootDirectory $IndexLocation 

        #new Search Topology
        $SearchTopology | Set-SPEnterpriseSearchTopology 
	}
	catch
	{	Write-Output $_
	}
}

Trace "Configure Search Settings" { 
	try
{
    #--------------------------------------------
    # Get Web App URLs
    # Loads all existing Web App Urls
    # Finds MySite Host Url
    #--------------------------------------------
    $WebAppUrls = @();   #Create an empty Array to store Web App URLs
    $MySiteUrl = "";     #Stores MySite Url

    foreach($wa in Get-SPWebApplication)
    {
       $sc = Get-SPWeb -Identity $wa.Url

       if ($sc.WebTemplate -eq "SPSMSITEHOST")
       {
          Write-Host "MySite found: " $sc.Url;
          $MySiteUrl = $wa.Url;
		  $WebAppUrls += $wa.Url;
       }
       else
       {
          Write-Host "WebApp found: " $sc.url;
          $WebAppUrls += $wa.Url;
       }
    }


    #--------------------------------------------
    # Get Search Service Application
    #--------------------------------------------
    $SearchServiceApplication = Get-SPEnterpriseSearchServiceApplication -ErrorAction SilentlyContinue


    #--------------------------------------------
    # Get all Search Service Content Sources
    #--------------------------------------------
    $DefaultContentSource = $null;
    $PeopleSearchContentSource = $null;

    $ContentSources = Get-SPEnterpriseSearchCrawlContentSource -SearchApplication $SearchServiceApplication

    $ContentSources | ForEach-Object {
        if ($_.Name.ToString() -eq "Local SharePoint sites" -or $_.Name.ToString() -eq "Lokale SharePoint-Websites")
        {
            Write-Host "Default Content Source found";
            $DefaultContentSource = $_;
        }
        if ($_.Name.ToString() -eq "People Search")
        {
            Write-Host "People Search Content Source found";
            $PeopleSearchContentSource = $_;
        }
    }


    #--------------------------------------------
    # Build People Search Url
    #--------------------------------------------

    if ($MySiteUrl -ne $null)
    { 
        # Replace https:// with sps3s:// for SSL Connections   
        if ($MySiteUrl.StartsWith("https://"))
        {
            $spsUrl = $MySiteUrl -replace "https://", "sps3s://"
        }
 
        # Replace https:// with sps3s:// for SSL Connections   
        if ($MySiteUrl.StartsWith("http://"))
        {
            $spsUrl = $MySiteUrl -replace "http://", "sps3://"
        }   
    }


    #--------------------------------------------
    # Modify Default Search Content Source
    #--------------------------------------------

    #Check for People Search Url. If found, Remove it.
    if ($DefaultContentSource -ne $null -and $spsUrl -ne $null)
    {
        if ($DefaultContentSource.StartAddresses.Exists($spsUrl))
        {
            $DefaultContentSource.StartAddresses.Remove($spsUrl);
            $DefaultContentSource.Update();
        }
    }

    #Add all WebApp Urls
    if ($DefaultContentSource -ne $null)
    {
        foreach ($wa in $WebAppUrls)
        {
            if (!$DefaultContentSource.StartAddresses.Exists($wa))
            {
              $DefaultContentSource.StartAddresses.Add($wa);
            }
        }
        $DefaultContentSource.Update();
    }

    #Remove obsolete Urls in Default Content Source
    if ($DefaultContentSource -ne $null)
    {
        $UrlsToRemove = @();
        foreach ($cu in $DefaultContentSource.StartAddresses)
        {
            if ($WebAppUrls.Contains($cu))
            {
                Write-Host $cu is valid
            }
            else
            {
                Write-Host $cu is not valid
                $UrlsToRemove += $cu;
            }
        }

        if ($UrlsToRemove.Count -gt 0)
        {
            foreach ($u in $UrlsToRemove)
            {
                $DefaultContentSource.StartAddresses.Remove($u);
            }
                $DefaultContentSource.Update();
        }   
    }


    #--------------------------------------------
    # Set Crawl Schedules for Default Search Content Source
    #--------------------------------------------
    if ($DefaultContentSource -ne $null)
    {
        # Enable Continuous Crawl
        $DefaultContentSource | Set-SPEnterpriseSearchCrawlContentSource -EnableContinuousCrawls $True
        # Set interval to specific time
        # Microsoft default 15 minutes https://technet.microsoft.com/de-CH/library/jj219802.aspx
        $SearchServiceApplication.SetProperty("ContinuousCrawlInterval",15)
        $SearchServiceApplication.Update()
        
        # Full Crawl Schedule
        $DefaultContentSource | Set-SPEnterpriseSearchCrawlContentSource -ScheduleType Full -DailyCrawlSchedule -CrawlScheduleStartDateTime "2:00 AM" -CrawlScheduleRunEveryInterval 1 -Confirm:$false;

        # Increment Crawl Schedule
        $DefaultContentSource | Set-SPEnterpriseSearchCrawlContentSource -ScheduleType Incremental -DailyCrawlSchedule -CrawlScheduleStartDateTime "12:00 AM" -CrawlScheduleRunEveryInterval 1 -CrawlScheduleRepeatInterval 240  -CrawlScheduleRepeatDuration 1440 -Confirm:$false;
    }


    #--------------------------------------------
    # Create or Modify People Search Content Source
    #--------------------------------------------

    if ($PeopleSearchContentSource -ne $null -and $spsUrl -ne $null)
    {
        # People Search Content Source exists. Checking configuration.
        Write-Host "People Search Content Source exists. Checking configuration."
    
        # Check sps3 Url
        if ($PeopleSearchContentSource.StartAddresses.Exists($spsUrl))
        {
            Write-Host "SPS3 Url already exists."
        }
        else
        {
            $PeopleSearchContentSource.StartAddresses.Add($spsUrl);
            $PeopleSearchContentSource.Update();
        }

        # Remove obsolet Urls
        $PeopleUrlsToRemove = @();
        foreach ($pu in $PeopleSearchContentSource.StartAddresses)
        {
            if ($pu -ne $spsUrl)
            {
                $PeopleUrlsToRemove += $pu;
            }
        }

        if ($PeopleUrlsToRemove.Count -gt 0)
        {
            foreach ($p in $PeopleUrlsToRemove)
            {
                $PeopleSearchContentSource.StartAddresses.Remove($p);
            }
                $PeopleSearchContentSource.Update();
        }   

        # Check Search Priority and set to High
        if ($PeopleSearchContentSource.CrawlPriority -eq "Normal")
        {
            $PeopleSearchContentSource.CrawlPriority = "High";
            $PeopleSearchContentSource.Update();
        }
    }

    if ($PeopleSearchContentSource -eq $null -and $spsUrl -ne $null)
    {
        # People Search Content Source does not exist. Creating it.
        Write-Host "People Search Content Source not found. Creating it."
        $PeopleSearchContentSource = New-SPEnterpriseSearchCrawlContentSource -SearchApplication $SearchServiceApplication -Type SharePoint -Name "People Search" -StartAddresses $spsUrl -MaxSiteEnumerationDepth 0 -CrawlPriority High
        Write-Host "People Search Content created."
    }


    #--------------------------------------------
    # Set Crawl Schedules for People Search Content Source
    #--------------------------------------------
    if ($PeopleSearchContentSource -ne $null)
    {
        # Full Crawl Schedule
        $PeopleSearchContentSource | Set-SPEnterpriseSearchCrawlContentSource -ScheduleType Full -DailyCrawlSchedule -CrawlScheduleStartDateTime "1:00 AM" -CrawlScheduleRunEveryInterval 1 -Confirm:$false;

        # Increment Crawl Schedule
        $PeopleSearchContentSource | Set-SPEnterpriseSearchCrawlContentSource -ScheduleType Incremental -DailyCrawlSchedule -CrawlScheduleStartDateTime "12:00 AM" -CrawlScheduleRunEveryInterval 1 -CrawlScheduleRepeatInterval 30  -CrawlScheduleRepeatDuration 1440 -Confirm:$false;
    }


    #--------------------------------------------
    # Get Default Content Access Account
    #--------------------------------------------
    $SearchServiceApplication = Get-SPEnterpriseSearchServiceApplication
    $c= New-Object Microsoft.Office.Server.Search.Administration.Content($SearchServiceApplication);
    $DefaultContentAccessAccount = $c.DefaultGatheringAccount;


    #--------------------------------------------
    # Add UPS Permissions for Default Crawl Account
    #--------------------------------------------
    if ($DefaultContentAccessAccount -ne $null)
    {
        Write-Host "Adding UPS Permissions for Default Crawl Account" $DefaultContentAccessAccount;
        $ups = Get-SPServiceApplication | where {$_.TypeName -eq "User Profile Service Application" -or $_.TypeName -eq "Benutzerprofildienst-Anwendung"}
        $security = Get-SPServiceApplicationSecurity $ups -Admin
        $principalCrawlAccount = New-SPClaimsPrincipal -Identity $DefaultContentAccessAccount -IdentityType WindowsSamAccountName
        Grant-SPObjectSecurity $security -Principal $principalCrawlAccount -Rights "Retrieve People Data for Search Crawlers"
        Set-SPServiceApplicationSecurity $ups -ObjectSecurity $security -Admin
    }

}

 catch
 {
	Write-Output $_ 
 }
}
#Stop Schritt 6


##########################################################
# ----------------------- Optional ----------------------#
# --- nur für SharePoint Server Standard / Enterprise ---#
##########################################################
Trace "Preconfigure Visio Graphics Service Application" { 
	try
{

      #App Pool     
      $ApplicationPool = Get-SPServiceApplicationPool -Identity $config.Services.VisioGraphicsService.AppPoolName

      #Create a Visio Graphics Service Application
      if((Get-SPServiceApplication |?{$_.TypeName -eq "Visio Graphics Service Application"})-eq $null)
	  {      
			Write-Host -ForegroundColor Yellow "- Creating Visio Graphics Service Application:"

            #Create Service App
   			Write-Host -ForegroundColor Yellow " - Creating Visio Graphics Service Application..."
            $VisioGraphicsServiceApp  = New-SPVisioServiceApplication -Name $config.Services.VisioGraphicsService.Name -ApplicationPool $ApplicationPool
            if (-not $?) { throw "- Failed to create Visio Graphics Service Application" }

            #Create Proxy
			Write-Host -ForegroundColor Yellow " - Creating Visio Graphics Service Application Proxy..."
            $VisioGraphicsServiceAppProxy  = New-SPVisioServiceApplicationProxy -Name $config.Services.VisioGraphicsService.Name -ServiceApplication $config.Services.VisioGraphicsService.Name
            if (-not $?) { throw "- Failed to create Visio Graphics Service Application Proxy" }
            
			Write-Host -ForegroundColor Yellow "- Done creating Visio Graphics Service Application."

            #Get the service instance
            $VisioGraphicsServiceInstance = (Get-SPService |?{$_.TypeName -eq "Visio Graphics Service" -or $_.TypeName -eq "Visio-Grafikdienst"})
            if (-not $?) { throw "- Failed to find Visio Graphics Service Application instance" }

             #Start Service instance
            if($VisioGraphicsServiceInstance.AutoProvision -eq $false)
			{ 
                  Write-Host -ForegroundColor Yellow " - Starting Visio Graphics Service Application Instance..."
                  $VisioGraphicsServiceInstance | Start-SPService | Out-Null
                  if (-not $?) { throw "- Failed to start Visio Graphics Service Application instance" }
            } 

            #Wait
			Write-Host -ForegroundColor Yellow " - Waiting for Visio Graphics Service Application to provision" -NoNewline
			While ($VisioGraphicsServiceInstance.AutoProvision -ne $true) 
			{
				Write-Host -ForegroundColor Yellow "." -NoNewline
				sleep 1
				$VisioGraphicsServiceInstance = (Get-SPService |?{$_.TypeName -eq "Visio Graphics Service" -or $_.TypeName -eq "Visio-Grafikdienst"})
			}
			Write-Host -BackgroundColor Yellow -ForegroundColor Black "Started!"
      }
	  Else {Write-Host "- Visio Graphics Service Application already exists."}
}

 catch
 {
	Write-Output $_ 
 }
}

Trace "Set up APP Service" { 
    try
    {

		# Configure Subscription Service #
		##################################
		
		Write-Host "Configure Subscription Service"
		$appPoolSubSvc = Get-SPServiceApplicationPool -Identity $config.Services.Apps.Subscription.AppPoolName
		$appSubSvc = New-SPSubscriptionSettingsServiceApplication –ApplicationPool $appPoolSubSvc –Name $config.Services.Apps.Subscription.ServiceName –DatabaseName $config.Services.Apps.Subscription.DBName
		$proxySubSvc = New-SPSubscriptionSettingsServiceApplicationProxy –ServiceApplication $appSubSvc

		$service = Get-SPService | Where {$_.TypeName -eq "Microsoft SharePoint Foundation Subscription Settings Service" -or $_.TypeName -eq "Microsoft SharePoint Foundation-Abonnementeinstellungendienst"} 
		If ($service.AutoProvision -eq $false) 
		{
			try
			{
				Write-Host "- Starting Microsoft SharePoint Foundation Subscription Settings Service..."
				$service | Start-SPService | Out-Null
				If (-not $?) {throw}
			}
			catch {"- An error occurred starting the Microsoft SharePoint Foundation Subscription Settings Service"}
		}

		# Configure App Management Service #
		####################################

		Write-Host "Configure App Management Service"
		$appPoolAppSvc = get-SPServiceApplicationPool -Identity $config.Services.Apps.AppPoolName
		$appAppSvc = New-SPAppManagementServiceApplication -ApplicationPool $appPoolAppSvc -Name $config.Services.Apps.ServiceName -DatabaseName $config.Services.Apps.DBName 
		$proxyAppSvc = New-SPAppManagementServiceApplicationProxy -ServiceApplication $appAppSvc -Name $config.Services.Apps.ServiceName

		$service = Get-SPService | Where {$_.TypeName -eq "App Management Service"-or $_.TypeName -eq "App-Verwaltungsdienst"} 
		If ($service.AutoProvision -eq $false) 
		{
			try
			{
				Write-Host "- Starting App Management Service ..."
				$service | Start-SPServiceInstance | Out-Null
				If (-not $?) {throw}
			}
			catch {"- An error occurred starting the App Management Service "}
		}
		

        # Follow Up #
        #############
        Write-Host "Add App Domain and Prefix"
        Set-SPAppDomain $config.Services.Apps.AppDomain
        Set-SPAppSiteSubscriptionName -Name $config.Services.Apps.AppPrefix -Confirm:$false
        $wa = Get-SPWebApplication -Identity $config.Services.Apps.BindingWebApp

        Write-Host -ForegroundColor Yellow "Bind the AppDomain Wildcard Certificate with a new IP on the correct IIS WebSite on all WFE servers"

        Write-Host "Create App Catalog SiteCollection on the specific WebApp"

    
        #Use this for creating path-based site collections (Appcatalog)
        foreach($sc in Get-SPSite -WebApplication $wa -Limit All | where {$_.ServerRelativeUrl -eq "/" -and $_.HostHeaderIsSiteName -eq $False -and $_.Url -notlike "*sitemaster*"}){
            #Check Managed Path exists
            $managedPaths = Get-SPManagedPath -WebApplication $sc.WebApplication | where {$_.Name -eq $config.Services.Apps.AppCatalog.ManagePath}
            if($managedPaths -eq $null){
                New-SPManagedPath -Explicit $config.Services.Apps.AppCatalog.ManagePath -WebApplication $sc.WebApplication
            }
            $spadmin = $config.WebApplications.spadmin
            $contentDBName = $sc.ContentDatabase.Name+"_"+$config.Services.Apps.AppCatalog.ManagePath
            $contentDB = New-SPContentDatabase -Name $contentDBName -WebApplication $sc.WebApplication -MaxSiteCount 1 -WarningSiteCount 0
            $url=$sc.Url+"/"+$config.Services.Apps.AppCatalog.ManagePath
            New-SPSite -url $url -OwnerAlias $spadmin -Name $config.Services.Apps.AppCatalog.Name -Template $config.Services.Apps.AppCatalog.template -language $config.Services.Apps.AppCatalog.language -ContentDatabase $contentDB | Out-Null
            Write-Host "Set App Catalog for the WebApp"
            Update-SPAppCatalogConfiguration -Site $url -Force:$true
        }

    
        #Use this for createing a Host Named Site Collection (Appcatalog)
        foreach($sc in Get-SPSite -WebApplication $wa -Limit All | where {$_.ServerRelativeUrl -eq "/" -and $_.HostHeaderIsSiteName -eq $True -and $_.Url -notlike "*sitemaster*"}){
            #Check Managed Path exists
            $managedPaths = Get-SPManagedPath -HostHeader | where {$_.Name -eq $config.Services.Apps.AppCatalog.ManagePath}
            if($managedPaths -eq $null){
                New-SPManagedPath -Explicit $config.Services.Apps.AppCatalog.ManagePath -HostHeader
            }
            $spadmin = $config.WebApplications.spadmin
            $contentDBName = $sc.ContentDatabase.Name+"_"+$config.Services.Apps.AppCatalog.ManagePath
            $contentDB = New-SPContentDatabase -Name $contentDBName -WebApplication $sc.WebApplication -MaxSiteCount 1 -WarningSiteCount 0
            $url=$sc.Url+"/"+$config.Services.Apps.AppCatalog.ManagePath
            New-SPSite -url $url -OwnerAlias $spadmin -Name $config.Services.Apps.AppCatalog.Name -Template $config.Services.Apps.AppCatalog.template -language $config.Services.Apps.AppCatalog.language -ContentDatabase $contentDB -HostHeaderWebApplication $sc.WebApplication | Out-Null
            Write-Host "Set App Catalog for the WebApp"
            Update-SPAppCatalogConfiguration -Site $url -Force:$true
        }
    }
    catch
    {
	    Write-Host "Error has occured"    
    }
}


Trace "Set up ACCESS Service" { 
    try
    {

    # check Prerequistis SQL and SP --> http://www.microsoft.com/en-us/download/details.aspx?id=30445
    
    $account = Get-Account($config.Services.AccessService.Account)
    $appPoolAccess = New-SPServiceApplicationPool -Name $config.Services.AccessService.AppPoolName -Account (Get-SPManagedAccount $account.UserName)
    $asaccess = New-SPAccessServicesApplication -Name $config.Services.AccessService.ServiceName -ApplicationPool $appPoolAccess -Default -DatabaseServer $config.Services.AccessService.SQLServerAlias -Verbose

    $service = Get-SPService | Where {$_.TypeName -eq "Access Services"} 
    If ($service.AutoProvision -eq $false) 
    {
        try
        {
    	    Write-Host "- Starting Access Services ..."
    	    $service | Start-SPServiceInstance | Out-Null
    	    If (-not $?) {throw}
        }
        catch {"- An error occurred starting the Access Services"}
    }

    #Special IIS App Pool Settings
    $appPoolAccess = Get-SPServiceApplicationPool -Identity $config.Services.AccessService.AppPoolName
    write-host "Set Load User Profile settings to true from the ServiceApplication Pool with the ID:" $appPoolAccess.Id -ForegroundColor Red
    write-host "Restart the Server afterwards!!!" -ForegroundColor White -BackgroundColor Red

    #Cofigure Application Database Server
    # - Run Step 1 again
    $asaccess = Get-SPAccessServicesApplication
    If($asaccess.DisplayName -ne $config.Services.AccessService.ServiceName){
        Write-Host "There are multiple Access Service --> Make sure the right is selected" -ForegroundColor Red
    }else{
        $context = [Microsoft.SharePoint.SPServiceContext]::GetContext($asaccess.ServiceApplicationProxyGroup, [Microsoft.SharePoint.SPSiteSubscriptionIdentifier]::Default)
        $sqlServerName = $config.Services.AccessService.SQLServerAlias
        $serverGroupName = 'DEFAULT'
        $newdbserver = New-SPAccessServicesDatabaseServer -ServiceContext $context -DatabaseServerName $sqlServerName -DatabaseServerGroup $serverGroupName -AvailableForCreate $true -Verbose
    }

    #GrantFull Admin to Access Account to specific WebApps --> Exclud with where -ne
    $account = Get-Account($config.Services.AccessService.Account)
    Get-SPWebApplication | where  {$_.DisplayName -ne "SP_HHApps"} | foreach { 
        $webApp = $_ 
        $WebApp.GrantAccessToProcessIdentity($account.UserName)    
    }

    #Permission to App MAnagement Service
    # - Account sa-spaccess need full control on App Management Service --> do it over mermission Permission in Servie Application view
    Add-SPShellAdmin $config.Services.AccessService.Account
    Get-SPShellAdmin

    # sa-spaccess benötigt read und write access auf folgStop Share C:\ProgramData\Microsoft\SharePoint\Config
    # http://blogs.msdn.com/b/kaevans/archive/2013/07/14/access-services-2013-setup-for-an-on-premises-installation.aspx

    # Cleint Settings
    # -Cleint Regional Settings have to be set to English United States

    }
    catch
    {
	    Write-Host "Error has occured"    
    }
}

Trace "Preconfigure Secure Store Service" { 
	try
{
      #Variabeln festlegen
      if ($config.Farm.Passphrase.Length -gt 0) {
          $passphrase = (ConvertTo-SecureString $config.Farm.Passphrase -AsPlainText -force)
      } else {
          Write-Warning "You didn't enter a farm passphrase, using the Farm Administrator's password instead"
          $passphrase = $farmAcct.Password
      }

      #App Pool     
      $ApplicationPool = Get-SPServiceApplicationPool $config.Services.SecureStore.AppPoolName -ea SilentlyContinue
      if($ApplicationPool -eq $null)
	  { 
            $appoolname=$config.ServiceAppPool.Name
			$appooluser=Get-Account($config.ServiceAppPool.Account)
            $ApplicationPool = New-SPServiceApplicationPool -name $appoolname -account (Get-SPManagedAccount $appooluser.username) 
      }

      #Create a Secure Store Service Application
      if((Get-SPServiceApplication |?{$_.TypeName -eq "Secure Store Service"})-eq $null)
	  {      
			Write-Host -ForegroundColor Yellow "- Creating Secure Store Service:"
            #Get the service instance
            $SecureStoreServiceInstance = (Get-SPServiceInstance |?{$_.TypeName -eq "Secure Store Service"})
            if (-not $?) { throw "- Failed to find Secure Store service instance" }

             #Start Service instance
            if($SecureStoreServiceInstance.Status -eq "Disabled")
			{ 
                  Write-Host -ForegroundColor Yellow " - Starting Secure Store Service Instance..."
                  $SecureStoreServiceInstance | Start-SPServiceInstance | Out-Null
                  if (-not $?) { throw "- Failed to start Secure Store service instance" }
            } 

            #Wait
			Write-Host -ForegroundColor Yellow " - Waiting for Secure Store service to provision" -NoNewline
			While ($SecureStoreServiceInstance.Status -ne "Online") 
			{
				Write-Host -ForegroundColor Yellow "." -NoNewline
				sleep 1
				$SecureStoreServiceInstance = (Get-SPServiceInstance |?{$_.TypeName -eq "Secure Store Service"})
			}
			Write-Host -BackgroundColor Yellow -ForegroundColor Black "Started!"

            #Create Service App
   			Write-Host -ForegroundColor Yellow " - Creating Secure Store Service Application..."
            $SecureStoreServiceApp  = New-SPSecureStoreServiceApplication -Name $config.Services.SecureStore.Name -ApplicationPool $ApplicationPool -AuditingEnabled:$false -DatabaseServer $dbserver -DatabaseName $config.Services.SecureStore.DBName
            if (-not $?) { throw "- Failed to create Secure Store Service Application" }

            #create proxy
			Write-Host -ForegroundColor Yellow " - Creating Secure Store Service Application Proxy..."
            $SecureStoreServiceAppProxy  = New-SPSecureStoreServiceApplicationProxy -Name "Secure Store Service Application Proxy" -ServiceApplication $SecureStoreServiceApp -DefaultProxyGroup
            if (-not $?) { throw "- Failed to create Secure Service Application Proxy" }
            
			Write-Host -ForegroundColor Yellow "- Done creating Secure Store Service."

            #IIS Reset
            Write-Host "Resetting IIS"
            cmd.exe /c "iisreset /noforce"

            #Set Administrators for User Profile Service
            $SecureStoreServiceApp = (Get-SPServiceApplication |?{$_.TypeName -eq "Secure Store Service Application"})
            $SecureStoreServiceAppSecurity = Get-SPServiceApplicationSecurity $SecureStoreServiceApp -Admin
            $SecureStoreServiceAppPrincipalUser1 = New-SPClaimsPrincipal -Identity $config.WebApplications.spadmin -IdentityType WindowsSamAccountName
            Grant-SPObjectSecurity $SecureStoreServiceAppSecurity -Principal $SecureStoreServiceAppPrincipalUser1 -Rights "Full Control"
            Set-SPServiceApplicationSecurity $SecureStoreServiceApp -ObjectSecurity $SecureStoreServiceAppSecurity -Admin

            Update-SPSecureStoreMasterKey -ServiceApplicationProxy $SecureStoreServiceAppProxy -Passphrase $passphrase
      }
	  Else {Write-Host "- Secure Store Service already exists."}
}

 catch
 {
	Write-Output $_ 
 }
}

Trace "Configure Secure Store Settings for Collaboration Manager" { 
	try
{
            #Target Application für Collaboration Manager
            Write-Host -ForegroundColor Green "- Configure now the Secure Store Target Application for Collaboration Manager`n"
            $targetAppAdmin = $config.WebApplications.spadmin
            $farmAccount = $config.Accounts.Account[0].Name
            $farmPassword = $config.Accounts.Account[0].Password
            $selectedWebApplication = Get-SPWebApplication -includecentraladministration | where {$_.IsAdministrationWebApplication} | Select-Object -ExpandProperty Url
            $UserNameField = New-SPSecureStoreApplicationField -name "Windows User Name" -type WindowsUserName -masked:$false
            $PasswordField = New-SPSecureStoreApplicationField -name "Windows Password" -type WindowsPassword -masked:$true 
            $fields = $UserNameField, $PasswordField
            $targetApp = New-SPSecureStoreTargetApplication -Name "Collaboration Manager" -FriendlyName "Collaboration Manager" -ContactEmail $config.Farm.Email.FromAddress -ApplicationType Group
            $targetAppAdminAccount = New-SPClaimsPrincipal -Identity $targetAppAdmin -IdentityType WindowsSamAccountName
            $targetGroupAccount = New-SPClaimsPrincipal -EncodedClaim "c:0!.s|windows"
            $defaultServiceContext = Get-SPServiceContext $selectedWebApplication
            $ssApp = New-SPSecureStoreApplication -ServiceContext $defaultServiceContext -TargetApplication $targetApp -Administrator $targetAppAdminAccount -Fields $fields -CredentialsOwnerGroup $targetGroupAccount
            # Convert values to secure strings
            $secureUserName = ConvertTo-SecureString $farmAccount -asplaintext -force
            $securePassword = ConvertTo-SecureString $farmPassword -asplaintext -force
            $credentialValues = $secureUserName, $securePassword
            # Fill in the values for the fields in the target application
            Update-SPSecureStoreGroupCredentialMapping -Identity $ssApp -Values $credentialValues

            Write-Host -ForegroundColor Green "- Done creating Secure Store Target Application."

            #Target Application für Collaboration Manager App
            Write-Host -ForegroundColor Green "- Configure now the Secure Store Target Application for Collaboration Manager App`n"
            $targetAppAdmin = $config.WebApplications.spadmin
            $farmAccount = $config.Accounts.Account[1].Name
            $farmPassword = $config.Accounts.Account[1].Password
            $selectedWebApplication = Get-SPWebApplication -includecentraladministration | where {$_.IsAdministrationWebApplication} | Select-Object -ExpandProperty Url
            $UserNameField = New-SPSecureStoreApplicationField -name "Windows User Name" -type WindowsUserName -masked:$false
            $PasswordField = New-SPSecureStoreApplicationField -name "Windows Password" -type WindowsPassword -masked:$true 
            $fields = $UserNameField, $PasswordField
            $targetApp = New-SPSecureStoreTargetApplication -Name "Collaboration Manager App" -FriendlyName "Collaboration Manager App" -ContactEmail $config.Farm.Email.FromAddress -ApplicationType Group
            $targetAppAdminAccount = New-SPClaimsPrincipal -Identity $targetAppAdmin -IdentityType WindowsSamAccountName
            $targetGroupAccount = New-SPClaimsPrincipal -EncodedClaim "c:0!.s|windows"
            $defaultServiceContext = Get-SPServiceContext $selectedWebApplication
            $ssApp = New-SPSecureStoreApplication -ServiceContext $defaultServiceContext -TargetApplication $targetApp -Administrator $targetAppAdminAccount -Fields $fields -CredentialsOwnerGroup $targetGroupAccount
            # Convert values to secure strings
            $secureUserName = ConvertTo-SecureString $farmAccount -asplaintext -force
            $securePassword = ConvertTo-SecureString $farmPassword -asplaintext -force
            $credentialValues = $secureUserName, $securePassword
            # Fill in the values for the fields in the target application
            Update-SPSecureStoreGroupCredentialMapping -Identity $ssApp -Values $credentialValues

            Write-Host -ForegroundColor Green "- Done creating Secure Store Target Application."
}

 catch
 {
	Write-Output $_ 
 }
}