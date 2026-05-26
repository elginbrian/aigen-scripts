<#
.SYNOPSIS
    Run the full AiGen PR import pipeline on the VPS in one command.

.DESCRIPTION
    Automates the full diagram flow by making HTTP calls to the VPS services.
    URLs and credentials are auto-read from your local .env files
    (synced from VPS via `aigen env pull`).

    Flow:
      1. Read VPS URLs + credentials from local .env files
      2. Login to VPS backend -> get JWT token
      3. POST mock SAP data to VPS /mock/search-library  (optional, skip with -SkipMockData)
      4. POST to VPS import-pr-gateway /pr-sourcing/aigen  -> publishes Kafka event
      5. VPS aigen-import-pr worker processes: importPRData() + syncRFQData()
      6. Worker calls VPS backend email endpoints automatically

.PARAMETER LastPeriodDays
    How many days back the import-pr worker should scan. Default: 14

.PARAMETER MockDataFile
    Path to a JSON file with mock search_library records.
    If omitted, uses the built-in minimal test payload.

.PARAMETER SkipMockData
    Skip Step 3 (mock data injection). Use when real PRPO data already exists on VPS.

.PARAMETER WaitSeconds
    Seconds to wait for the Kafka worker to finish before printing results. Default: 15

.EXAMPLE
    # Full flow - reads everything from .env files
    aigen run-flow

.EXAMPLE
    # Skip mock data (real data already in VPS PRPO DB)
    aigen run-flow -SkipMockData

.EXAMPLE
    # Use a custom mock data file and wait longer
    aigen run-flow -MockDataFile "D:\DOT Indonesia\sql\mock_pr_data.json" -WaitSeconds 30
#>

param(
    [int]$LastPeriodDays = 14,
    [string]$MockDataFile = '',
    [switch]$SkipMockData,
    [int]$WaitSeconds = 15
)

$ErrorActionPreference = 'Stop'
$workspaceRoot = 'D:\DOT Indonesia'

# -------------------------------------------------
# HELPERS
# -------------------------------------------------

function Write-Step {
    param([string]$Number, [string]$Message)
    Write-Host ""
    Write-Host "========================================" -ForegroundColor DarkCyan
    Write-Host "  STEP $Number - $Message" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor DarkCyan
}

function Write-Success { param([string]$Msg); Write-Host "  [OK] $Msg" -ForegroundColor Green }
function Write-Fail    { param([string]$Msg); Write-Host "  [FAIL] $Msg" -ForegroundColor Red }
function Write-Info    { param([string]$Msg); Write-Host "  -> $Msg" -ForegroundColor Gray }
function Write-Warn    { param([string]$Msg); Write-Host "  [WARN] $Msg" -ForegroundColor Yellow }

# Read a KEY=VALUE from a .env file
function Get-EnvValue {
    param([string]$FilePath, [string]$Key)
    if (-not (Test-Path $FilePath)) { return $null }
    $line = Get-Content $FilePath | Where-Object { $_ -match "^\s*$([regex]::Escape($Key))\s*=" } | Select-Object -First 1
    if (-not $line) { return $null }
    return (($line -split '=', 2)[1]).Trim().Trim('"').Trim("'")
}

# HTTP call helper — throws on non-2xx
function Invoke-Api {
    param(
        [string]$Method,
        [string]$Uri,
        [hashtable]$Headers = @{},
        [object]$Body = $null
    )
    $params = @{
        Method      = $Method
        Uri         = $Uri
        Headers     = $Headers
        ContentType = 'application/json'
        ErrorAction = 'Stop'
    }
    if ($null -ne $Body) {
        $params.Body = ($Body | ConvertTo-Json -Depth 20 -Compress)
    }
    try {
        return Invoke-RestMethod @params
    } catch {
        $statusCode = $_.Exception.Response.StatusCode.value__
        $rawBody    = $_.ErrorDetails.Message
        throw "HTTP $statusCode - $rawBody"
    }
}

