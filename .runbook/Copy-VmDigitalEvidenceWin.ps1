<#
.SYNOPSIS
    Performs a digitial evidence capture operation on a target VM 

.DESCRIPTION
    This is sample code, please be sure to read
    https://docs.microsoft.com/azure/architecture/example-scenario/forensics/ to get
    all the requirements in place and adapt the code to your environment by replacing
    the placeholders and adding the required code blocks before using it. Key outputs
    are in the script for debug reasons, remove the output after the initial tests to
    improve the security of your script.
    
    This is designed to be run from a Windows Hybrid Runbook Worker in response to a
    digitial evidence capture request for a target VM.  It will create disk snapshots
    for all disks, copying them to immutable SOC storage, and take a SHA-256 hash and
    storing the results in your SOC Key Vault.

    This script depends on Az.Accounts, Az.Compute, Az.Storage, and Az.KeyVault being 
    imported in your Azure Automation account.
    See: https://docs.microsoft.com/en-us/azure/automation/az-modules

.EXAMPLE
    Copy-VmDigitialEvidence -SubscriptionId ffeeddcc-bbaa-9988-7766-554433221100 -ResourceGroupName rg-finance-vms -VirtualMachineName vm-workstation-001

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

    # Hash Calculation (Optional. Allowed Values:true/false Default = true)
    [Parameter(Mandatory = $false)]
    [boolean]
    $CalulateHash = $true,

    # Hash Algorithm (Optional. Allowed Values:MD5/SHA256/Skein Default = Skein)
    [Parameter(Mandatory = $false)]
    [string]
    $HashAlgorithm = "SKEIN"
)

#$ErrorActionPreference = 'Stop'

######################################### SOC Constants #####################################
# Update the following constants with the values related to your environment
# SOC Team Evidence Resources
$destSubId = '577dd4dc-387b-4e19-885e-f0788b27f2c7' # The subscription containing the storage account being copied to (ex. 00112233-4455-6677-8899-aabbccddeeff)
$destRGName = 'Coc-SOC'                             # The name of the resource group containing the storage account being copied to 
$destSAblob = 'cocsocstorageacct'                   # The name of the storage account for BLOB
$destSAfile = 'cocsocstorageacct'                   # The name of the storage account for FILE
$destTempShare = 'hash'                             # The temporary file share mounted on the hybrid worker
$destSAContainer = 'immutable'                      # The name of the container within the storage account
$destKV = 'CoC-SOC-keyvault'                        # The name of the keyvault to store a copy of the BEK in the dest subscription
$targetWindowsDir = "Z:"                            # The mapping path to the share that will contain the disk and its hash. By default the scripts assume you mounted the Azure file share on drive Z.
                                                      # If you need a different mounting point, update Z: in the script or set a variable for that. 
$snapshotPrefix = (Get-Date).toString('yyyyMMddHHmm') # The prefix of the snapshot to be created

Write-Output "SubscriptionId: $SubscriptionId"
Write-Output "ResourceGroupName: $ResourceGroupName"
Write-Output "VirtualMachineName: $VirtualMachineName"


#############################################################################################
#Adding BouncyCastle.Crypto DLL to implement Skein Hash Algorithm (note: this DLL is part of the AZ.Keyvault powershell module)
$KVmodulePath= Split-Path (Get-Module -ListAvailable Az.KeyVault).Path
Add-Type -Path "$KVmodulePath\BouncyCastle.Crypto.dll"

#Functions section
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


