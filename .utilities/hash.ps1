
param(
    [Parameter(Mandatory = $true)]
    [string[]] 
    $fileList,

    [Parameter(Mandatory = $true)]
    [string]
    $HashAlgorithm = "MD5"  #supported algorithms: MD5, SHA256, SKEIN, KECCAK (or SHA3)
    )

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
    $hashString = "ERROR"
    Add-Type -Path ".\BouncyCastle.Crypto.dll" 

    #https://javadoc.io/static/org.bouncycastle/bcprov-jdk14/1.57/org/bouncycastle/crypto/digests/SkeinDigest.html
    $skein = New-Object Org.BouncyCastle.Crypto.Digests.SkeinDigest(512, 512)
    $fileStream = [System.IO.File]::OpenRead($filePath)
    $bufferSize = 512KB
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

$KECCAKscriptBlock = {
    param($filePath)
    Add-Type -Path ".\BouncyCastle.Crypto.dll" 

    # https://javadoc.io/static/org.bouncycastle/bcprov-jdk14/1.57/org/bouncycastle/crypto/digests/SHA3Digest.html
    $keccak = New-Object Org.BouncyCastle.Crypto.Digests.KeccakDigest(512)
    $fileStream = [System.IO.File]::OpenRead($filePath)
    $bufferSize = 1MB
    $buffer = New-Object byte[] $bufferSize
 
    while (($bytesRead = $fileStream.Read($buffer, 0, $bufferSize)) -gt 0) {
        $keccak.BlockUpdate($buffer, 0, $bytesRead)
    }
 
    $fileStream.Close()
 
    $hash = New-Object byte[] $keccak.GetDigestSize()
    $keccak.DoFinal($hash, 0)
 
    $hashString = [System.BitConverter]::ToString($hash).Replace('-', '')
    
    $result = [PSCustomObject]@{
        FilePath = $filePath
        Hash = $hashString
    }
    return $result
}

# End Script Block Section
#############################################################################################


############################# MAIN  ##############################

# Adding parallel jobs for HASH calculation
$results = $null
$jobs = @()

foreach ($filePath in $FileList) {
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
        {"KECCAK","SHA3" -contains $_} {
            # KECCAK hash algorithm selected
            Write-Output "Starting Keccak hash job for $filePath..."
            $jobs += Start-Job -ScriptBlock $KECCAKscriptBlock -ArgumentList $filePath
        }
        default {
            Write-Host "Invalid algorithm"
        }
    }
}

Write-Output "##############################################################"
Write-output "Waiting the hash jobs for all the files to be completed"
Write-Output "##############################################################"

$results = Receive-Job -Job $jobs -Wait
Remove-Job -Job $jobs



$evenIndicesArray = @()
if ($HashAlgorithm.ToUpper() -ne "MD5" -and  $HashAlgorithm.ToUpper() -ne "SHA256")  {
    for ($i = 1; $i -lt $results.Length; $i += 2) {
        $evenIndicesArray += $results[$i]
    }
    $results = $evenIndicesArray
}
foreach ($result in $results) {
    Write-Host "$($result.FilePath): $($result.Hash)"
}

$sw.Stop()
Write-Output "Elapsed time: $($sw.Elapsed.TotalMinutes)  minutes" 

