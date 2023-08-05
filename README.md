# CoC LAB Deployment
Deploy the LAB environment for [Computer Forensics Chain of Custody in Azure](https://learn.microsoft.com/en-us/azure/architecture/example-scenario/forensics/)

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Ffamascicoc.blob.core.windows.net%2Farmtemplate%2Fcoc-main.json)

To deploy the LAB environment click on the **Deploy to Azure** button above. The deployment will start in the Azure Portal. You will be asked to provide the following parameters:

> NOTE: For resources like storage account, key vault, etc. that require a globally unique name, please replace the \<UNIQUESTRING> placeholder with a unique string of your choice. 

| Parameter | Description | Default value |
|Subscription|The subscription where the resource groups will be deployed|Current subscription|
|Region|The region where the deployment start. NOTE: All the resources will be deployed in the region defined in the Coc-Location paramtere below||
|Coc-Location|The region where the resources will be deployed.|westeurope|
|Coc-prod-rg_name
CoC-Production
Coc-prod-vnet_name
CoC-Production-vnet
Coc-prod-nsg_name
CoC-Production-vnet-server-nsg
Coc-prod-keyvault_name
CoC-Prod-keyvault-<UNIQUESTRING>
Coc-prod-VM01_name
CoC-Prod-VM01
Coc-prod-VM01_admin Username
cocprodadmin
Coc-prod-VM01_admin Password
Coc-soc-rg_name
CoC-SOC
Coc-soc-vnet_name
CoC-SOC-vnet
Coc-soc-nsg_name
CoC-SOC-vnet-soc-subnet01-nsg
Coc-soc-keyvault_name
CoC-SOC-keyvault-<UNIQUESTRING>
Coc-soc-storage Account_name
cocsocstorage<UNIQUESTRING>
Coc-soc-Log An Wks_name
CoC-SOC-LogAnWks-<UNIQUESTRING>
Coc-soc-automation Account_name
CoC-SOC-AutomationAcct
Coc-soc-worker Group Name
CoC-HRW-Windows
Coc-soc-HRW_VM_name
CoC-SOC-HRW
Coc-soc-HRW_admin Username
cocsocadmin
Coc-soc-HRW_admin Password




## Description of the LAB environment
The LAB environment is a simplified realization of the architecture described in the article because it deploys two resource groups in the same subscription. The fist resource group simulates the **Production Environment** containing the Digital Evidence, while the second resource group contains the **SOC Environment**.

The Production resource group contains:
1. A virtual network with a subnet and and network security group prtotecting the subnet
1. A Windows Server 2022 VM with a public IP address an OS disk and two data disks configured with Azure Disk Encryption (ADE)
1. A key vault for storing the BEK keys of the encrypted disks.

The SOC resource group contains:
1. A **virtual network** with a subnet and and network security group prtotecting the subnet
1. A **Windows Server 2022 VM** that will be used as a Hybrid Runbook Worker (HRW). 
1. A **storage account** for storing the digital evidence with 
    1. a blob container named *immutable* configured with the [Legal Hold](https://docs.microsoft.com/en-us/azure/storage/blobs/storage-blob-immutability-policies-overview) feature
    1. a file share named *hash* used to calculate the hash of the digital evidence.
1. A **key vault** for storing in the SOC environment a copy of the BEK keys and the hash of the digital evidence processed.
1. An **automation account** configured with:
    1. A runbook that implements the Chain of Custody process as described in the article
    1. Variables for the runbook automatically populated with the values of the SOC environment
    1. A System Managed Identity with the required permissions on Production resource Group and SOC resource group
    1. An Hybrid Worker Group containing the Hybrid Runbook Worker (HRW) VM

 
## Execute the Chain of Custody process in the LAB environment