# -------------------------------------------------
# STEP 0 - READ CONFIG FROM LOCAL .env FILES
# (These are synced from VPS via `aigen env pull`)
# -------------------------------------------------

Write-Step '0' 'Reading VPS config from local .env files'

$backendEnvPath = Join-Path $workspaceRoot 'backend\.env'
$gatewayEnvPath = Join-Path $workspaceRoot 'import-pr-gateway\.env'

if (-not (Test-Path $backendEnvPath)) {
    Write-Fail "backend/.env not found at: $backendEnvPath"
    Write-Warn "Run 'aigen env pull' first to sync VPS .env files locally."
    exit 1
}
if (-not (Test-Path $gatewayEnvPath)) {
    Write-Fail "import-pr-gateway/.env not found at: $gatewayEnvPath"
    Write-Warn "Run 'aigen env pull' first to sync VPS .env files locally."
    exit 1
}

# --- Backend URL ---
# APP_URL in backend .env = VPS public URL (e.g. http://103.175.221.88)
# Backend runs on port 3001 on VPS (deploy-run-3001.sh maps container 3000 -> host 3001)
$appUrl = Get-EnvValue -FilePath $backendEnvPath -Key 'APP_URL'
if (-not $appUrl) {
    Write-Fail "APP_URL not found in backend/.env"
    exit 1
}
# Strip trailing slash, ensure port 3001
$vpsHost = ($appUrl -replace 'https?://', '').Split(':')[0].Split('/')[0]
$backendUrl = "http://${vpsHost}:3001"

# --- Gateway URL ---
# import-pr-gateway runs on HOST_PORT=4000 on VPS
$gatewayHostPort = Get-EnvValue -FilePath $gatewayEnvPath -Key 'HOST_PORT'
$gatewayPort = if ($gatewayHostPort) { $gatewayHostPort } else { '4000' }
$gatewayUrl = "http://${vpsHost}:${gatewayPort}"

# --- Gateway API Key ---
$gatewayApiKey = Get-EnvValue -FilePath $gatewayEnvPath -Key 'API_KEY_AIGEN'
if (-not $gatewayApiKey) {
    Write-Fail "API_KEY_AIGEN not found in import-pr-gateway/.env"
    Write-Warn "Set API_KEY_AIGEN in import-pr-gateway/.env and run 'aigen env pull' again."
    exit 1
}

# --- Login credentials ---
# Read from env vars or prompt
$loginIdentifier = $env:AIGEN_LOGIN_IDENTIFIER
$loginPassword   = $env:AIGEN_LOGIN_PASSWORD

if (-not $loginIdentifier) {
    $loginIdentifier = Read-Host "  Backend login email/username"
}
if (-not $loginPassword) {
    $rawPass = Read-Host "  Backend login password" -AsSecureString
    $loginPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($rawPass)
    )
}

Write-Success "Config loaded"
Write-Info "VPS Host  : $vpsHost"
Write-Info "Backend   : $backendUrl"
Write-Info "Gateway   : $gatewayUrl"
Write-Info "Period    : last $LastPeriodDays days"
Write-Info "Skip mock : $($SkipMockData.IsPresent)"

# -------------------------------------------------
# BUILT-IN MOCK PAYLOAD
# Adjust groups/vendor/material to match your VPS config_auto_po rules
# -------------------------------------------------

$mockPrNumber = "PR-TEST-$(Get-Random -Minimum 1000 -Maximum 9999)"

