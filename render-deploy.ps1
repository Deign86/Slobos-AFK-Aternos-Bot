<#
render-deploy.ps1 - Slobos-AFK-Aternos-Bot
Creates (or updates) a free Web Service on Render for the configured fork.

Single source of truth for Render API automation. See references in
hermes skill `render-service-automation` for API schema gotchas:
  - GET /v1/owners (NOT /v1/identities) to resolve ownerId
  - POST /v1/services requires serviceDetails nesting
  - buildCommand / startCommand go under serviceDetails.envSpecificDetails
  - autoDeploy is an enum ("yes"/"no"), not bool
  - env vars bulk endpoint: PUT /v1/services/{id}/env-vars/bulk (top-level array)

Behavior:
  1. Verify RENDER_API_KEY is set; exit 1 if missing
  2. Resolve ownerId via GET /v1/owners
  3. Create Web Service with the canonical schema, or update if it already exists
  4. Set env vars (NODE_ENV=production)
  5. Trigger a deploy
  6. Poll deploy status until terminal (live / failed / canceled)
  7. Write render-deploy-metadata.json in repo root

The bot process binds to PORT (Render injects this) for its Express health
endpoint. The self-ping loop (every 10 min) uses RENDER_EXTERNAL_URL which
Render injects automatically when the service type is Web Service. We do
NOT need to set RENDER_EXTERNAL_URL ourselves.

Usage:
  $env:RENDER_API_KEY = '...'
  Set-Location 'C:\Users\Deign\Slobos-AFK-Aternos-Bot'
  .\render-deploy.ps1
#>

$ErrorActionPreference = "Stop"

# -------- CONFIG --------
$REPO_URL        = "https://github.com/Deign86/Slobos-AFK-Aternos-Bot"
$BRANCH          = "main"
$SERVICE_NAME    = "slobos-afk-aternos-bot"
$PLAN            = "free"
$REGION          = "oregon"
$NODE_VERSION    = "22"
$RUNTIME         = "node"
$HEALTH_PATH     = "/ping"
$BUILD_COMMAND   = "npm install"
$START_COMMAND   = "node index.js"

# -------- PREDICATES --------
if (-not $env:RENDER_API_KEY) {
    Write-Host "ERROR: RENDER_API_KEY is missing in this PowerShell session." -ForegroundColor Red
    Write-Host "Set it with: `$env:RENDER_API_KEY = '...'"
    exit 1
}

$headers = @{
    "Authorization" = "Bearer $env:RENDER_API_KEY"
    "Accept"        = "application/json"
    "Content-Type"  = "application/json"
}
$API = "https://api.render.com/v1"

function Rdr-Get($path) {
    return Invoke-RestMethod -Uri "$API$path" -Headers $headers -Method Get
}

function Rdr-Post($path, $body) {
    return Invoke-RestMethod -Uri "$API$path" -Headers $headers -Method Post -Body ($body | ConvertTo-Json -Depth 20) -ContentType "application/json"
}

function Rdr-Put($path, $body) {
    return Invoke-RestMethod -Uri "$API$path" -Headers $headers -Method Put -Body ($body | ConvertTo-Json -Depth 20) -ContentType "application/json"
}

function Rdr-Patch($path, $body) {
    return Invoke-RestMethod -Uri "$API$path" -Headers $headers -Method Patch -Body ($body | ConvertTo-Json -Depth 20) -ContentType "application/json"
}

# -------- 1. OWNER --------
Write-Host "[1/6] Resolving owner via GET /v1/owners ..." -ForegroundColor Cyan
$ownerResp = Rdr-Get "/owners"
$ownerId   = $ownerResp.owner.id
$ownerName = $ownerResp.owner.name
Write-Host "       ownerId=$ownerId  name=$ownerName"

# -------- 2. FIND EXISTING SERVICE --------
Write-Host "[2/6] Looking for existing service named '$SERVICE_NAME' ..." -ForegroundColor Cyan
$existing = $null
try {
    $list = Rdr-Get "/services?ownerId=$ownerId&limit=100"
    $existing = $list | Where-Object { $_.service.name -eq $SERVICE_NAME } | Select-Object -First 1
} catch {
    Write-Host "       (no existing services yet or list call failed: $($_.Exception.Message))" -ForegroundColor Yellow
}

