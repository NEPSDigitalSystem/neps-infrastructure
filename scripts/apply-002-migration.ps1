# ═════════════════════════════════════════════════════════════════════════════
# NEPS Digital — Apply Additive V3.1 Migration (002 Independent Source Intake)
# DevOps / Infrastructure PowerShell Script (Windows)
# ═════════════════════════════════════════════════════════════════════════════

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$InfraDir = Split-Path -Parent $ScriptDir
$RepoRoot = Split-Path -Parent $InfraDir
$SqlFile = Join-Path $RepoRoot "NDS_Team\migrations\Independent_Source_Intake_Additive_PostgreSQL.sql"

Write-Host "=== NEPS V3.1 Additive Database Migration Tool (PowerShell) ===" -ForegroundColor Cyan

if (-not (Test-Path $SqlFile)) {
    Write-Error "ERROR: Additive migration SQL file not found at: $SqlFile"
    exit 1
}

Write-Host "Source SQL: $SqlFile"

$PostgresContainer = $(docker ps --filter "name=postgres" --format "{{.Names}}" | Select-Object -First 1)

if (-not $PostgresContainer) {
    Write-Error "ERROR: No running PostgreSQL container detected. Please start stack first."
    exit 1
}

Write-Host "Target Container: $PostgresContainer"

Write-Host "Applying additive migration to neps_db..." -ForegroundColor Yellow
Get-Content $SqlFile -Raw | docker exec -i $PostgresContainer psql -U neps -d neps_db -v ON_ERROR_STOP=1

Write-Host "`n=== Verifying 9 Additive Tables ===" -ForegroundColor Cyan
$ExpectedTables = @(
    "nds_v31_intake_raw",
    "nds_v31_intake_audit",
    "nds_v31_intake_head",
    "nds_v31_intake_pending",
    "nds_v31_participant_links",
    "nds_v31_source",
    "nds_v31_audit",
    "nds_v31_derived",
    "nds_v31_validated"
)

$AllPresent = $true
foreach ($table in $ExpectedTables) {
    $exists = $(docker exec -i $PostgresContainer psql -U neps -d neps_db -tAc "SELECT to_regclass('public.$table');").Trim()
    if ($exists -eq $table -or $exists.Length -gt 0) {
        Write-Host "  [OK] Table '$table' confirmed." -ForegroundColor Green
    } else {
        Write-Host "  [MISSING] Table '$table' NOT found!" -ForegroundColor Red
        $AllPresent = $false
    }
}

if ($AllPresent) {
    Write-Host "`nSUCCESS: All 9 independent intake tables verified successfully." -ForegroundColor Green
} else {
    Write-Error "WARNING: Verification incomplete."
}
