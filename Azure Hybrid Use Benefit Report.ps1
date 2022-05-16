$ErrorActionPreference = 'Inquire'
Set-Item Env:\SuppressAzurePowerShellBreakingChangeWarnings "true"

$vms = @()
$dbs = @()
$pools = @()

$vmSizeCache = @{}

function Get-VmCores ($vmSize, $vmLocation) {
    
    if ($vmSizeCache.Keys -notcontains $vmLocation) {
        $vmSizeCache.$vmLocation = Invoke-Retry { Get-AzVMSize -location $vmLocation }
    }

    return ($vmSizeCache.$vmLocation | Where-Object { $_.name -eq $vmSize }).NumberOfCores
}


function Get-VmAhb ($vm) {
    if ($vm.LicenseType -match "Windows_.*" ) {
        return $true
    }

    if ($vm.StorageProfile.OsDisk.OsType -eq "Linux") {
        return "HUB is NA for Linux"
    }

    return $false
}

function Get-SqlAhb ($sql) {
    $ahb = "Unknown"


    # return early with things that exclude potential AHUB use... since "LicenseType" is inaccurate for e.g. EPs
    # 
    if (($sql.SkuName -eq "ElasticPool") -or ($sql.CurrentServiceObjectiveName -eq "ElasticPool")) {
        return "DB is in an Elastic Pool. See EP report for AHUB status."
    }

    if ($sql.CurrentServiceObjectiveName -like "*_S_*") {
        # serverless
        return "AHUB is not an option for this DB due to its Serverless compute tier."
    }

    if (@("Free", "Standard", "Basic") -contains $sql.SkuName) {
        return "AHB is not available for this Azure SQL Database SKU"
    }


    # these are valid, except EPs as described above
    # 
    if ($null -eq $sql.LicenseType) {
        #  LicenseType is null, DB could be in an Elastic Pool
        # ?? ms?
    }

    if ($sql.LicenseType -eq "BasePrice") { 
        return $true 
    }

    if ($sql.LicenseType -eq "LicenseIncluded") { 
        return $false
    }

    return $ahb
}

function Invoke-Retry() {
    # stolen shamelessly from https://stackoverflow.com/a/57503237 with slight adjustments
    [CmdletBinding()]
    param(
        [parameter(Mandatory = $true, ValueFromPipeline)][ValidateNotNullOrEmpty()][scriptblock]$action,
        [Parameter(Mandatory = $false)][int]$maxAttempts = 8
    )

    $attempts = 1    
    $ErrorActionPreferenceToRestore = $ErrorActionPreference
    $ErrorActionPreference = "Stop"

    do {
        try {
            Invoke-Command -ScriptBlock $action -OutVariable invokeResult
            break;
        }
        catch [Exception] {
            Write-Host $_.Exception.Message
        }

        # exponential backoff delay
        $attempts++
        if ($attempts -le $maxAttempts) {
            $retryDelaySeconds = [math]::Pow(2, $attempts)
            $retryDelaySeconds = $retryDelaySeconds - 1  # Exponential Backoff Max == (2^n)-1
            Write-Host("Action failed. Waiting " + $retryDelaySeconds + " seconds before attempt " + $attempts + " of " + $maxAttempts + ".")
            Start-Sleep $retryDelaySeconds 
        }
        else {
            $ErrorActionPreference = $ErrorActionPreferenceToRestore
            Write-Error $_.Exception.Message
        }
    } while ($attempts -le $maxAttempts)

    $ErrorActionPreference = $ErrorActionPreferenceToRestore
}