# -------- 3. CREATE OR UPDATE SERVICE --------
if ($existing) {
    Write-Host "[3/6] Found existing service id=$($existing.service.id) - skipping create, will trigger fresh deploy." -ForegroundColor Cyan
    $serviceId = $existing.service.id
    $serviceUrl = $existing.service.serviceDetails.url
} else {
    Write-Host "[3/6] Creating new Web Service ..." -ForegroundColor Cyan
    $body = @{
        type   = "web_service"
        name   = $SERVICE_NAME
        ownerId = $ownerId
        repo   = $REPO_URL
        branch = $BRANCH
        autoDeploy = "yes"
        serviceDetails = @{
            runtime         = $RUNTIME
            plan            = $PLAN
            region          = $REGION
            healthCheckPath = $HEALTH_PATH
            envSpecificDetails = @{
                buildCommand = $BUILD_COMMAND
                startCommand = $START_COMMAND
                nodeVersion  = $NODE_VERSION
            }
        }
        envVars = @(
            @{ key = "NODE_ENV"; value = "production" }
        )
    }
    $created = Rdr-Post "/services" $body
    $serviceId  = $created.id
    $serviceUrl = $created.serviceDetails.url
}

Write-Host "       serviceId=$serviceId  url=$serviceUrl"

# -------- 4. SET ENV VARS (idempotent) --------
Write-Host "[4/6] Syncing env vars (NODE_ENV=production) ..." -ForegroundColor Cyan
$envBody = @(
    @{ key = "NODE_ENV"; value = "production" }
)
try {
    $null = Rdr-Put "/services/$serviceId/env-vars/bulk" $envBody
} catch {
    Write-Host "       env-vars sync failed (continuing): $($_.Exception.Message)" -ForegroundColor Yellow
}

# -------- 5. TRIGGER DEPLOY --------
Write-Host "[5/6] Triggering deploy ..." -ForegroundColor Cyan
$deployBody = @{ }  # empty body - latest commit on branch
$deploy = Rdr-Post "/services/$serviceId/deploys" $deployBody
$deployId = $deploy.id
Write-Host "       deployId=$deployId"

# -------- 6. POLL STATUS --------
Write-Host "[6/6] Polling deploy status (every 20s, max 60 attempts) ..." -ForegroundColor Cyan
$final = $null
for ($i = 1; $i -le 60; $i++) {
    Start-Sleep -Seconds 20
    try {
        $events = Rdr-Get "/services/$serviceId/events?limit=20"
        $deployEnd = $events | Where-Object { $_.type -eq "deploy_ended" -and $_.details.deployId -eq $deployId } | Select-Object -First 1
        if ($deployEnd) {
            $final = $deployEnd.details
            break
        }
        $current = $events | Where-Object { $_.type -in @("deploy_started","build_in_progress","update_in_progress") } | Select-Object -First 1
        if ($current) {
            Write-Host "       attempt $i : $($current.type)  status=$($current.details.status)"
        } else {
            Write-Host "       attempt $i : waiting ..."
        }
    } catch {
        Write-Host "       attempt $i : poll error: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

if (-not $final) {
    Write-Host "TIMEOUT waiting for deploy to reach terminal state." -ForegroundColor Yellow
    $final = @{ status = "timeout" }
}

# -------- METADATA --------
$meta = @{
    serviceId     = $serviceId
    serviceUrl    = $serviceUrl
    ownerId       = $ownerId
    ownerName     = $ownerName
    repo          = $REPO_URL
    branch        = $BRANCH
    deployId      = $deployId
    finalStatus   = $final.status
    finalizedAt   = (Get-Date).ToString("o")
    runtime       = $RUNTIME
    plan          = $PLAN
    region        = $REGION
    nodeVersion   = $NODE_VERSION
    buildCommand  = $BUILD_COMMAND
    startCommand  = $START_COMMAND
    healthPath    = $HEALTH_PATH
}
$meta | ConvertTo-Json -Depth 5 | Out-File -FilePath "render-deploy-metadata.json" -Encoding UTF8

Write-Host ""
Write-Host "==========================================" -ForegroundColor Green
Write-Host "  Render service URL : $serviceUrl"
Write-Host "  Service ID         : $serviceId"
Write-Host "  Deploy ID          : $deployId"
Write-Host "  Final status       : $($final.status)"
Write-Host "  Metadata           : render-deploy-metadata.json"
Write-Host "==========================================" -ForegroundColor Green