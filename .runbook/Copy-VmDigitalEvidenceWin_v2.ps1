<#
.SYNOPSIS
    Performs a digital evidence capture operation on a target VM.
    This script is the optimized version that runs in parallel jobs.

.DESCRIPTION
    This is sample code, please be sure to read
    https://docs.microsoft.com/azure/architecture/example-scenario/forensics/ to get
    all the requirements in place and adapt the code to your environment by replacing
    the placeholders and adding the required code blocks before using it. Key outputs
    are in the script for debug reasons, remove the output after the initial tests to
    improve the security of your script.
    
    This is designed to be run from a Windows Hybrid Runbook Worker in response to a
    digital evidence capture request for a target VM. It will create disk snapshots
    for all disks, copying them to immutable SOC storage, takes the hash of all disks
    if specified in the CalculateHash parameter, and stores them in the SOC Key Vault.

    The hash calculation may require a long time to complete, depending on the algorithm 
    chosen and on the size of the disks. The script will run in parallel jobs (one job 
    for each disk) to speed up the process. The most performant algorithm is SKEIN because
    it reads the disk in chunks of 1MB and merges all the hashes calculated for each chunk.

    This script depends on Az.Accounts, Az.Compute, Az.Storage, and Az.KeyVault being 
    imported in your Azure Automation account and in the Hybrid Runbook Worker.
    See: https://docs.microsoft.com/en-us/azure/automation/az-modules

.EXAMPLE
    Copy-VmDigitalEvidence -SubscriptionId ffeeddcc-bbaa-9988-7766-554433221100 -ResourceGroupName rg-finance-vms -VirtualMachineName vm-workstation-001

.LINK
    https://docs.microsoft.com/azure/architecture/example-scenario/forensics/
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
    $VirtualMachineName,

    # Hash Calculation (Optional. Allowed Values:TRUE/FALSE Default = TRUE)
    [Parameter(Mandatory = $false)]
    [string]
    $CalculateHash = "TRUE",

    # Hash Algorithm (Optional. Allowed Values:MD5/SHA256/SKEIN Default = SKEIN)
    [Parameter(Mandatory = $false)]
    [string]
    $HashAlgorithm = "SKEIN"
)

#$ErrorActionPreference = 'Stop'

######################################### CoC Constants ###################################################
# Update the following constants with the values related to your environment

$destSubId = '577dd4dc-387b-4e19-885e-f0788b27f2c7'   # The subscription containing the storage account being copied to (ex. 00112233-4455-6677-8899-aabbccddeeff)
$destRGName = 'Coc-SOC'                               # The name of the resource group containing the storage account being copied to 
$destSAblob = 'cocsocstorageacct'                     # The name of the storage account for BLOB
$destSAfile = 'cocsocstorageacct'                     # The name of the storage account for FILE
$destTempShare = 'hash'                               # The temporary file share mounted on the hybrid worker
$destSAContainer = 'immutable'                        # The name of the container within the storage account
$destKV = 'CoC-SOC-keyvault'                          # The name of the keyvault to store a copy of the BEK in the dest subscription
$targetWindowsDir = "Z:"                              # The mapping path to the share that will contain the disk and its hash. By default, the scripts assume you mounted the Azure file share on drive Z.
                                                      # If you need a different mounting point, update Z: in the script or set a variable for that. 
$snapshotPrefix = (Get-Date).ToString('yyyyMMddHHmm') # The prefix of the snapshot to be created

############################################################################################################
Write-Output "SubscriptionId: $SubscriptionId"
Write-Output "ResourceGroupName: $ResourceGroupName"
Write-Output "VirtualMachineName: $VirtualMachineName"


#############################################################################################
# Please verify that your Hybrid Runbook Worker has the following modules installed

    # Uninstall-Module Az.Accounts -Force
    # Uninstall-Module Az.Resources -Force
    # Uninstall-Module Az.Compute -Force
    # Uninstall-Module Az.Storage -Force
    # Uninstall-Module Az.KeyVault -Force    

    # Install-Module Az.Accounts -requiredVersion 2.12.1
    # Install-Module Az.Resources -requiredVersion 6.6.0
    # Install-Module Az.Compute -requiredVersion 5.7.0
    # Install-Module Az.Storage -requiredVersion 5.5.0
    # Install-Module Az.KeyVault -requiredVersion 4.9.2

#############################################################################################

#############################################################################################
# Script Block Section for HASH Algorithm implementation in parallel jobs

