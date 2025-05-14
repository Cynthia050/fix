# Creates or updates a Key Vault secret for the SHIR VM password
# Parameters:
#   KeyVaultName: Name of the Key Vault
#   SecretName: Name of the secret to create/update

param(
    [Parameter(Mandatory = $true)]
    [string]$KeyVaultName,
    
    [Parameter(Mandatory = $true)]
    [string]$SecretName
)

function GenerateSecurePassword {
    $length = 16
    $nonAlphaChars = 5
    $password = [System.Web.Security.Membership]::GeneratePassword($length, $nonAlphaChars)
    $securePassword = ConvertTo-SecureString -String $password -AsPlainText -Force
    return $securePassword
}

# Add the required assembly for password generation
Add-Type -AssemblyName System.Web

Write-Host "Checking if secret '$SecretName' exists in Key Vault '$KeyVaultName'..."
$secretExists = Get-AzKeyVaultSecret -VaultName $KeyVaultName -Name $SecretName -ErrorAction SilentlyContinue

if ($null -eq $secretExists) {
    Write-Host "Secret does not exist. Generating a new secure password..."
    $securePassword = GenerateSecurePassword

    Write-Host "Setting secret '$SecretName' in Key Vault '$KeyVaultName'..."
    $secret = Set-AzKeyVaultSecret -VaultName $KeyVaultName -Name $SecretName -SecretValue $securePassword
    
    Write-Host "Secret has been created successfully. Secret ID: $($secret.Id)"
}
else {
    Write-Host "Secret '$SecretName' already exists in Key Vault '$KeyVaultName'. Using existing secret."
}

Write-Host "Key Vault secret operation completed."