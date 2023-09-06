# Install-PackageProvider -Name NuGet -Force
# Set-PSRepository -Name 'PSGallery' -InstallationPolicy Trusted
# Install-Module -name PSDesiredStateConfiguration
# Install-Module -name ComputerManagementDsc -force
# Publish-AzVMDscConfiguration ".\Deploy-RDSHost.ps1" -OutputArchivePath ".\Deploy-RDSHost.ps1.zip" -Force


Configuration Deploy-RDSHost
{
    
    
    Import-DscResource -ModuleName 'PSDesiredStateConfiguration'
    Import-DscResource -ModuleName 'ComputerManagementDsc'


    Node localhost
    {
        LocalConfigurationManager 
        {
            ConfigurationMode = 'ApplyOnly'
            RebootNodeIfNeeded = $true
        }

        WindowsFeature InstallRDSSHost
        {
            Ensure = 'Present'
            Name = 'RDS-RD-Server'
        }

        PendingReboot RebootAfterInstallRDSSHost
        {
            Name = 'RebootAfterInstallRDSSHost'
            DependsOn = "[WindowsFeature]InstallRDSSHost"
        }
    }
}