$MD5scriptBlock = {
    param($filePath)
    $hash = (Get-FileHash $filePath -Algorithm MD5).Hash
    $result = [PSCustomObject]@{
        Name = $args[0]
        FilePath = $filePath
        Hash = $hash
    }
    return $result
}

$SHA256scriptBlock = {
    param($filePath)
    $hash = (Get-FileHash $filePath -Algorithm SHA256).Hash
    $result = [PSCustomObject]@{
        Name = $args[0]
        FilePath = $filePath
        Hash = $hash
    }
    return $result
}

$SKEINscriptBlock = {
    param($filePath)
    # $KVmodulePath= Split-Path (Get-Module -ListAvailable Az.KeyVault).Path
    # if ($KVmodulePath.count -gt 0) {$KVmodulePath = $KVmodulePath[0]}
    $KVmodulePath = "C:\Program Files\WindowsPowerShell\Modules\Az.KeyVault\4.9.2"
    Add-Type -Path "$KVmodulePath\BouncyCastle.Crypto.dll" # DLL available in the Az.Keyvault PowerShell module folder

    $skein = New-Object Org.BouncyCastle.Crypto.Digests.SkeinDigest(1024, 1024)
    $fileStream = [System.IO.File]::OpenRead($filePath)
    $bufferSize = 1MB
    $buffer = New-Object byte[] $bufferSize
 
    while (($bytesRead = $fileStream.Read($buffer, 0, $bufferSize)) -gt 0) {
        $skein.BlockUpdate($buffer, 0, $bytesRead)
    }
 
    $fileStream.Close()
 
    $hash = New-Object byte[] $skein.GetDigestSize()
    $skein.DoFinal($hash, 0)
 
    $hashString = [System.BitConverter]::ToString($hash).Replace('-', '')
    
    $result = [PSCustomObject]@{
        FilePath = $filePath
        Hash = $hashString
    }
    return $result
}

# End Script Block Section
#############################################################################################

#Adding BouncyCastle.Crypto DLL to implement Skein Hash Algorithm (note: this DLL is part of the AZ.Keyvault powershell module)
# $KVmodulePath= Split-Path (Get-Module -ListAvailable Az.KeyVault).Path
# if ($KVmodulePath.count -gt 0) {$KVmodulePath = $KVmodulePath[0]}
$KVmodulePath = "C:\Program Files\WindowsPowerShell\Modules\Az.KeyVault\4.9.2"
Add-Type -Path "$KVmodulePath\BouncyCastle.Crypto.dll"

####### Functions section ##########
function SkeinDigest ($filePath) {
    $hashString = ""    
    $skein = New-Object Org.BouncyCastle.Crypto.Digests.SkeinDigest(1024, 1024)
    $fileStream = [System.IO.File]::OpenRead($filePath)
    $bufferSize = 1MB
    $buffer = New-Object byte[] $bufferSize
    
    while (($bytesRead = $fileStream.Read($buffer, 0, $bufferSize)) -gt 0) {
        $skein.BlockUpdate($buffer, 0, $bytesRead)
    }
    
    $fileStream.Close()
    
    $hash = New-Object byte[] $skein.GetDigestSize()
    $skein.DoFinal($hash, 0)
    
    $hashString = [System.BitConverter]::ToString($hash).Replace('-', '')
 
    return $hashString
}
####### End Functions section ##########

##############################################
# Main script section

$swGlobal = [Diagnostics.Stopwatch]::StartNew()