$defaultMockData = @()
for ($i = 1; $i -le 10; $i++) {
    $matNumber = "00$($i * 10)".Substring("00$($i * 10)".Length - 4)
    
    $defaultMockData += @{
        tipe_data                    = 'DETAIL'
        pr_number                    = $mockPrNumber
        material_number              = $matNumber
        pr_type                      = 'ZST'
        pr_material_group            = 'MECHANICAL'
        pr_material_group_number     = '001'
        pr_requestor_user            = 'test.user'
        pr_requestor_email           = 'test.user@example.com'
        pr_creator_user              = 'test.creator'
        pr_creator_email             = 'test.creator@example.com'
        text                         = "Mock PR Item $i for AiGen flow test"
        tipe                         = 'PR'
        qty_item                     = Get-Random -Minimum 1 -Maximum 10
        unit_item                    = 'EA'
        value                        = 400 # 400 * 10 = 4000 (must be < 5000 for BCG config rules)
        currency                     = 'USD'
        src_value                    = 6000000
        src_currency                 = 'IDR'
        value_idr                    = 6000000
        price_item_idr               = 6000000
        groups                       = 'BCG'
        company                      = '1000'
        create_date                  = (Get-Date -Format 'yyyy-MM-dd')
        pr_release_date              = (Get-Date -Format 'yyyy-MM-dd')
        delivery_date                = (Get-Date).AddDays(30).ToString('yyyy-MM-dd')
        status                       = 'Full Release'
        division                     = 'PROCUREMENT'
        purchase_group               = 'Mechanical Group'
        purchase_group_code          = 'MG01'
        external_material_group      = '5805'
        external_material_group_name = 'External Mechanical'
        nomor_material_sap           = "MAT-000$i"
        plant_code                   = 'P001'
        plant_name                   = 'Plant Jakarta'
        spend_channel                = 'AUTO_PO'
        gl_account_code              = '500001'
        cost_center_code             = 'CC001'
        is_delete                    = 0
        is_oa                        = 0
        is_newItem                   = 1
        is_service                   = 0
    }
}

# -------------------------------------------------
# BANNER
# -------------------------------------------------

Write-Host ""
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "   AiGen PR Import Flow - Targeting VPS       " -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan

# -------------------------------------------------
# STEP 1 - LOGIN TO VPS BACKEND
# -------------------------------------------------

Write-Step '1' "Login to VPS backend ($backendUrl)"

$loginBody = @{ email = $loginIdentifier; password = $loginPassword }

try {
    $loginResponse = Invoke-Api -Method POST -Uri "$backendUrl/auth/login" -Body $loginBody
    $jwt = if ($loginResponse.data.jwtToken) { $loginResponse.data.jwtToken } elseif ($loginResponse.data.token) { $loginResponse.data.token } elseif ($loginResponse.token) { $loginResponse.token } else { $loginResponse.accessToken }
    if (-not $jwt) { throw "Token not found in login response: $($loginResponse | ConvertTo-Json)" }
    Write-Success "Login OK - JWT acquired"
} catch {
    Write-Fail "Login failed: $_"
    exit 1
}

$authHeaders = @{ 'Authorization' = "Bearer $jwt" }

# -------------------------------------------------
# STEP 2 - INJECT MOCK SAP DATA ON VPS (optional)
# -------------------------------------------------

