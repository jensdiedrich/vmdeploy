#Requires -Version 5.1
#Requires -Modules @{ ModuleName="ACME-PS"; ModuleVersion="1.5.2" }

<#
.SYNOPSIS
    Generates a SSL certificate from Let's Encrypt and saves it into a key vault.
.DESCRIPTION
    Generates a SSL certificate from Let's Encrypt and saves it into a key vault.
    The script assumes a DNZ Zone resource exists for the Dns you are trying to generate a certificate for.
    It also assumes you already have a storage account and a blob container created.
.PARAMETER DefaultSubscriptionId
    Specifies the subscription id context where the powershell cmdlets are ran against by default.
.PARAMETER DnsZoneResourceId
    Specifies the resource id of the DNS zone where the TXT record will be created (if different from default Subcription Id and/or Resource Group).
    The script will use this to create a TXT record for the challenge.
.PARAMETER StorageAccountResourceId
    Specifies the resource id of the storage account to store the account data (if different from default Subcription Id and/or Resource Group).
.PARAMETER DefaultResourceGroupName
    Specifies the default resource group name where the storage account, key vault and dns reside (if not in different subscriptins or resource groups).
.PARAMETER DefaultStorageAccountName
    Specifies the default storage account name to use to store the state of the letsencrypt account(s), if not in different subscriptins or resource groups.
.PARAMETER ContactEmails
    Specifies the contact emails to use when creating a new lets encrypt account is created.
.PARAMETER DnsName
    Specifies the dns that a certificate needs to be created for.
    For wildcards, use *.hostname.tld
.PARAMETER KeyVaultName
    Specifies the name of the keyvault where the certificate will be stored.
.PARAMETER StorageContainerName
    Specifies the name of the container in the blob storage where the state data is stored. Defaults to letsencrypt.
.PARAMETER KeyVaultCertificateSecretName
    Specifies the key vault secret name of the certificate password that will be used to export the certificate once it has been issued by Let's Encrypt
.PARAMETER Staging
    Specifies whether to use lets encrypt staging/test facily or production facility.
.PARAMETER VerboseOutput
    Specifies whether to set the VerbosePreference to continue
#>

[CmdletBinding()]
Param (
    [Parameter()]
    [string] $DefaultSubscriptionId,
    [Parameter()]
    [string] $DnsZoneResourceId,
    [Parameter()]
    [string] $StorageAccountResourceId,
    [Parameter()]
    [string] $DefaultResourceGroupName,
    [Parameter()]
    [string] $DefaultStorageAccountName,
    [Parameter()]
    [string] $ContactEmails,
    [Parameter()]
    [string] $DnsName,
    [Parameter()]
    [string] $KeyVaultName,
    [Parameter()]
    [string] $StorageContainerName,
    [Parameter()]
    [string] $KeyVaultCertificateSecretName,
    [Parameter()]
    [bool] $Staging = $true,
    [Parameter()]
    [bool] $VerboseOutput = $true
)

$ErrorActionPreference = 'stop'
if ($VerboseOutput) {
    $VerbosePreference = 'continue'
}

Import-Module 'ACME-PS'