################################## Hybrid Worker Check ######################################
$bios= Get-WmiObject -class Win32_BIOS
if ($bios) {   
    Write-Output "Running on Hybrid Worker"

    ################################## Mounting fileshare #######################################
    # The Storage account also hosts an Azure file share to use as a temporary repository for calculating the snapshot's hash value.
    # The following doc shows a possible way to mount the Azure file share on Z:\ :
    # https://docs.microsoft.com/azure/storage/files/storage-how-to-use-files-windows
    #
    # The following is a sample code: please adapt it to your environment and change the password 
    # with the SAS key you used when you created the storage account

    If (!(Test-Path $targetWindowsDir)) {
       $connectTestResult = Test-NetConnection -ComputerName "$destSAfile.file.core.windows.net" -Port 445
       if ($connectTestResult.TcpTestSucceeded) {
           # Save the password so the drive will persist on reboot
           cmd.exe /C "cmdkey /add:`"$destSAfile.file.core.windows.net`" /user:`"localhost\$destSAfile`" /pass:`"h9Powi8m33D5DiGhlddjG267WGOWqZXFKzrqdt6Re24obwIsGnVR+yOnUHlMyhyTD6XBuHT1Xc3n+AStGZONkg==`""
           # Mount the drive
           New-PSDrive -Name Z -PSProvider FileSystem -Root "\\$destSAfile.file.core.windows.net\hash" -Persist
       } else {
           Write-Error -Message "Unable to reach the Azure storage account via port 445. Check to make sure your organization or ISP is not blocking port 445, or use Azure P2S VPN, Azure S2S VPN, or Express Route to tunnel SMB traffic over a different port."
       }
    }
    
   # https://github.com/Azure/azure-powershell/issues/21647#issuecomment-1648566363

    ################################## Login session ############################################
    # Connect to Azure (via Managed Identity)
    # The following roles must be granted to the Azure AD identity of the Azure Automation account:
    #  - "Contributor" on the Resource Group of target Virtual Machine. This provides snapshot rights on Virtual Machine disks
    #  - "Storage Account Contributor" on the immutable SOC Storage Account
    #  - "Key Vault Secrets Officer" on the SOC Key Vault
    #  - "Key Vault Secrets User" on the Key Vault used by target Virtual Machine
    
    Write-Output "Logging in to Azure..."
    Connect-AzAccount -Identity

    ###############################
    # OS DISK SECTION
    ###############################

    ############################# Snapshot the OS disk of target VM ##############################
    Write-Output "#################################"
    Write-Output "Snapshot the OS Disk"
    Write-Output "#################################"

    Set-AzContext -Subscription $SubscriptionId
    $vm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VirtualMachineName

    $disk = Get-AzDisk -ResourceGroupName $ResourceGroupName -DiskName $vm.StorageProfile.OsDisk.Name
    $snapshot = New-AzSnapshotConfig -SourceUri $disk.Id -CreateOption Copy -Location $vm.Location
    $snapshotName = $snapshotPrefix + "-" + $disk.name.Replace("_","-")
    New-AzSnapshot -ResourceGroupName $ResourceGroupName -Snapshot $snapshot -SnapshotName $snapshotname


    ##################### Start the job to copy the OS disk snapshot from source to the storage account ########################
    Write-Output "########################################################################"
    Write-Output "Copy the OS snapshot from source resource Group to the storage account"
    Write-Output "########################################################################"

    $snapSasUrl = Grant-AzSnapshotAccess -ResourceGroupName $ResourceGroupName -SnapshotName $snapshotName -DurationInSecond 72000 -Access Read
    Set-AzContext -Subscription $destSubId
    $targetStorageContextBlob = (Get-AzStorageAccount -ResourceGroupName $destRGName -Name $destSAblob).Context
    $targetStorageContextFile = (Get-AzStorageAccount -ResourceGroupName $destRGName -Name $destSAfile).Context

    Write-Output "############################################"
    Write-Output "Start Copying OS snaphot to Blob container"
    Write-output "Snapshot: $SnapshotName.vhd"
    Write-Output "############################################"
    Start-AzStorageBlobCopy -AbsoluteUri $snapSasUrl.AccessSAS -DestContainer $destSAContainer -DestContext $targetStorageContextBlob -DestBlob "$SnapshotName.vhd" -Force

    ##################### If you need to calculate the hash start the job to copy the OS disk snapshot to the fileshare ########################
    if ($CalculateHash.ToUpper() -eq "TRUE") {
        Write-Output "############################################"
        Write-Output "Start Copying OS snapshot to Fileshare"
        Write-output "Snapshot: $SnapshotName"
        Write-Output "############################################"
        Start-AzStorageFileCopy -AbsoluteUri $snapSasUrl.AccessSAS -DestShareName $destTempShare -DestContext $targetStorageContextFile -DestFilePath $SnapshotName -Force
    }

    #################### Copy the OS disk BEK to the SOC Key Vault  ###################################
    $BEKurl = $disk.EncryptionSettingsCollection.EncryptionSettings.DiskEncryptionKey.SecretUrl
    Write-Output "#################################################################"
    Write-Output "OS Disk Encryption Secret URL: $BEKurl"
    Write-Output "#################################################################"
    if ($BEKurl) {
        Set-AzContext -Subscription $SubscriptionId
        $sourcekv = $BEKurl.Split("/")
        $BEK = Get-AzKeyVaultSecret -VaultName  $sourcekv[2].split(".")[0] -Name $sourcekv[4] -Version $sourcekv[5]
        Write-Output "Key value: $BEK"
        Set-AzContext -Subscription $destSubId
        Set-AzKeyVaultSecret -VaultName $destKV -Name $snapshotName -SecretValue $BEK.SecretValue -ContentType "BEK" -Tag $BEK.Tags
    }

    ###############################
    # DATA DISKS SECTION
    ###############################

    ############################ Snapshot the data disks #####################
    $dsnapshotList = @()

    Set-AzContext -Subscription $SubscriptionId
    foreach ($dataDisk in $vm.StorageProfile.DataDisks) {
        $ddisk = Get-AzDisk -ResourceGroupName $ResourceGroupName -DiskName $dataDisk.Name
        $dsnapshot = New-AzSnapshotConfig -SourceUri $ddisk.Id -CreateOption Copy -Location $vm.Location
        $dsnapshotName = $snapshotPrefix + "-" + $ddisk.name.Replace("_","-")
        $dsnapshotList += $dsnapshotName
        Write-Output "####################################################"
        Write-Output "Snapshot data disk: $dsnapshotName"
        Write-Output "####################################################"
        New-AzSnapshot -ResourceGroupName $ResourceGroupName -Snapshot $dsnapshot -SnapshotName $dsnapshotName
        
        $dsnapSasUrl = Grant-AzSnapshotAccess -ResourceGroupName $ResourceGroupName -SnapshotName $dsnapshotName -DurationInSecond 72000 -Access Read
        Set-AzContext -Subscription $destSubId
        $targetStorageContextBlob = (Get-AzStorageAccount -ResourceGroupName $destRGName -Name $destSABlob).Context
        $targetStorageContextFile = (Get-AzStorageAccount -ResourceGroupName $destRGName -Name $destSAFile).Context

        ##################### Start the job to copy the Data Disk snapshot from source to the storage account ########################
        Write-Output "######################################################"
        Write-Output "Start Copying the Data Disk snapshot to blob container"
        Write-Output "Snapshot: $dsnapshotName.vhd"
        Write-Output "######################################################"
        Start-AzStorageBlobCopy -AbsoluteUri $dsnapSasUrl.AccessSAS -DestContainer $destSAContainer -DestContext $targetStorageContextBlob -DestBlob "$dsnapshotName.vhd" -Force

        ##################### If you need to calculate the hash start the job to copy the OS disk snapshot to the fileshare ########################
        if ($CalculateHash.ToUpper() -eq "TRUE") {
            Write-Output "###########################################################"
            Write-Output "Start Copying the Data Disk snapshot to Fileshare"
            Write-Output "Snapshot: $dsnapshotName"
            Write-Output "###########################################################"
            Start-AzStorageFileCopy -AbsoluteUri $dsnapSasUrl.AccessSAS -DestShareName $destTempShare -DestContext $targetStorageContextFile -DestFilePath $dsnapshotName  -Force
        }

        #################### Copy the Data Disk BEK to the SOC Key Vault  ###################################
        $BEKurl = $ddisk.EncryptionSettingsCollection.EncryptionSettings.DiskEncryptionKey.SecretUrl
        Write-Output "#############################################################"
        Write-Output "Disk Encryption Secret URL: $BEKurl"
        Write-Output "#############################################################"
        if ($BEKurl) {
            Set-AzContext -Subscription $SubscriptionId
            $sourcekv = $BEKurl.Split("/")
            $BEK = Get-AzKeyVaultSecret -VaultName  $sourcekv[2].split(".")[0] -Name $sourcekv[4] -Version $sourcekv[5]
            Write-Output "Key value: $BEK"
            Write-Output "Secret name: $dsnapshotName"
            Set-AzContext -Subscription $destSubId
            Set-AzKeyVaultSecret -VaultName $destKV -Name $dsnapshotName -SecretValue $BEK.SecretValue -ContentType "BEK" -Tag $BEK.Tags
        }
        else {
            Write-Output "Disk not encrypted"
        }

    }

    #############################
    # HASH SECTION
    #############################

    ############################# Calculate the hash of the OS and Data disk snapshots ##############################

    if ($CalculateHash.ToUpper() -eq "TRUE") {
        $completedSnapshots = @()
        #adding OS snapshot to the list of Data Snapshots to parallelize the hash calculation
        $snapshotList = $dsnapshotList + $snapshotName
        Write-Output "################################################################################"
        Write-Output "Waiting for all the copies of the snapshots to the fileshare to be completed"
        Write-Output "################################################################################"
        foreach ( $snapshot in $snapshotList) {           
            $sw = [Diagnostics.Stopwatch]::StartNew()
            Get-AzStorageFileCopyState -Context $targetStorageContextFile -ShareName $destTempShare -FilePath $snapshot -WaitForComplete
            $sw.Stop()
            Write-Output "Elapsed time:  $($sw.Elapsed.TotalMinutes)  minutes"           

            $completedSnapshots += $snapshot
        }
        # Adding parallel jobs for HASH calculation
        Write-Output "################################################################################"
        Write-Output "Starting to calculate the HASH for all the snapshots copied to the fileshare"
        Write-Output "################################################################################"
        $jobs = @()
 
        foreach ($snapshot in $completedSnapshots) {
            $filePath = "$targetWindowsDir\$snapshot"
            switch ($HashAlgorithm.toUpper()) {
                "MD5" {
                    # MD5 hash algorithm selected
                    Write-Output "Starting MD5 hash job for $filePath..."
                    $jobs += Start-Job -ScriptBlock $MD5scriptBlock -ArgumentList $filePath
                }
                "SHA256" {
                    # SHA256 hash algorithm selected
                    Write-Output "Starting SHA256 hash job for $filePath..."
                    $jobs += Start-Job -ScriptBlock $SHA256scriptBlock -ArgumentList $filePath
                }
                "SKEIN" {
                    # Skein hash algorithm selected
                    Write-Output "Starting Skein hash job for $filePath..."
                    $jobs += Start-Job -ScriptBlock $SKEINscriptBlock -ArgumentList $filePath
                }
                default {
                    Write-Host "Invalid algorithm"
                }
            }
        }
    }
    else {
        $dhash = "Not Calculated"
    }

    $sw = [Diagnostics.Stopwatch]::StartNew()
    Write-Output "##############################################################"
    Write-output "Waiting the hash jobs for all the snapshots to be completed"
    Write-Output "##############################################################"
    $results = Receive-Job -Job $jobs -Wait
    Remove-Job -Job $jobs
    
    $i = 0
    foreach ($result in $results) {
        $i++
        # The 'results' array contains data to be ignored at its odd indices.
        if ($i % 2 -eq 0) {
            Write-Output "$($result.FilePath): $($result.Hash)"
            $snapshot = Split-Path $result.filePath -Leaf
            $dhash = $result.Hash.ToString()
            Write-Output "#################################################"
            Write-Output "Data disk - Put hash value in the Key Vault"
            Write-Output "#################################################"
            $Secret = ConvertTo-SecureString -String $dhash -AsPlainText -Force
            Set-AzKeyVaultSecret -VaultName $destKV -Name "$snapshot-hash" -SecretValue $Secret -ContentType "text/plain"
            $targetStorageContextFile = (Get-AzStorageAccount -ResourceGroupName $destRGName -Name $destSAfile).Context
            Remove-AzStorageFile -ShareName $destTempShare -Path $snapshot -Context $targetStorageContextFile
        }
    }
    
    $sw.Stop()
    Write-Output "Elapsed time: $($sw.Elapsed.TotalMinutes)  minutes" 


    #############################
    # FINAL SECTION
    #############################
    Write-Output "##############################################################"
    Write-Output "Waiting for all the copies to blob to be completed"
    Write-Output "##############################################################"
    $sw = [Diagnostics.Stopwatch]::StartNew()
       
    foreach ($snapshot in $snapshotList) {
        Get-AzStorageBlobCopyState -Blob "$snapshot.vhd" -Container $destSAContainer -Context $targetStorageContextBlob -WaitForComplete
    }
    $sw.Stop()
    Write-Output "Elapsed time: $($sw.Elapsed.TotalMinutes)  minutes"
    Set-AzContext -Subscription $SubscriptionId
    

    ################################## Delete all the source snapshots ###############################
    Write-Output "########################################"
    Write-Output "Waiting deletion of all source snapshots"
    Write-Output "########################################"

    $sw = [Diagnostics.Stopwatch]::StartNew()

    foreach ($snapshot in $snapshotList) {
        Revoke-AzSnapshotAccess -ResourceGroupName $ResourceGroupName -SnapshotName $snapshot
        Remove-AzSnapshot -ResourceGroupName $ResourceGroupName -SnapshotName $snapshot -Force
    }
    $sw.Stop()
    
    Write-Output "Elapsed time:  $($sw.Elapsed.TotalMinutes)  minutes"
}
else {
    Write-Information "This runbook must be executed from a Hybrid Worker. Please retry selecting the Hybrid Worker group in the Azure Automation account."
}


$swGlobal.Stop()

Write-Output "#####################################################"
Write-Output "Operation completed."
Write-Output "Elapsed time:  $($swGlobal.Elapsed.TotalMinutes)  minutes"
Write-Output "#####################################################"
