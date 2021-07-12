# Input bindings are passed in via param block.
# For the Function App
param($Timer)

######## Variables ##########
# Add the personal host pool name and resource group.
$pooledHp = '<Pooled Host Pool Name>'
$pooledHpRg = '<Pooled Host Pool Resource Group>'
$RessourceTagDrainTime = 'DrainTime'
$LocalTimeZone = "W. Europe Standard Time"

# Add the resource group for the session hosts.
# Update if different from the resource group of the Host Pool
$sessionHostVmRg = $personalHpRg

########## Script Execution ##########

# Cache current Time in UTC
$UTCcurrentTime = Get-Date

# Get the Session Hosts
# Exclude servers in drain mode and do not allow new connections
$sessionHosts = (Get-AzWvdSessionHost -HostPoolName $pooledHp -ResourceGroupName $pooledHpRg | Where-Object { $_.AllowNewSession -eq $true } )
$runningSessionHosts = $sessionHosts | Where-Object { $_.Status -eq "Available" }

#Evaluate the list of running session hosts against 
foreach ($sessionHost in $runningSessionHosts) {
    # Read the Session Host Tags
    $sessionHostTags = Get-AzTag -ResourceID $sessionHost.ResourceId
    [DateTime]$sessionHostDrainTime = $sessionHostTags.Properties.TagsProperty.$($RessourceTagDrainTime)

    # Convert Time to UTC
    $TZ = [System.TimeZoneInfo]::FindSystemTimeZoneById($LocalTimeZone)
    $UTCSessionHostDrainTime = [System.TimeZoneInfo]::ConvertTimeFromUtc($UTCcurrentTime, $TZ)

    $sessionHost = (($sessionHost).name -split { $_ -eq '.' -or $_ -eq '/' })[1]
    if ($UTCSessionHostDrainTime -le $UTCcurrentTime) {
        Write-Host "Server $sessionHost is not in drain mode, setting drain mode to ON"
        try {
            # Stop the VM
            Update-AzWvdSessionHost -HostPoolName $pooledHp -ResourceGroupName $personalHpRg -Name $sessionHost -AllowNewSession:$false
        }
        catch {
            $ErrorMessage = $_.Exception.message
            Write-Error ("Error setting drain mode: " + $ErrorMessage)
            Break
        }
    }
}