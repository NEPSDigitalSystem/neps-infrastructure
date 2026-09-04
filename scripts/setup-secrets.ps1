# NEPS Digital - PowerShell secrets setup script
# Creates all required secrets for the docker-compose stack

$ErrorActionPreference = "Stop"

$SECRETS_DIR = Join-Path $PSScriptRoot "..\secrets"

Write-Host "Setting up NEPS Digital secrets..." -ForegroundColor Cyan

# Create secrets directory if it doesn't exist
if (-not (Test-Path $SECRETS_DIR)) {
    New-Item -ItemType Directory -Path $SECRETS_DIR | Out-Null
}

# Function to generate random password
function Generate-Password {
    $bytes = New-Object byte[] 32
    [System.Security.Cryptography.RNGCryptoServiceProvider]::Create().GetBytes($bytes)
    return [Convert]::ToBase64String($bytes) -replace '[=+/]', '' -replace '.{25}', '$0'
}

# Database credentials
$postgresPassword = Generate-Password
$postgresPassword | Out-File -FilePath (Join-Path $SECRETS_DIR "postgres_password.txt") -NoNewline
"neps" | Out-File -FilePath (Join-Path $SECRETS_DIR "postgres_user.txt") -NoNewline

# REDCap API token
"mock_token_neps_2025" | Out-File -FilePath (Join-Path $SECRETS_DIR "redcap_api_token.txt") -NoNewline

# App secret key
$appSecretKey = (Generate-Password) + (Generate-Password)
$appSecretKey | Out-File -FilePath (Join-Path $SECRETS_DIR "app_secret_key.txt") -NoNewline

Write-Host "Secrets generated in $SECRETS_DIR/" -ForegroundColor Green
Write-Host "  - postgres_password.txt"
Write-Host "  - postgres_user.txt"
Write-Host "  - redcap_api_token.txt"
Write-Host "  - app_secret_key.txt"
Write-Host ""
Write-Host "IMPORTANT: Do NOT enable the discord-alerts overlay unless you have a valid, private Discord webhook URL!" -ForegroundColor Yellow