$subs = Invoke-Retry { Get-AzSubscription } | Where-Object { $_.name -match ".*(((jmd|app|ss|gc.)\d+)| 05|ProdCustomerApps|TestDevQa|DevTestQa|Shared Services|Microsoft Azure Enterprise|AD Team).*" }
foreach ($sub in $subs ) {
    Invoke-Retry { Select-AzSubscription -SubscriptionName $sub.Name }

    # note
    # having issues with too many API calls resulting in odd HTTP errors, so.. breaking things up a bit, using a retry function, and should give more visibility if we need to troubleshoot
    

    # because cmdlets like "get-azsqldatabase" require the name of the server (you can't just return all of them), I'm working backwards by
    # first getting them via the generic "get-azresource" to get their server, and then examining them via get-azsqlxxxx later.


    # get all the Az SQL DBs
    $dbResources = Invoke-Retry { Get-AzResource -ResourceType "Microsoft.Sql/servers/databases" }
    # add details we need to these objects
    foreach ($dbResource in $dbResources) {
        $dbServerName = ($dbResource.Name).split('/')[0]
        $dbDatabaseName = ($dbResource.Name).split('/')[1]
    
        # exempt "Master" and "AdminDB" DBs from our results, since they're not AHUB-applicable, and don't need to appear in the reports
        if ( $dbDatabaseName -eq "Master" -or $dbDatabaseName -eq "AdminDB") {
            continue
        }

        # get the properties of the Az SQL database..
        $tmpResult = Invoke-Retry { Get-AzSqlDatabase -DatabaseName $dbDatabaseName -ServerName $dbServerName -ResourceGroupName $dbResource.ResourceGroupName }
        $tmpResult | Add-Member  -MemberType NoteProperty -Name SubscriptionId          -Value $sub.id
        $tmpResult | Add-Member  -MemberType NoteProperty -Name SubscriptionName        -Value $sub.name
        $tmpResult | Add-Member  -MemberType NoteProperty -Name IsAhbEnabled            -Value (Get-SqlAhb -Sql $tmpResult)

        $tmpResult | Add-Member -MemberType NoteProperty -Name TagBillTo                -Value $dbResource.Tags.BillTo
        $tmpResult | Add-Member -MemberType NoteProperty -Name TagDevTeam               -Value $dbResource.Tags.DevTeam
        $tmpResult | Add-Member -MemberType NoteProperty -Name TagEnvironmentName       -Value $dbResource.Tags.EnvironmentName
        $tmpResult | Add-Member -MemberType NoteProperty -Name TagPurpose               -Value $dbResource.Tags.Purpose
        $tmpResult | Add-Member -MemberType NoteProperty -Name TagSubEnvironmentName    -Value $dbResource.Tags.SubEnvironmentName
        $tmpResult | Add-Member -MemberType NoteProperty -Name TagAll                   -Value ($dbResource.Tags | ConvertTo-Json)
        
        $dbs += $tmpResult
    }


    # get all the Az SQL Elastic Pools
    $poolResources = Invoke-Retry { Get-AzResource -ResourceType "Microsoft.Sql/servers/elasticpools" }
    # add details we need to these objects
    foreach ($poolResource in $poolResources) {
        $poolServerName = ($poolResource.Name).split('/')[0]
        $poolElasticPoolName = ($poolResource.Name).split('/')[1]

        $tmpResult = Invoke-Retry { Get-AzSqlElasticPool -ElasticPoolName $poolElasticPoolName -ServerName $poolServerName -ResourceGroupName $poolResource.ResourceGroupName }
        $tmpResult | Add-Member -MemberType NoteProperty -Name SubscriptionId           -Value $sub.id
        $tmpResult | Add-Member -MemberType NoteProperty -Name SubscriptionName         -Value $sub.name
        $tmpResult | Add-Member -MemberType NoteProperty -Name IsAhbEnabled             -Value (Get-SqlAhb -Sql $tmpResult)
        
        $tmpResult | Add-Member -MemberType NoteProperty -Name TagBillTo                -Value $poolResource.Tags.BillTo
        $tmpResult | Add-Member -MemberType NoteProperty -Name TagDevTeam               -Value $poolResource.Tags.DevTeam
        $tmpResult | Add-Member -MemberType NoteProperty -Name TagEnvironmentName       -Value $poolResource.Tags.EnvironmentName
        $tmpResult | Add-Member -MemberType NoteProperty -Name TagPurpose               -Value $poolResource.Tags.Purpose
        $tmpResult | Add-Member -MemberType NoteProperty -Name TagSubEnvironmentName    -Value $poolResource.Tags.SubEnvironmentName
        $tmpResult | Add-Member -MemberType NoteProperty -Name TagAll                   -Value ($poolResource.Tags | ConvertTo-Json)
        
        $pools += $tmpResult
    }
 
    foreach ($vm in Invoke-Retry { Get-AzVM }) {
        $vm | Add-Member -MemberType NoteProperty -Name SubscriptionId          -Value $sub.id
        $vm | Add-Member -MemberType NoteProperty -Name SubscriptionName        -Value $sub.name
        $vm | Add-Member -MemberType NoteProperty -Name CoreCount               -Value (Get-VmCores -vmSize $vm.HardwareProfile.VmSize -vmLocation $vm.Location)
        $vm | Add-Member -MemberType NoteProperty -Name OsType                  -Value $vm.StorageProfile.OsDisk.OsType
        $vm | Add-Member -MemberType NoteProperty -Name IsAhbEnabled            -Value (Get-VmAhb -Vm $vm)

        $vm | Add-Member -MemberType NoteProperty -Name TagBillTo               -Value $vm.Tags.BillTo
        $vm | Add-Member -MemberType NoteProperty -Name TagDevTeam              -Value $vm.Tags.DevTeam
        $vm | Add-Member -MemberType NoteProperty -Name TagEnvironmentName      -Value $vm.Tags.EnvironmentName
        $vm | Add-Member -MemberType NoteProperty -Name TagPurpose              -Value $vm.Tags.Purpose
        $vm | Add-Member -MemberType NoteProperty -Name TagSubEnvironmentName   -Value $vm.Tags.SubEnvironmentName
        $vm | Add-Member -MemberType NoteProperty -Name TagAll                  -Value ($vm.Tags | ConvertTo-Json)

        $vms += $vm
    }           
}
 

$vms    | Select-Object -Property SubscriptionId, SubscriptionName, ResourceGroupName, Location, Name, CoreCount, LicenseType, OsType, IsAhbEnabled, TagBillTo, TagDevTeam, TagEnvironmentName, TagPurpose, TagSubEnvironmentName, TagAll -ExcludeProperty HardwareProfile | Export-Csv -Path "C:\temp\VMs.csv" -NoTypeInformation -Force
$dbs    | Select-Object -Property SubscriptionId, SubscriptionName, ResourceGroupName, Location, ServerName, DatabaseName, Edition, SkuName, ElasticPoolName, CurrentServiceObjectiveName, Capacity, LicenseType, IsAhbEnabled, TagBillTo, TagDevTeam, TagEnvironmentName, TagPurpose, TagSubEnvironmentName, TagAll | Export-Csv -Path "C:\temp\SQL Databases.csv" -NoTypeInformation -Force
$pools  | Select-Object -Property SubscriptionId, SubscriptionName, ResourceGroupName, Location, ServerName, ElasticPoolName, Edition, SkuName, Capacity, DTU, LicenseType, IsAhbEnabled, TagBillTo, TagDevTeam, TagEnvironmentName, TagPurpose, TagSubEnvironmentName, TagAll | Export-Csv -Path "C:\temp\SQL Elastic Pools.csv" -NoTypeInformation -Force