if (-not $SkipMockData) {
    Write-Step '2' "Inject mock SAP data -> VPS POST /mock/search-library"

    if ($MockDataFile -and (Test-Path $MockDataFile)) {
        Write-Info "Loading mock data from file: $MockDataFile"
        $mockPayload = Get-Content $MockDataFile -Raw | ConvertFrom-Json
    } else {
        if ($MockDataFile) { Write-Warn "File not found: $MockDataFile - using built-in payload" }
        else { Write-Info "Using built-in minimal mock payload" }
        $mockPayload = $defaultMockData
    }

    $prNumbers = ($mockPayload | ForEach-Object { $_.pr_number }) -join ', '
    Write-Info "Injecting $($mockPayload.Count) record(s): $prNumbers"

    try {
        $mockResponse = Invoke-Api -Method POST `
            -Uri "$backendUrl/mock/search-library" `
            -Headers $authHeaders `
            -Body $mockPayload
        $msg = if ($mockResponse.message) { $mockResponse.message } else { 'OK' }
        Write-Success "Mock data injected into VPS PRPO DB - $msg"
    } catch {
        Write-Warn "Mock injection failed: $_ - continuing to gateway trigger anyway"
    }
} else {
    Write-Host ""
    Write-Host "  [SKIP] Step 2 - Mock data injection skipped (-SkipMockData)" -ForegroundColor DarkGray
}

# -------------------------------------------------
# STEP 3 - TRIGGER VPS IMPORT-PR-GATEWAY
# -------------------------------------------------

Write-Step '3' "Trigger VPS gateway -> POST $gatewayUrl/pr-sourcing/aigen"

$gatewayHeaders = @{ 'x-api-key' = $gatewayApiKey }

try {
    $gatewayResponse = Invoke-Api -Method POST `
        -Uri "$gatewayUrl/pr-sourcing/aigen?lastPeriodDays=$LastPeriodDays" `
        -Headers $gatewayHeaders

    $requestId = if ($gatewayResponse.requestId) { $gatewayResponse.requestId } else { 'N/A' }
    $status    = if ($gatewayResponse.status) { $gatewayResponse.status } else { 'N/A' }
    Write-Success "Gateway accepted - requestId: $requestId | status: $status"
    Write-Info "Kafka event fired on VPS: AIGEN_IMPORT_PR_REQUEST"
    Write-Info "VPS aigen-import-pr worker is now processing..."
} catch {
    Write-Fail "Gateway trigger failed: $_"
    exit 1
}

# -------------------------------------------------
# STEP 4 - WAIT FOR VPS WORKER
# -------------------------------------------------

Write-Step '4' "Waiting ${WaitSeconds}s for VPS Kafka worker (aigen-import-pr)..."
Write-Info "Tip: Run 'aigen logs ipr' in another terminal to watch live"

for ($i = $WaitSeconds; $i -gt 0; $i--) {
    Write-Host "  [$i]..." -ForegroundColor DarkGray
    Start-Sleep -Seconds 1
}

# -------------------------------------------------
# STEP 5 - VERIFY VPS BACKEND HEALTH
# -------------------------------------------------

Write-Step '5' 'Verify VPS backend is healthy'

try {
    $healthUrl = "http://${vpsHost}:3001/health"
    $health = Invoke-Api -Method GET -Uri $healthUrl
    $hs = if ($health.status) { $health.status } else { 'OK' }
    Write-Success "VPS backend healthy - status: $hs"
} catch {
    Write-Warn "Health check failed (non-critical): $_"
}

# -------------------------------------------------
# DONE
# -------------------------------------------------

Write-Host ""
Write-Host "==============================================" -ForegroundColor Green
Write-Host "          VPS Flow Completed Successfully     " -ForegroundColor Green
Write-Host "==============================================" -ForegroundColor Green
Write-Host ""
Write-Host "  What happened on VPS ($vpsHost):" -ForegroundColor White
Write-Host "   1. JWT token acquired from VPS backend" -ForegroundColor Gray
if (-not $SkipMockData) {
    Write-Host "   2. Mock SAP PR data injected into VPS search_library (PRPO DB)" -ForegroundColor Gray
}
Write-Host "   3. Kafka event fired via VPS import-pr-gateway" -ForegroundColor Gray
Write-Host "   4. VPS aigen-import-pr worker ran importPRData() + syncRFQData()" -ForegroundColor Gray
Write-Host "   5. VPS backend sent vendor + CS emails for generated RFQs" -ForegroundColor Gray
Write-Host ""
Write-Host "  Verify results:" -ForegroundColor White
Write-Host "   * RFQ list   : GET $backendUrl/purchase/rfq" -ForegroundColor DarkCyan
Write-Host "   * Worker logs: aigen logs ipr" -ForegroundColor DarkCyan
Write-Host "   * Backend log: aigen logs be" -ForegroundColor DarkCyan
Write-Host ""