##############################################

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
    If (!(Test-Path $targetWindowsDir)) {
       $connectTestResult = Test-NetConnection -ComputerName cocsocstorageacct.file.core.windows.net -Port 445
       if ($connectTestResult.TcpTestSucceeded) {
           # Save the password so the drive will persist on reboot
           cmd.exe /C "cmdkey /add:`"cocsocstorageacct.file.core.windows.net`" /user:`"localhost\cocsocstorageacct`" /pass:`"h9Powi8m33D5DiGhlddjG267WGOWqZXFKzrqdt6Re24obwIsGnVR+yOnUHlMyhyTD6XBuHT1Xc3n+AStGZONkg==`""
           # Mount the drive
           New-PSDrive -Name Z -PSProvider FileSystem -Root "\\cocsocstorageacct.file.core.windows.net\hash" -Persist
       } else {
           Write-Error -Message "Unable to reach the Azure storage account via port 445. Check to make sure your organization or ISP is not blocking port 445, or use Azure P2S VPN, Azure S2S VPN, or Express Route to tunnel SMB traffic over a different port."
       }
    }
    

    # Azure Automation's RunAs Account VERRA RITIRATO
    # I PERMESSI VANNO DATI SULL'IDENTITY DELLA VIRTUAL MACHINE 
    # QUELLI DEL KEYVAULT SONO STATI ASSEGNATI ALL'IDENTITY DEL AUTOMATION ACCOUNT
    # ABBIAMO DATO DIRITTI RBAC SUI KEY VAULT
    # IN CASO DI PROBLEMI CON POWERSHELL 5.1 CONTROLLARE ALL LOGS

    # Get-InstalledModule Az.Accounts -AllVersion
    # Get-InstalledModule Az.Resources -AllVersion
    # Install-Module Az.Accounts -requiredVersion 2.12.1
    # Install-Module Az.Resources -requiredVersion 6.6.0
    # Install-Module Az.Compute -requiredVersion 5.7.0
    # Install-Module Az.Storage -requiredVersion 5.5.0
    # Install-Module Az.KeyVault -requiredVersion 4.9.2
    # Uninstall-Module Az.Accounts -RequiredVersion 2.12.4 -Force
    # Uninstall-Module Az.Resources -RequiredVersion 6.8.0 -Force
    # Uninstall-Module Az.Compute -RequiredVersion 6.1.0 -Force
    # Uninstall-Module Az.Storage -RequiredVersion 5.8.0 -Force
    # Uninstall-Module Az.KeyVault -RequiredVersion 4.10.0 -Force
    # https://github.com/Azure/azure-powershell/issues/21647#issuecomment-1648566363


    ################################## Login session ############################################
    # Connect to Azure (via Managed Identity or Azure Automation's RunAs Account)
    #
    # Feel free to adjust the following lines to invoke Connect-AzAccount via
    # whatever mechanism your Hybrid Runbook Workers are configured to use.
    #
    # Whatever service principal is used, it must have the following permissions
    #  - "Contributor" on the Resource Group of target Virtual Machine. This provide snapshot rights on Virtual Machine disks
    #  - "Storage Account Contributor" on the immutable SOC Storage Account
    #  - Access policy to Get Secret (for BEK key) and Get Key (for KEK key, if present) on the Key Vault used by target Virtual Machine
    #  - Access policy to Set Secret (for BEK key) and Create Key (for KEK key, if present) on the SOC Key Vault

    Write-Output "Logging in to Azure..."
    Connect-AzAccount -Identity


    ############################# Snapshot the OS disk of target VM ##############################
    Write-Output "#################################"
    Write-Output "Snapshot the OS Disk of target VM"
    Write-Output "#################################"

    Set-AzContext -Subscription $SubscriptionId
    $vm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VirtualMachineName

    $disk = Get-AzDisk -ResourceGroupName $ResourceGroupName -DiskName $vm.StorageProfile.OsDisk.Name
    $snapshot = New-AzSnapshotConfig -SourceUri $disk.Id -CreateOption Copy -Location $vm.Location
    $snapshotName = $snapshotPrefix + "-" + $disk.name.Replace("_","-")
    New-AzSnapshot -ResourceGroupName $ResourceGroupName -Snapshot $snapshot -SnapshotName $snapshotname


    ##################### Copy the OS snapshot from source to file share and blob container ########################
    Write-Output "#################################"
    Write-Output "Copy the OS snapshot from source to file share and blob container"
    Write-Output "#################################"

    $snapSasUrl = Grant-AzSnapshotAccess -ResourceGroupName $ResourceGroupName -SnapshotName $snapshotName -DurationInSecond 72000 -Access Read
    Set-AzContext -Subscription $destSubId
    $targetStorageContextBlob = (Get-AzStorageAccount -ResourceGroupName $destRGName -Name $destSAblob).Context
    $targetStorageContextFile = (Get-AzStorageAccount -ResourceGroupName $destRGName -Name $destSAfile).Context

    Write-Output "Start Copying Blob $SnapshotName"
    Start-AzStorageBlobCopy -AbsoluteUri $snapSasUrl.AccessSAS -DestContainer $destSAContainer -DestContext $targetStorageContextBlob -DestBlob "$SnapshotName.vhd" -Force

    if ($CalulateHash) {
        Write-Output "Start Copying Fileshare"
        Start-AzStorageFileCopy -AbsoluteUri $snapSasUrl.AccessSAS -DestShareName $destTempShare -DestContext $targetStorageContextFile -DestFilePath $SnapshotName -Force

        Write-Output "Waiting for the fileshare copy to finish"
        $sw = [Diagnostics.Stopwatch]::StartNew()
        Get-AzStorageFileCopyState -Context $targetStorageContextFile -ShareName $destTempShare -FilePath $SnapshotName -WaitForComplete
        $sw.Stop()
        Write-Output "Elapsed time:  $($sw.Elapsed.TotalMinutes)  minutes"    

        #Windows hash version if you use a Windows Hybrid Runbook Worker
        $diskpath = "$targetWindowsDir\$snapshotName"  
        Write-Output "Start Calculating HASH for $diskpath"
        Get-ChildItem "$diskpath" | Select-Object -Expand FullName | ForEach-Object{Write-Output $_}
        $sw = [Diagnostics.Stopwatch]::StartNew()
        switch ($HashAlgorithm.toUpper() ) {
            "MD5" {
                # Calculate MD5 hash
                Write-Output "Calculating MD5 hash..."
                $hash = (Get-FileHash $diskpath -Algorithm MD5).Hash
            }
            "SHA256" {
                # Calculate SHA256 hash
                Write-Output "Calculating SHA256 hash..."
                $hash = (Get-FileHash $diskpath -Algorithm SHA256).Hash
            }
            "SKEIN" {
                # Calculate Skein hash
                Write-Output "Calculating Skein hash..."
                $hash = SkeinDigest $diskpath
            }
            default {
                Write-Host "Invalid algorithm"
            }
        }

        $sw.Stop()
        Write-Output "Elapsed time:  $($sw.Elapsed.TotalMinutes)  minutes"   
        Write-Output "Computed hash: $hash"
    }
    else {
        $hash = "Not Calculated"
    }
    #################### Copy the OS BEK to the SOC Key Vault  ###################################
    $BEKurl = $disk.EncryptionSettingsCollection.EncryptionSettings.DiskEncryptionKey.SecretUrl
    Write-Output "#################################"
    Write-Output "OS Disk Encryption Secret URL: $BEKurl"
    Write-Output "#################################"
    if ($BEKurl) {
        Set-AzContext -Subscription $SubscriptionId
        $sourcekv = $BEKurl.Split("/")
        $BEK = Get-AzKeyVaultSecret -VaultName  $sourcekv[2].split(".")[0] -Name $sourcekv[4] -Version $sourcekv[5]
        Write-Output "Key value: $BEK"
        Set-AzContext -Subscription $destSubId
        Set-AzKeyVaultSecret -VaultName $destKV -Name $snapshotName -SecretValue $BEK.SecretValue -ContentType "BEK" -Tag $BEK.Tags
    }

    ######## Copy the OS disk hash value in key vault and delete disk in file share ##################
    Write-Output "#################################"
    Write-Output "OS disk - Put hash value in Key Vault"
    Write-Output "#################################"
    $secret = ConvertTo-SecureString -String $hash.ToString() -AsPlainText -Force
    Set-AzKeyVaultSecret -VaultName $destKV -Name "$SnapshotName-hash" -SecretValue $secret -ContentType "text/plain"
    $targetStorageContextFile = (Get-AzStorageAccount -ResourceGroupName $destRGName -Name $destSAfile).Context
    if ($CalulateHash) {
        Remove-AzStorageFile -ShareName $destTempShare -Path $SnapshotName -Context $targetStorageContextFile
    }

    ############################ Snapshot the data disks, store hash and BEK #####################
    $dsnapshotList = @()

    Set-AzContext -Subscription $SubscriptionId
    foreach ($dataDisk in $vm.StorageProfile.DataDisks) {
        $ddisk = Get-AzDisk -ResourceGroupName $ResourceGroupName -DiskName $dataDisk.Name
        $dsnapshot = New-AzSnapshotConfig -SourceUri $ddisk.Id -CreateOption Copy -Location $vm.Location
        $dsnapshotName = $snapshotPrefix + "-" + $ddisk.name.Replace("_","-")
        $dsnapshotList += $dsnapshotName
        Write-Output "Snapshot data disk name: $dsnapshotName"
        New-AzSnapshot -ResourceGroupName $ResourceGroupName -Snapshot $dsnapshot -SnapshotName $dsnapshotName
        
        Write-Output "#################################"
        Write-Output "Copy the Data Disk $dsnapshotName snapshot from source to blob container"
        Write-Output "#################################"

        $dsnapSasUrl = Grant-AzSnapshotAccess -ResourceGroupName $ResourceGroupName -SnapshotName $dsnapshotName -DurationInSecond 72000 -Access Read
        Set-AzContext -Subscription $destSubId
        $targetStorageContextBlob = (Get-AzStorageAccount -ResourceGroupName $destRGName -Name $destSABlob).Context
        $targetStorageContextFile = (Get-AzStorageAccount -ResourceGroupName $destRGName -Name $destSAFile).Context

        Write-Output "Start Copying Blob $dsnapshotName"
        Start-AzStorageBlobCopy -AbsoluteUri $dsnapSasUrl.AccessSAS -DestContainer $destSAContainer -DestContext $targetStorageContextBlob -DestBlob "$dsnapshotName.vhd" -Force

        if ($CalulateHash) {
            Write-Output "Start Copying Fileshare"
            Start-AzStorageFileCopy -AbsoluteUri $dsnapSasUrl.AccessSAS -DestShareName $destTempShare -DestContext $targetStorageContextFile -DestFilePath $dsnapshotName  -Force
            
            Write-Output "Waiting Fileshare Copy End"
            $sw = [Diagnostics.Stopwatch]::StartNew()
            Get-AzStorageFileCopyState -Context $targetStorageContextFile -ShareName $destTempShare -FilePath $dsnapshotName -WaitForComplete
            $sw.Stop()
            Write-Output "Elapsed time:  $($sw.Elapsed.TotalMinutes)  minutes"           

            $ddiskpath = "$targetWindowsDir\$dsnapshotName"

            Write-Output "Start Calculating HASH for $ddiskpath"
            Get-ChildItem "$ddiskpath" | Select-Object -Expand FullName | ForEach-Object{Write-Output $_}
            $sw = [Diagnostics.Stopwatch]::StartNew()

            switch ($HashAlgorithm.toUpper() ) {
                "MD5" {
                    # Calculate MD5 hash
                    Write-Output "Calculating MD5 hash..."
                    $dhash = (Get-FileHash $ddiskpath -Algorithm MD5).Hash
                }
                "SHA256" {
                    # Calculate SHA256 hash
                    Write-Output "Calculating SHA256 hash..."
                    $dhash = (Get-FileHash $ddiskpath -Algorithm SHA256).Hash
                }
                "SKEIN" {
                    # Calculate Skein hash
                    Write-Output "Calculating Skein hash..."
                    $dhash = SkeinDigest $ddiskpath
                }
                default {
                    Write-Host "Invalid algorithm"
                }
            }


            $sw.Stop()
            Write-Output "Elapsed time:  $($sw.Elapsed.TotalMinutes)  minutes" 
            Write-Output "Computed hash: $dhash"
        }
        else {
            $dhash = "Not Calculated"
        }

        $BEKurl = $ddisk.EncryptionSettingsCollection.EncryptionSettings.DiskEncryptionKey.SecretUrl
        Write-Output "#################################"
        Write-Output "Disk Encryption Secret URL: $BEKurl"
        Write-Output "#################################"
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

        Write-Output "#################################"
        Write-Output "Data disk - Put hash value in Key Vault"
        Write-Output "#################################"
        $Secret = ConvertTo-SecureString -String $dhash.ToString() -AsPlainText -Force
        Set-AzKeyVaultSecret -VaultName $destKV -Name "$dsnapshotName-hash" -SecretValue $Secret -ContentType "text/plain"
        $targetStorageContextFile = (Get-AzStorageAccount -ResourceGroupName $destRGName -Name $destSAfile).Context
        if ($CalulateHash) {
            Remove-AzStorageFile -ShareName $destTempShare -Path $dsnapshotName -Context $targetStorageContextFile
        }
    }

    Write-Output "Waiting for all copies to blob to complete"
    $sw = [Diagnostics.Stopwatch]::StartNew()
       
    Get-AzStorageBlobCopyState -Blob "$snapshotName.vhd" -Container $destSAContainer -Context $targetStorageContextBlob -WaitForComplete
    foreach ($dsnapshotName in $dsnapshotList) {
        Get-AzStorageBlobCopyState -Blob "$dsnapshotName.vhd" -Container $destSAContainer -Context $targetStorageContextBlob -WaitForComplete
    }
    $sw.Stop()
    Write-Output "Elapsed time:  $($sw.Elapsed.TotalMinutes)  minutes"
    Set-AzContext -Subscription $SubscriptionId
    

    ################################## Delete all source snapshots ###############################
    Write-Output "Waiting deletion of all source snapshots"
    $sw = [Diagnostics.Stopwatch]::StartNew()

    Revoke-AzSnapshotAccess -ResourceGroupName $ResourceGroupName -SnapshotName $snapshotName
    Remove-AzSnapshot -ResourceGroupName $ResourceGroupName -SnapshotName $snapshotname -Force
    foreach ($dsnapshotName in $dsnapshotList) {
        Revoke-AzSnapshotAccess -ResourceGroupName $ResourceGroupName -SnapshotName $dsnapshotName
        Remove-AzSnapshot -ResourceGroupName $ResourceGroupName -SnapshotName $dsnapshotname -Force
    }
    $sw.Stop()
    Write-Output "Elapsed time:  $($sw.Elapsed.TotalMinutes)  minutes"
}
else {
    Write-Information "This runbook must be executed from a Hybrid Worker. Please retry selecting the HybridWorker"
}

$swGlobal.Stop()

Write-Output "#####################################################"
Write-Output "Operation completed."
Write-Output "Elapsed time:  $($swGlobal.Elapsed.TotalMinutes)  minutes"
Write-Output "#####################################################"