function Add-DirectoryToAzureStorage {
    Param (
        [Parameter(Mandatory=$true)]
        [string] $Path,
        [Parameter(Mandatory=$true)]
        [string] $StorageAccountName,
        [Parameter(Mandatory=$true)]
        [string] $StorageAccountKey,
        [Parameter(Mandatory=$true)]
        [string] $ContainerName
    )

    if ([string]::IsNullOrWhiteSpace($StorageAccountKey)) {
        $context = New-AzStorageContext -StorageAccountName $StorageAccountName -UseConnectedAccount
    }
    else {
        $context = New-AzStorageContext -StorageAccountName $StorageAccountName -StorageAccountKey $StorageAccountKey
    }

    $items = Get-ChildItem -Path $Path -File -Recurse
    $startIndex = $Path.Length + 1
    foreach ($item in $items) {
        $targetPath = ($item.FullName.Substring($startIndex)).Replace("\", "/")
        Set-AzStorageBlobContent -File $item.FullName -Container $ContainerName -Context $context -Blob $targetPath -Force | Out-Null
    }
}

function Get-DirectoryFromAzureStorage {
    Param (
        [Parameter(Mandatory=$true)]
        [string] $DestinationPath,
        [Parameter(Mandatory=$true)]
        [string] $StorageAccountSubscriptionId,
        [Parameter(Mandatory=$true)]
        [string] $StorageAccountResourceGroupName,
        [Parameter(Mandatory=$true)]
        [string] $StorageAccountName,
        [Parameter(Mandatory=$true)]
        [string] $StorageAccountKey,
        [Parameter(Mandatory=$true)]
        [string] $ContainerName,
        [Parameter()]
        [string] $BlobName
    )

    if ([string]::IsNullOrWhiteSpace($StorageAccountKey)) {
        $context = New-AzStorageContext -StorageAccountName $StorageAccountName
    }
    else {
        $context = New-AzStorageContext -StorageAccountName $StorageAccountName -StorageAccountKey $StorageAccountKey
    }
    if ([string]::IsNullOrWhiteSpace($BlobName)) {
        $items = Get-AzStorageBlob -Container $ContainerName -Context $context
    }
    else {
        $items = Get-AzStorageBlob -Container $ContainerName -Blob $BlobName -Context $context
    }

    if ((Test-Path $DestinationPath) -eq $FALSE) {
        New-Item -Path $DestinationPath -ItemType Directory | Out-Null
    }

    foreach ($item in $items) {
        Get-AzStorageBlobContent -Container $ContainerName -Blob $item.Name -Destination $DestinationPath -Context $context -Force | Out-Null
    }
}

function New-AccountProvisioning {
    Param (
        [Parameter(Mandatory=$True)]
        [string] $StateDir,
        [Parameter(Mandatory=$True)]
        [string[]] $ContactEmails,
        [Parameter()]
        [switch] $Staging
    )

    if ($Staging) {
        $serviceName = "LetsEncrypt-Staging"
    }
    else {
        $serviceName = "LetsEncrypt"
    }

    # Create a state object and save it to the harddrive
    $state = New-ACMEState -Path $StateDir

    # Fetch the service directory and save it in the state
    Get-ACMEServiceDirectory -State $state -ServiceName $serviceName

    # Get the first anti-replay nonce
    New-ACMENonce -State $state

    # Create an account key. The state will make sure it's stored.
    New-ACMEAccountKey -State $state

    # Register the account key with the acme service. The account key will automatically be read from the state
    Write-Output "Create new ACME account with EMails: $ContactEmails"
    New-ACMEAccount -State $state -EmailAddresses $ContactEmails -AcceptTOS

    return $state
}

function Get-SubDomainFromHostname {
    Param (
        [Parameter(Mandatory=$true)]
        [string] $Hostname
    )

    $splitDomainParts = $Hostname -split "\."
    $subDomain = ""
    for ($i =0; $i -lt $splitDomainParts.Length-2; $i++) {
        $subDomain += "{0}." -f $splitDomainParts[$i]
    }
    return $subDomain.SubString(0,$subDomain.Length-1)
}

function Add-TxtRecordToDns {
    Param (
        [Parameter(Mandatory=$True)]
        [string] $SubscriptionId,
        [Parameter(Mandatory=$True)]
        [string] $ResourceGroupName,
        [Parameter(Mandatory=$True)]
        [string] $DnsZoneName,
        [Parameter(Mandatory=$True)]
        [string] $TxtName,
        [Parameter(Mandatory=$True)]
        [string] $TxtValue,
        [switch] $IsWildcard
    )

    $subDomain = Get-SubDomainFromHostname -Hostname $TxtName
    Write-Output "-- Switching to DNS zone subscription --"
    Set-AzContext -SubscriptionId $SubscriptionId
    New-AzDnsRecordSet -ResourceGroupName $ResourceGroupName `
                        -ZoneName $DnsZoneName `
                        -Name $subDomain `
                        -RecordType TXT `
                        -Ttl 10 `
                        -DnsRecords (New-AzDnsRecordConfig -Value $TxtValue) `
                        -Confirm:$False `
                        -Overwrite
}

function Remove-TxtRecordToDns {
    Param (
        [Parameter(Mandatory=$True)]
        [string] $SubscriptionId,
        [Parameter(Mandatory=$True)]
        [string] $ResourceGroupName,
        [Parameter(Mandatory=$True)]
        [string] $DnsZoneName,
        [Parameter(Mandatory=$True)]
        [string] $TxtName
    )

    $subDomain = Get-SubDomainFromHostname -Hostname $TxtName
    Write-Output "-- Switching to DNS zone subscription --"

    Set-AzContext -SubscriptionId $SubscriptionId

    $recordSet = Get-AzDnsRecordSet -ResourceGroupName $ResourceGroupName `
                                    -ZoneName $DnsZoneName `
                                    -Name $subDomain `
                                    -RecordType TXT `
                                    -ErrorAction SilentlyContinue

    if ($null -ne $recordSet) {
        Remove-AzDnsRecordSet -RecordSet $recordSet -Confirm:$False -Overwrite
    }
}

try {
    
        if ([string]::IsNullOrWhiteSpace($DefaultSubscriptionId)) {
            $DefaultSubscriptionId = Get-AutomationVariable -Name "DefaultSubscriptionId"
        }

        if ([string]::IsNullOrWhiteSpace($DnsZoneResourceId)) {
            $DnsZoneResourceId = Get-AutomationVariable -Name "DnsZoneResourceId"
        }

        if ([string]::IsNullOrWhiteSpace($StorageAccountResourceId)) {
            $StorageAccountResourceId = Get-AutomationVariable -Name "StorageAccountResourceId"
        }

        if (([string]::IsNullOrWhiteSpace($DefaultResourceGroupName)) -and (([string]::IsNullOrWhiteSpace($StorageAccountResourceId))) -and (([string]::IsNullOrWhiteSpace($DnsZoneResourceId))))    {
            $DefaultResourceGroupName = Get-AutomationVariable -Name "DefaultResourceGroupName"
        }

        if (([string]::IsNullOrWhiteSpace($DefaultStorageAccountName)) -and (([string]::IsNullOrWhiteSpace($StorageAccountResourceId))) -and (([string]::IsNullOrWhiteSpace($DnsZoneResourceId))))   {
            $DefaultStorageAccountName = Get-AutomationVariable -Name "DefaultStorageAccountName"
        }

        if ([string]::IsNullOrWhiteSpace($ContactEmails)) {
            $ContactEmails = Get-AutomationVariable -Name "ContactEmails"
        }

        if ([string]::IsNullOrWhiteSpace($DnsName)) {
            $DnsName = Get-AutomationVariable -Name "DnsName"
        }

        if ([string]::IsNullOrWhiteSpace($KeyVaultName)) {
            $KeyVaultName = Get-AutomationVariable -Name "KeyVaultName"
        }

        if ([string]::IsNullOrWhiteSpace($StorageContainerName)) {
            $StorageContainerName = Get-AutomationVariable -Name "StorageContainerName"
        }

        if ([string]::IsNullOrWhiteSpace($KeyVaultCertificateSecretName)) {
            $KeyVaultCertificateSecretName = Get-AutomationVariable -Name "KeyVaultCertificateSecretName"
        }
        Write-Output "Using the following settings"
        Write-Output "DefaultSubscriptionId: $DefaultSubscriptionId"
        Write-Output "ContactEmails: $(($ContactEmails).split(","))"
        Write-Output "DnsZoneResourceId: $DnsZoneResourceId"
        Write-Output "StorageAccountResourceId: $StorageAccountResourceId"
        Write-Output "DefaultResourceGroupName: $DefaultResourceGroupName"
        Write-Output "DefaultStorageAccountName: $DefaultStorageAccountName"
        Write-Output "DnsName: $DnsName"
        Write-Output "KeyVaultName: $KeyVaultName"
        Write-Output "StorageContainerName: $StorageContainerName"
        Write-Output "KeyVaultCertificateSecretName: $KeyVaultCertificateSecretName"
        Write-Output "Staging: $Staging"

            
        # Ensures that any credentials apply only to the execution of this runbook
        Disable-AzContextAutosave -Scope Process | Out-Null

        # Connect to Azure with system-assigned managed identity
        $AzureContext = (Connect-AzAccount -Identity -SubscriptionId $DefaultSubscriptionId).context
        Write-Output "-- Connected to Azure with default subscription id --"
        Set-AzContext -SubscriptionId $DefaultSubscriptionId -DefaultProfile $AzureContext
        if ([string]::IsNullOrWhiteSpace($DnsZoneResourceId)) {
            $DnsSubscriptionId = $DefaultSubscriptionId
            $DnsResourceGroupName = $DefaultResourceGroupName

        }
        else {
            $DnsSubscriptionId = (Get-AzResource -ResourceId $DnsZoneResourceId).SubscriptionId
            $DnsResourceGroupName = (Get-AzResource -ResourceId $DnsZoneResourceId).ResourceGroupName
        }

        if ([string]::IsNullOrWhiteSpace($StorageAccountResourceId)) {
            $StorageAccountSubscriptionId = $DefaultSubscriptionId
            $StorageAccountResourceGroupName = $DefaultResourceGroupName
            $StorageAccountName = $DefaultStorageAccountName
        }
        else {
            $StorageAccountSubscriptionId = (Get-AzResource -ResourceId $StorageAccountResourceId).SubscriptionId
            $StorageAccountResourceGroupName = (Get-AzResource -ResourceId $StorageAccountResourceId).ResourceGroupName
            $StorageAccountName = (Get-AzResource -ResourceId $StorageAccountResourceId).Name
        }
        
        
        $mainDir = Join-Path $env:TEMP "LetsEncrypt"
        if ($Staging) {
            $stateDir = Join-Path $mainDir "Staging"
        }
        else {
            $stateDir = Join-Path $mainDir "Prod"
        }

        $keyVaultCertificateName = (($DnsName.Replace("*","wildcard")).Replace(".","-")).ToLowerInvariant()
        if ($Staging) {
            $keyVaultCertificateName += "-test"
        }
        Write-Output "-- Fetching the certificate password from Key Vault --"
        $keyVaultSecretValue = Get-AzKeyVaultSecret -VaultName $KeyVaultName -Name $KeyVaultCertificateSecretName -AsPlainText
        $certificatePassword = ConvertTo-SecureString $keyVaultSecretValue -AsPlainText -Force
        Write-Output "-- Switching to storage account subscription --"
        Set-AzContext -SubscriptionId $StorageAccountSubscriptionId
        $storageAccountKey = (Get-AzStorageAccountKey -ResourceGroupName $StorageAccountResourceGroupName -Name $StorageAccountName | Where-Object { $_.KeyName -eq "key1" } | Select-Object Value).Value

        Write-Output "-- Fetching the state directory from storage --"
        if($Staging) {
            Get-DirectoryFromAzureStorage -DestinationPath $mainDir `
                                        -StorageAccountSubscriptionId $StorageAccountSubscriptionId `
                                        -StorageAccountResourceGroupName $StorageAccountResourceGroupName `
                                        -StorageAccountName $StorageAccountName `
                                        -StorageAccountKey $storageAccountKey `
                                        -ContainerName $StorageContainerName `
                                        -BlobName "Staging/*"
        }
        else {
            Get-DirectoryFromAzureStorage -DestinationPath $mainDir `
                                            -StorageAccountSubscriptionId $StorageAccountSubscriptionId `
                                            -StorageAccountResourceGroupName $StorageAccountResourceGroupName `
                                            -StorageAccountName $StorageAccountName `
                                            -StorageAccountKey $storageAccountKey `
                                            -ContainerName $StorageContainerName `
                                            -BlobName "Prod/*"
        }

        $isNew = (Test-Path $stateDir) -eq $false
        if ($isNew) {
            Write-Output "-- Directory is empty. Adding a new account --"
            $state = New-AccountProvisioning -StateDir $stateDir -ContactEmails $ContactEmails.split(",") -Staging:$Staging

            Write-Output "-- Saving the state directory to storage --"
            Add-DirectoryToAzureStorage -Path $mainDir `
                                        -StorageAccountName $StorageAccountName `
                                        -StorageAccountKey $storageAccountKey `
                                        -ContainerName $StorageContainerName
        }
        else {
            # Load an state object to have service directory and account keys available
            Write-Output "-- ACME account exists. Get account data from the state directory --"
            $state = Get-ACMEState -Path $stateDir
        }

        # It might be neccessary to acquire a new nonce, so we'll just do it for the sake.
        Write-Output "-- Acquiring new nonce --"
        $state = Get-ACMEState -Path $stateDir
        New-ACMENonce -State $state

        # Create the identifier for the DNS name
        Write-Output "-- Create new DNS identifier --"
        $identifier = New-ACMEIdentifier $DnsName

        # Create the order object at the ACME service.
        Write-Output "-- Creating a new order --"
        $order = New-ACMEOrder -State $state -Identifiers $identifier

        # Fetch the authorizations for that order
        Write-Output "-- Fetching the authorizations for the order --"
        $authZ = Get-ACMEAuthorization -State $state -Order $order

        # Select a challenge to fullfill
        Write-Output "-- Getting the challenge --"
        $challenge = Get-ACMEChallenge -State $state -Authorization $authZ -Type "dns-01"

        # Inspect the challenge data
        Write-Output "-- Dumping the challenge data --"
        $challenge.Data

        $challengeTxtRecordName = $challenge.Data.TxtRecordName
        $challengeToken = $challenge.Data.Content

        # Insert the data into the proper TXT record
        $splitDomainParts = $challengeTxtRecordName -split "\."
        $dnsZoneName = "{0}.{1}" -f $splitDomainParts[$splitDomainParts.Length-2], $splitDomainParts[$splitDomainParts.Length-1]
        $isWildcard = $DnsName.StartsWith("*.")

        Write-Output "-- Adding the txt record --"
        # Remove the TXT record in case it is already there
        Remove-TxtRecordToDns -SubscriptionId $DnsSubscriptionId `
                            -ResourceGroupName $DnsResourceGroupName `
                            -DnsZoneName $dnsZoneName `
                            -TxtName $challengeTxtRecordName

        Add-TxtRecordToDns -SubscriptionId $DnsSubscriptionId `
                            -ResourceGroupName $DnsResourceGroupName `
                            -DnsZoneName $dnsZoneName `
                            -TxtName $challengeTxtRecordName `
                            -TxtValue $challengeToken `
                            -IsWildcard:$isWildcard

        # Wait 5 seconds for the DNS to set
        Start-Sleep -Seconds 5

        # Signal the ACME server that the challenge is ready
        Write-Output "-- Signaling the challenge as ready --"
        $challenge | Complete-ACMEChallenge -State $state

        # Wait a little bit and update the order, until we see the states
        $tries = 1
        while($order.Status -notin ("ready","invalid") -and $tries -le 3) {
            $waitTimeInSeconds = 10 * $tries
            Write-Output "-- Order is not ready... waiting $waitTimeInSeconds seconds --"
            Start-Sleep -Seconds $waitTimeInSeconds
            $order | Update-ACMEOrder -State $state -PassThru
            $tries = $tries + 1
        }

        if ($order.Status -eq "invalid") {
            # ACME-PS as of version 1.0.7 doesn't have the error property. Fetch manually
            $authZWithError = Invoke-RestMethod -Uri $authZ.ResourceUrl
            Write-Error "-- Order failed. It is in invalid state. Reason: $($authZWithError.challenges.error.detail) --"
            return
        }

        # We should have a valid order now and should be able to complete it, therefore we need a certificate key
        Write-Output "-- Grabbing the certificate key --"
        $certificateKeyExportPath = Join-Path $stateDir "$DnsName.key.xml".Replace("*","wildcard")
        if (Test-Path $certificateKeyExportPath) {
            Remove-Item -Path $certificateKeyExportPath
        }
        $certKey = New-ACMECertificateKey -Path $certificateKeyExportPath

        # Complete the order - this will issue a certificate singing request
        Write-Output "-- Completing the order --"
        Complete-ACMEOrder -State $state -Order $order -CertificateKey $certKey;

        # Now we wait until the ACME service provides the certificate url
        while(-not $order.CertificateUrl) {
            Write-Output "-- Certificate url is not ready... waiting 15 seconds --"
            Start-Sleep -Seconds 15
            $order | Update-ACMEOrder -State $state -PassThru
        }

        # As soon as the url shows up we can create the PFX
        Write-Output "-- Exporting the certificate to the filesystem --"
        $certificateExportPath = Join-Path $stateDir "$DnsName.pfx".Replace("*","wildcard")
        Export-ACMECertificate -State $state -Order $order -CertificateKey $certKey -Path $certificateExportPath -Password $certificatePassword

        # Remove the TXT Record
        Write-Output "-- Removing the TXT record --"
        Remove-TxtRecordToDns -SubscriptionId $DnsSubscriptionId `
                                -ResourceGroupName $DnsResourceGroupName `
                                -DnsZoneName $dnsZoneName `
                                -TxtName $challengeTxtRecordName

        # Save the certificate into the keyvault
        Write-Output "-- Adding the certificate to the key vault --"
        Import-AzKeyVaultCertificate -VaultName $KeyVaultName -Name $keyVaultCertificateName -FilePath $certificateExportPath -Password $certificatePassword

        # Remove the certificate and key
        Write-Output "-- Removing the certificate data from the filesystem --"
        Remove-Item -Path $certificateExportPath -Force | Out-Null
        Remove-Item -Path $certificateKeyExportPath -Force | Out-Null

        if ($Staging -eq $False) {
            Write-Output "-- Saving the state directory to storage --"
            Add-DirectoryToAzureStorage -Path $mainDir `
                                        -StorageAccountName $StorageAccountName `
                                        -StorageAccountKey $storageAccountKey `
                                        -ContainerName $StorageContainerName
        }
}
catch {
    $ErrorMessage = $_.Exception.Message
    Write-Error "An error occurred: $ErrorMessage"

    if (Test-Path variable:dnsZoneName -and Test-Path variable:challengeTxtRecordName -and Test-Path variable:isWildcard) {
        # Remove the TXT Record
        Write-Output "-- Removing the TXT record --"
        Remove-TxtRecordToDns -SubscriptionId $DnsSubscriptionId `
                            -ResourceGroupName $DnsResourceGroupName `
                            -DnsZoneName $dnsZoneName `
                            -TxtName $challengeTxtRecordName
    }
}
