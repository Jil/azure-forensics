<#
.SYNOPSIS
    Performs a digital evidence capture operation on a target VM.
    This script is the optimized version that runs in parallel jobs.

.DESCRIPTION
    This is designed to dump the RAM from Windows through a SYSTEM execution. The
    dump file is created on an Azure share that is mounted during the operation.
    As the target VM is supposedly comrpomised, consider the credentials used to
    mount the share are compromised. Rotate storage encryption keys afterwards.

    This script depends on Az.Accounts, Az.Compute, Az.Storage, and Az.KeyVault being 
    imported in your Azure Automation account and in the Hybrid Runbook Worker.
    See: https://docs.microsoft.com/en-us/azure/automation/az-modules

.EXAMPLE
    Copy-VmMemoryDumpWindows -SubscriptionId ffeeddcc-bbaa-9988-7766-554433221100 -ResourceGroupName rg-finance-vms -VirtualMachineName vm-workstation-001

#>

param (
    # The ID of subscription in which the target Virtual Machine is stored
    [Parameter(Mandatory = $true)]
    [string]
    $SubscriptionId,

    # The Resource Group containing the Virtual Machine
    [Parameter(Mandatory = $true)]
    [string]
    $ResourceGroupName,

    # The name of the target Virtual Machine
    [Parameter(Mandatory = $true)]
    [string]
    $VirtualMachineName
)

#$ErrorActionPreference = 'Stop'

######################################### CoC Constants ###################################################
# Update the following Automation Account Variable with the values related to your environment

$destSubId  = Get-AutomationVariable -Name 'destSubId'  # The subscription containing the storage account being copied to (ex. 00112233-4455-6677-8899-aabbccddeeff)
$destRGName = Get-AutomationVariable -Name 'destRGName' # The name of the resource group containing the storage account being copied to 
$destSAfile = Get-AutomationVariable -Name 'destSAfile' # The name of the storage account for FILE

# Please do not change the following constants
$destSAContainer = 'memory-dumps'                     # The name of the container within the storage account
$snapshotPrefix = (Get-Date).ToString('yyyyMMddHHmm') # The prefix of the snapshot to be created

############################################################################################################
Write-Output "SubscriptionId: $SubscriptionId"
Write-Output "ResourceGroupName: $ResourceGroupName"
Write-Output "VirtualMachineName: $VirtualMachineName"

$swGlobal = [Diagnostics.Stopwatch]::StartNew()

################################## Login session ############################################
# Connect to Azure (via Automation Account Managed Identity)
# The following roles must be granted to the Azure AD identity of the Azure Automation account:
#  - "Contributor" on the Resource Group of target Virtual Machine. This provides snapshot rights on Virtual Machine disks
#  - "Storage Account Contributor" on the immutable SOC Storage Account


Write-Output "Logging in to Azure..."
Connect-AzAccount -Identity
Set-AzContext -Subscription $SubscriptionId


################################## Check VM details #########################################

Write-Output "Checking VM details (OS=Windows,Status=Running)"

$vm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VirtualMachineName

if ((Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VirtualMachineName -Status).Statuses[1].displayStatus -notmatch "running"  ) {
    Write-Error "The target VM $($VirtualMachineName) must be running to dump the RAM."
    Exit  
}

if ($vm.OSProfile.WindowsConfiguration -eq $Null ) {
    Write-Error "The target VM $($VirtualMachineName) must be a Windows VM."
    Exit  
}

Write-Output "Collect target VM network ID"
$net = $vm.NetworkProfile.NetworkInterfaces.Id.Split('/')[-1] 
$subnetId = (Get-AzNetworkInterface -Name $net).IpConfigurations.subnet.id


Write-Output "Moving into destination subscription context"
Set-AzContext -Subscription $destSubId -ErrorAction Stop 

Write-Output "Read destination storage account key"
$storageAccount = Get-AzStorageAccount -ResourceGroupName $destRGName -Name $destSAfile
$keys = $storageAccount | Get-AzStorageAccountKey
$destSAKey =  $keys[0].value

if ($vm.Location -notmatch $storageAccount.Location) {
    Write-Output "The target VM is not in same region as the destination storage. Additional peering is required."
    # TODO: handle it
    Exit
}

Write-Output "Add target VM subnet to destination storage inbound rules"
Add-AzStorageAccountNetworkRule -ResourceGroupName $destRGName -Name $destSAfile -VirtualNetworkResourceId $subnetId



Write-Output "Moving into target VM subscription context"
Set-AzContext -Subscription $SubscriptionId -ErrorAction Stop 

$scriptBlock = @"
If (!(Test-Path "I:")) {
    `$connectTestResult = Test-NetConnection -ComputerName "$destSAfile.file.core.windows.net" -Port 445
    if (`$connectTestResult.TcpTestSucceeded) {
        
        # Save the password so the drive will persist on reboot
        cmd.exe /C "cmdkey /add:``"$destSAfile.file.core.windows.net``" /user:``"localhost\$destSAfile``" /pass:``"$destSAKey``""
        # Mount the drive
        New-PSDrive -Name I -PSProvider FileSystem -Root "\\$destSAfile.file.core.windows.net\$destSAContainer" -Persist
    } else {
        Write-Error -Message "Unable to reach the Azure storage account via port 445. Check to added the target VM network to the $($destSAfile) storage networking settings."
        Exit
    }
}

`$DumpFile = "I:\dump_$VirtualMachineName-$snapshotPrefix.dmp"
Write-Host "Launching DumpIt.exe..."
iex "I:\DumpIt.exe /quiet /output `$DumpFile"
ls I:

Remove-PSDrive -Name I -Force
cmd.exe /C "cmdkey /delete:`"$destSAfile.file.core.windows.net`""
"@

Write-Debug "------ Script executed on the target VM $($VirtualMachineName)"
Write-Debug $scriptBlock
Write-Debug "------"

$invoke = Invoke-AzVMRunCommand -ResourceGroupName $ResourceGroupName -VMName $VirtualMachineName -CommandId "RunPowerShellScript" -ScriptString $scriptBlock -ErrorAction Stop
$invoke.Value 

#################################
# FINAL STATUS
#################################

# Output the job elapsed time
$swGlobal.Stop()
Write-Output "########################################################################"
Write-Output "Operation completed."
Write-Output "Elapsed time for the entire operation: $($swGlobal.Elapsed.TotalMinutes) minutes"
Write-Output ""
Write-Output "NOTE: $snapshotPrefix is the timestamp for the dump file"
Write-Output "Remember that the first encryption key of $($destSAfile) was disclosed on the target VM and must be rotated manually."
Write-Output "The key isn't automatically rotated in case concurrent jobs are dumping memory."
Write-Output "########################################################################"

