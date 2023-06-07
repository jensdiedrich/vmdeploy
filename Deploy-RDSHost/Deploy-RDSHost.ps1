# Install-PackageProvider -Name NuGet -Force
# Set-PSRepository -Name 'PSGallery' -InstallationPolicy Trusted
# Install-Module -name PSDesiredStateConfiguration
# Install-Module -name ComputerManagementDsc -force
# Publish-AzVMDscConfiguration ".\Deploy-RDSHost.ps1" -OutputArchivePath ".\Deploy-RDSHost.ps1.zip" -Force


Configuration Deploy-RDSHost
{
    Param
    (
        [Parameter(Mandatory)]
        [String] $domainFQDN,

        [Parameter(Mandatory)]
        [String] $computerName,

        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential] $adminCredential
    )
    
    Import-DscResource -ModuleName 'PSDesiredStateConfiguration'
    Import-DscResource -ModuleName 'ComputerManagementDsc'

    # Create the NetBIOS name and domain credentials based on the domain FQDN
    [String] $domainNetBIOSName = (Get-NetBIOSName -DomainFQDN $domainFQDN)
    # [System.Management.Automation.PSCredential] $domainCredential = New-Object System.Management.Automation.PSCredential ("${domainNetBIOSName}\$($adminCredential.UserName)", $adminCredential.Password)
    [System.Management.Automation.PSCredential] $domainCredential = New-Object System.Management.Automation.PSCredential ("$($adminCredential.UserName)@$($domainGQDN)", $adminCredential.Password)


    $interface = Get-NetAdapter | Where-Object Name -Like "Ethernet*" | Select-Object -First 1
    $interfaceAlias = $($interface.Name)

    Node localhost
    {
        LocalConfigurationManager 
        {
            ConfigurationMode = 'ApplyOnly'
            RebootNodeIfNeeded = $true
        }

        Computer JoinDomain
        {
            Name = $computerName 
            DomainName = $domainFQDN
            Credential = $domainCredential
        }

        PendingReboot RebootAfterJoiningDomain
        {
            Name = 'RebootAfterJoiningDomain'
            DependsOn = "[Computer]JoinDomain"
        }

        WindowsFeature InstallRDSSHost
        {
            Ensure = 'Present'
            Name = 'RDS-RD-Server'
            DependsOn = '[PendingReboot]RebootAfterJoiningDomain'
        }

        PendingReboot RebootAfterInstallRDSSHost
        {
            Name = 'RebootAfterInstallRDSSHost'
            DependsOn = "[WindowsFeature]InstallRDSSHost"
        }
    }
}

function Get-NetBIOSName {
    [OutputType([string])]
    param(
        [string] $domainFQDN
    )

    if ($domainFQDN.Contains('.')) {
        $length = $domainFQDN.IndexOf('.')
        if ( $length -ge 16) {
            $length = 15
        }
        return $domainFQDN.Substring(0, $length)
    }
    else {
        if ($domainFQDN.Length -gt 15) {
            return $domainFQDN.Substring(0, 15)
        }
        else {
            return $domainFQDN
        }
    }
}