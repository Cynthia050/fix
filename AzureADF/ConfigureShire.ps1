# Script to configure the Self-Hosted Integration Runtime after deployment
# Parameters:
#   ResourceGroupName: Name of the resource group containing ADF
#   DataFactoryName: Name of the Azure Data Factory
#   IntegrationRuntimeName: Name of the Self-Hosted Integration Runtime
#   VMName: Name of the VM for SHIR

param(
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,
    
    [Parameter(Mandatory = $true)]
    [string]$DataFactoryName,
    
    [Parameter(Mandatory = $true)]
    [string]$IntegrationRuntimeName,
    
    [Parameter(Mandatory = $true)]
    [string]$VMName
)

# Wait for the VM to be fully deployed and the SHIR to be installed
Write-Host "Waiting for VM deployment and SHIR installation to complete..."
Start-Sleep -Seconds 300

# Restart the VM to ensure SHIR service is properly registered
Write-Host "Restarting the VM '$VMName' to ensure SHIR service is properly registered..."
Restart-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName

Write-Host "Waiting for VM to restart..."
Start-Sleep -Seconds 180

# Get the SHIR status
Write-Host "Getting status of Self-Hosted Integration Runtime '$IntegrationRuntimeName'..."
$shir = Get-AzDataFactoryV2IntegrationRuntime -ResourceGroupName $ResourceGroupName -DataFactoryName $DataFactoryName -Name $IntegrationRuntimeName

# Wait until the SHIR is online
$maxRetries = 10
$retryCount = 0
$shirOnline = $false

while (-not $shirOnline -and $retryCount -lt $maxRetries) {
    $shir = Get-AzDataFactoryV2IntegrationRuntime -ResourceGroupName $ResourceGroupName -DataFactoryName $DataFactoryName -Name $IntegrationRuntimeName
    $shirStatus = Get-AzDataFactoryV2IntegrationRuntimeStatus -ResourceGroupName $ResourceGroupName -DataFactoryName $DataFactoryName -Name $IntegrationRuntimeName

    if ($shirStatus.State -eq "Online") {
        $shirOnline = $true
        Write-Host "Self-Hosted Integration Runtime is now online."
    }
    else {
        $retryCount++
        Write-Host "Self-Hosted Integration Runtime is not yet online. Status: $($shirStatus.State). Retry $retryCount of $maxRetries. Waiting 60 seconds..."
        Start-Sleep -Seconds 60
    }
}

if (-not $shirOnline) {
    Write-Warning "Self-Hosted Integration Runtime did not come online within the expected time. Please check the VM and SHIR configuration manually."
    exit 1
}

# Configure network security rules for ADF connectivity
Write-Host "Configuring additional network security rules for ADF connectivity..."

# Add NSG rules for ADF connectivity to various services
$vm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName
$nic = Get-AzNetworkInterface -ResourceId $vm.NetworkProfile.NetworkInterfaces[0].Id
$nsg = Get-AzNetworkSecurityGroup -ResourceGroupName $ResourceGroupName -Name "$VMName-nsg"

# Add rules to allow traffic from ADF to ADLS Gen2
$nsg = Add-AzNetworkSecurityRuleConfig -NetworkSecurityGroup $nsg -Name "ADF-to-ADLS-Gen2" `
    -Description "Allow traffic from ADF to ADLS Gen2" `
    -Access Allow -Protocol Tcp -Direction Outbound -Priority 1050 `
    -SourceAddressPrefix VirtualNetwork -SourcePortRange * `
    -DestinationAddressPrefix Storage -DestinationPortRange 443

# Add rules to allow traffic from ADF to Key Vault
$nsg = Add-AzNetworkSecurityRuleConfig -NetworkSecurityGroup $nsg -Name "ADF-to-Key-Vault" `
    -Description "Allow traffic from ADF to Key Vault" `
    -Access Allow -Protocol Tcp -Direction Outbound -Priority 1060 `
    -SourceAddressPrefix VirtualNetwork -SourcePortRange * `
    -DestinationAddressPrefix AzureKeyVault -DestinationPortRange 443

# Add rules to allow traffic from ADF to Azure SQL
$nsg = Add-AzNetworkSecurityRuleConfig -NetworkSecurityGroup $nsg -Name "ADF-to-SQL" `
    -Description "Allow traffic from ADF to Azure SQL" `
    -Access Allow -Protocol Tcp -Direction Outbound -Priority 1070 `
    -SourceAddressPrefix VirtualNetwork -SourcePortRange * `
    -DestinationAddressPrefix Sql -DestinationPortRange 1433

# Update the NSG with the new rules
$nsg | Set-AzNetworkSecurityGroup

Write-Host "Self-Hosted Integration Runtime configuration completed successfully."