# CoC LAB Deployment
Deploy the LAB environment for [Computer Forensics Chain of Custody in Azure](https://learn.microsoft.com/en-us/azure/architecture/example-scenario/forensics/)

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Ffamascicoc.blob.core.windows.net%2Farmtemplate%2Fcoc-main.json)

To deploy the LAB environment click on the **Deploy to Azure** button above. The deployment will start in the Azure Portal. You will be asked to provide the following parameters:

> NOTE: For resources like storage account, key vault, etc. that require a globally unique name, please replace the \<UNIQUESTRING> placeholder with a unique string of your choice respecting the constraints of the resource (max number of char, only lowercase, etc.). 

| Parameter | Description | Default value |
|-----------|-------------|---------------|
|Subscription|The subscription where the resource groups will be deployed|Current subscription|
|Region|The region where the deployment start. NOTE: All the resources will be deployed in the region defined in the *Coc-Location* paramter below||
|Coc-Location|The region where the resources will be deployed.|westeurope|
|Coc-prod-rg_name |The name of the resource group for the Production environment|CoC-Production|
|Coc-prod-vnet_name |The name of the virtual network for the Production environment|CoC-Production-vnet|
|Coc-prod-nsg_name |The name of the network security group for the Production environment|CoC-Production-vnet-server-nsg|
|Coc-prod-keyvault_name |The name of the key vault for the Production environment|CoC-Production-keyvault-\<UNIQUESTRING>|
|Coc-prod-VM01_name |The name of the VM for the Production environment|CoC-Prod-VM01|
|Coc-prod-VM01_adminUsername |The name of the admin user for the VM for the Production environment|cocprodadmin|
|Coc-prod-VM01_adminPassword|The password of the admin user for the VM for the Production environment||
||||
|Coc-soc-rg_name |The name of the resource group for the SOC environment|CoC-SOC|
|Coc-soc-vnet_name |The name of the virtual network for the SOC environment|CoC-SOC-vnet|
|Coc-soc-nsg_name |The name of the network security group for the SOC environment|CoC-SOC-vnet-soc-subnet01-nsg|
|Coc-soc-keyvault_name |The name of the key vault for the SOC environment|CoC-SOC-keyvault-\<UNIQUESTRING>|
|Coc-soc-storageAccount_name |The name of the storage account for the SOC environment|cocsocstorage-\<UNIQUESTRING>|
|Coc-soc-LogAnWks_name |The name of the Log Analytics Workspace for the SOC environment|CoC-SOC-LogAnWks-\<UNIQUESTRING>|
|Coc-soc-automatioAccount_name |The name of the automation account for the SOC environment|CoC-SOC-AutomationAcct|
|CoC-SOC-workerGroup_name|The name of the Hybrid Worker Group for the SOC environment|CoC-HRW-Windows|
|Coc-soc-HRW_VM_name |The name of the Hybrid RunBook Worker VM for the SOC environment|CoC-SOC-HRW|
|Coc-soc-HRW_adminUsername |The name of the admin user for the Hybrid RunBook Worker VM for the SOC environment|cocsocadmin|
|Coc-soc-HRW_adminPassword |The password of the admin user for the Hybrid RunBook Worker VM for the SOC environment||


>Note: The deployment will take about 5 minutes to complete.

![Screenshot of a succeeded deployment](./.diagrams/SucceededDeployment.jpg)

## Description of the LAB environment
The LAB environment is a simplified realization of the architecture described in the [article](https://learn.microsoft.com/en-us/azure/architecture/example-scenario/forensics/) because it deploys two resource groups in the same subscription. The fist resource group simulates the **Production Environment** containing the Digital Evidence, while the second resource group contains the **SOC Environment**.

![LAB CoC Architecture](./.diagrams/LAB_CoC_Architecture.png)

The Production resource group contains:
1. A **virtual network** with a subnet and and network security group prtotecting the subnet
1. A **Windows Server 2022 VM** with a public IP address an OS disk and two data disks configured with Azure Disk Encryption (ADE)
1. A **key vault** for storing the BEK keys of the encrypted disks.

The SOC resource group contains:
1. A **virtual network** with a subnet and and network security group prtotecting the subnet
1. A **Windows Server 2022 VM** that will be used as a Hybrid RunBook Worker (HRW). The HRW is automatically configured with all the powershell modules required to execute the Chain of Custody process.
1. A **storage account** for storing the digital evidence with:
    1. a blob container named *immutable* automatically configured with the [Legal Hold](https://docs.microsoft.com/en-us/azure/storage/blobs/storage-blob-immutability-policies-overview) feature
    1. a file share named *hash* used to calculate the hash of the digital evidence.
1. A **key vault** for storing in the SOC environment a copy of the BEK keys and the hash of the digital evidence processed.
1. An **automation account** configured with:
    1. A RunBook that implements the Chain of Custody process as described in the article
    1. Variables for the RunBook automatically populated with the values of the SOC environment
    1. A System Managed Identity with the required permissions on Production resource Group and SOC resource group
    1. An Hybrid Worker Group containing the Hybrid RunBook Worker (HRW) VM

## Execute the Chain of Custody process in the LAB environment
Open the automation account in the SOC resource group and click on the **RunBooks** blade. Select the **Copy-VmDigitalEvidenceWin** RunBook and click on the **Start** button. In the **Start RunBook** blade specify the following parameters:

|Parameter|Description|Sample value|
|--------|-----------|------------|
|SUBSCRIPTION ID|The subscription ID where the Production resource group is deployed|xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx|
|RESOURCEGROUPNAME|The name of the Production resource group|CoC-Production|
|VIRTUALMACHINENAME|The name of the VM in the Production resource group|CoC-Prod-VM01|
|CALCULATEHASH|If true the RunBook will calculate the hash of the digital evidence. Supported values are TRUE or FALSE| TRUE|
|HASHALGORITHM|The algorithm used to calculate the hash of the digital evidence. Supported Values are MD5, SHA256, SKEIN, KECCAK (or SHA3)|SHA256|

>NOTE: The RunBook, applied to the VM deployed in this LAB, will take about 45 minutes to complete (15 minutes if you skip the hash calculation). The time required to complete the RunBook depends on the size of the disks attached to the VM. The hash calculation is the most time consuming operation and is done in parallel jobs to speed the process over all the disks.