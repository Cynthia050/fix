# Comprehensive deployment script for ADF with SHIR, Private Endpoint, and VM backup
param(
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,
    
    [Parameter(Mandatory = $true)]
    [string]$Location,
    
    [Parameter(Mandatory = $true)]
    [ValidateSet("dev", "test", "prod")]
    [string]$EnvironmentName,
    
    [Parameter(Mandatory = $false)]
    [switch]$SkipKeyVaultPrep,
    
    [Parameter(Mandatory = $false)]
    [switch]$SkipValidation
)

# Set error action preference
$ErrorActionPreference = "Stop"

# Set deployment variables
$dataFactoryName = "test-ist-df-$EnvironmentName-datasync"
$keyVaultName = "kv-adf-$EnvironmentName"
$shirVmPasswordSecretName = "shir-vm-password"
$deploymentName = "ADF-Deployment-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
$templateFile = "./templates/azuredeploy.json"
$parameterFile = "./templates/azuredeploy.parameters.$EnvironmentName.json"

# Create resource group if it doesn't exist
$resourceGroup = Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction SilentlyContinue
if ($null -eq $resourceGroup) {
    Write-Host "Creating resource group '$ResourceGroupName' in location '$Location'..."
    New-AzResourceGroup -Name $ResourceGroupName -Location $Location
}

# Prepare Key Vault secret for SHIR VM password if not skipped
if (-not $SkipKeyVaultPrep) {
    Write-Host "Preparing Key Vault secret for SHIR VM password..."
    
    # Check if Key Vault exists
    $keyVault = Get-AzKeyVault -VaultName $keyVaultName -ErrorAction SilentlyContinue
    if ($null -eq $keyVault) {
        Write-Host "Key Vault '$keyVaultName' does not exist. Creating..."
        $keyVault = New-AzKeyVault -VaultName $keyVaultName -ResourceGroupName $ResourceGroupName -Location $Location -EnabledForTemplateDeployment $true
    }
    
    # Check if secret exists
    $secretExists = Get-AzKeyVaultSecret -VaultName $keyVaultName -Name $shirVmPasswordSecretName -ErrorAction SilentlyContinue
    
    if ($null -eq $secretExists) {
        Write-Host "Secret does not exist. Generating a new secure password..."
        
        # Add the required assembly for password generation
        Add-Type -AssemblyName System.Web
        
        # Generate a secure password
        $length = 16
        $nonAlphaChars = 5
        $password = [System.Web.Security.Membership]::GeneratePassword($length, $nonAlphaChars)
        $securePassword = ConvertTo-SecureString -String $password -AsPlainText -Force
        
        Write-Host "Setting secret '$shirVmPasswordSecretName' in Key Vault '$keyVaultName'..."
        $secret = Set-AzKeyVaultSecret -VaultName $keyVaultName -Name $shirVmPasswordSecretName -SecretValue $securePassword
        
        Write-Host "Secret has been created successfully. Secret ID: $($secret.Id)"
    }
    else {
        Write-Host "Secret '$shirVmPasswordSecretName' already exists in Key Vault '$keyVaultName'. Using existing secret."
    }
    
    # Verify CMK key for encryption
    $cmkKeyName = "adf-cmk-$EnvironmentName"
    $keyExists = Get-AzKeyVaultKey -VaultName $keyVaultName -Name $cmkKeyName -ErrorAction SilentlyContinue
    
    if ($null -eq $keyExists) {
        Write-Host "CMK key '$cmkKeyName' does not exist. Creating..."
        $key = Add-AzKeyVaultKey -VaultName $keyVaultName -Name $cmkKeyName -Destination Software
        Write-Host "CMK key has been created successfully. Key ID: $($key.Id)"
    }
    else {
        Write-Host "CMK key '$cmkKeyName' already exists in Key Vault '$keyVaultName'. Using existing key."
    }
}

# Validate the ARM template if not skipped
if (-not $SkipValidation) {
    Write-Host "Validating ARM template..."
    $validation = Test-AzResourceGroupDeployment -ResourceGroupName $ResourceGroupName `
        -TemplateFile $templateFile `
        -TemplateParameterFile $parameterFile
    
    if ($validation) {
        Write-Host "ARM template validation failed:"
        foreach ($error in $validation) {
            Write-Host "- $($error.Message)"
        }
        exit 1
    }
}

# Deploy the ARM template
Write-Host "Deploying ARM template..."
$deployment = New-AzResourceGroupDeployment -Name $deploymentName `
    -ResourceGroupName $ResourceGroupName `
    -TemplateFile $templateFile `
    -TemplateParameterFile $parameterFile `
    -Mode Incremental `
    -Verbose

if ($deployment.ProvisioningState -eq "Succeeded") {
    Write-Host "Deployment completed successfully."
    
    # Get the Data Factory resource
    $dataFactory = Get-AzDataFactoryV2 -ResourceGroupName $ResourceGroupName -Name $dataFactoryName
    Write-Host "Azure Data Factory deployed: $($dataFactory.DataFactoryName)"
    
    # Get the SHIR status
    $shirName = "ir10Prem"
    Write-Host "Getting status of Self-Hosted Integration Runtime '$shirName'..."
    $shir = Get-AzDataFactoryV2IntegrationRuntime -ResourceGroupName $ResourceGroupName -DataFactoryName $dataFactoryName -Name $shirName
    $shirStatus = Get-AzDataFactoryV2IntegrationRuntimeStatus -ResourceGroupName $ResourceGroupName -DataFactoryName $dataFactoryName -Name $shirName
    
    Write-Host "Self-Hosted Integration Runtime Status: $($shirStatus.State)"
    
    # Configure additional network security rules for ADF connectivity if needed
    $vmName = "vm-shir-$EnvironmentName"
    Write-Host "Configuring additional network security rules for ADF connectivity..."
    
    # Get VM and related resources
    $vm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $vmName -ErrorAction SilentlyContinue
    if ($null -ne $vm) {
        $nic = Get-AzNetworkInterface -ResourceId $vm.NetworkProfile.NetworkInterfaces[0].Id
        $nsg = Get-AzNetworkSecurityGroup -ResourceGroupName $ResourceGroupName -Name "$vmName-nsg" -ErrorAction SilentlyContinue
        
        if ($null -ne $nsg) {
            # Add rules to allow traffic from ADF to ADLS Gen2
            $nsgRule = $nsg.SecurityRules | Where-Object { $_.Name -eq "ADF-to-ADLS-Gen2" } -ErrorAction SilentlyContinue
            if ($null -eq $nsgRule) {
                Write-Host "Adding NSG rule for ADF to ADLS Gen2 connection..."
                $nsg = Add-AzNetworkSecurityRuleConfig -NetworkSecurityGroup $nsg -Name "ADF-to-ADLS-Gen2" `
                    -Description "Allow traffic from ADF to ADLS Gen2" `
                    -Access Allow -Protocol Tcp -Direction Outbound -Priority 1050 `
                    -SourceAddressPrefix VirtualNetwork -SourcePortRange * `
                    -DestinationAddressPrefix Storage -DestinationPortRange 443
                
                # Update the NSG with the new rule
                $nsg | Set-AzNetworkSecurityGroup
            }
        }
    }
    
    Write-Host "Deployment process completed. Azure Data Factory with Self-Hosted Integration Runtime is now deployed and configured."
}
else {
    Write-Host "Deployment failed with state: $($deployment.ProvisioningState)"
    Write-Host "Error: $($deployment.Error)"
    exit 1
}