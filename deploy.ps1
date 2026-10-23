# ==============================================================================
# Website Monitor V2 - Automated Universal GCP Deployment Script (PowerShell)
# ==============================================================================
# Deploys Website Monitor to any Google Cloud Platform (GCP) account/project.
#
# Usage:
#   .\deploy.ps1
#   .\deploy.ps1 -ProjectId "your-project-id" -Region "asia-south2"
# ==============================================================================

param (
    [string]$ProjectId = $env:GOOGLE_CLOUD_PROJECT,
    [string]$Region = "asia-south2",
    [string]$FirestoreDatabaseId = "website-monitor-v2",
    [string]$GmailSender = $env:GMAIL_SENDER,
    [string]$GmailSenderName = "Website Operations Monitor",
    [string]$AlertRecipients = $env:ALERT_RECIPIENTS,
    [string]$GmailOAuthClientId = $env:GMAIL_OAUTH_CLIENT_ID,
    [string]$GmailOAuthClientSecret = $env:GMAIL_OAUTH_CLIENT_SECRET,
    [string]$GmailOAuthRefreshToken = $env:GMAIL_OAUTH_REFRESH_TOKEN,
    [string]$HeartbeatUrl = $env:HEARTBEAT_URL,
    [int]$SslExpiryThresholdDays = 14
)

$ErrorActionPreference = "Stop"

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "   Website Monitor V2 - Universal GCP Deployment Script     " -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

# Check gcloud CLI
if (-not (Get-Command gcloud -ErrorAction SilentlyContinue)) {
    Write-Host "[ERROR] gcloud CLI is not installed. Please install Google Cloud SDK first:" -ForegroundColor Red
    Write-Host "https://cloud.google.com/sdk/docs/install"
    exit 1
}

# Load .env file if it exists
if (Test-Path ".env") {
    Write-Host "[INFO] Loading configuration from local .env file..." -ForegroundColor Green
    Get-Content ".env" | ForEach-Object {
        $line = $_.Trim()
        if ($line -and -not $line.StartsWith("#") -and $line.Contains("=")) {
            $parts = $line.Split("=", 2)
            $name = $parts[0].Trim()
            $val = $parts[1].Trim()
            [System.Environment]::SetEnvironmentVariable($name, $val, "Process")
        }
    }
    if (-not $ProjectId) { $ProjectId = $env:GOOGLE_CLOUD_PROJECT }
    if (-not $GmailSender) { $GmailSender = $env:GMAIL_SENDER }
    if (-not $AlertRecipients) { $AlertRecipients = $env:ALERT_RECIPIENTS }
    if (-not $GmailOAuthClientSecret) { $GmailOAuthClientSecret = $env:GMAIL_OAUTH_CLIENT_SECRET }
    if (-not $GmailOAuthRefreshToken) { $GmailOAuthRefreshToken = $env:GMAIL_OAUTH_REFRESH_TOKEN }
}

# Prompt for missing required values
if (-not $ProjectId) {
    $currentProject = gcloud config get-value project 2>$null
    $ProjectId = Read-Host "Enter your Google Cloud Project ID [$currentProject]"
    if (-not $ProjectId) { $ProjectId = $currentProject }
}

if (-not $ProjectId) {
    Write-Host "[ERROR] Project ID is required to deploy." -ForegroundColor Red
    exit 1
}

if (-not $GmailSender) {
    $GmailSender = Read-Host "Enter Gmail Sender Email (e.g., monitor@gmail.com)"
}

if (-not $AlertRecipients) {
    $AlertRecipients = Read-Host "Enter Alert Recipient Emails (comma-separated)"
}

if (-not $GmailOAuthClientSecret) {
    $GmailOAuthClientSecret = Read-Host "Enter Gmail OAuth Client Secret"
}

if (-not $GmailOAuthRefreshToken) {
    $GmailOAuthRefreshToken = Read-Host "Enter Gmail OAuth Refresh Token"
}

if (-not $GmailOAuthClientId) {
    $GmailOAuthClientId = "1096824898465-749me4f7fiopdmnellggjv2d4jc8sdd9.apps.googleusercontent.com"
}

$ServiceName = "website-monitor-v2"
$SaEmail = "$ServiceName@$ProjectId.iam.gserviceaccount.com"

Write-Host "`nDeployment Configuration:" -ForegroundColor Yellow
Write-Host "Project ID:           $ProjectId"
Write-Host "Region:               $Region"
Write-Host "Service Name:         $ServiceName"
Write-Host "Firestore Database:   $FirestoreDatabaseId"
Write-Host "Gmail Sender:         $GmailSender"
Write-Host "Alert Recipients:     $AlertRecipients`n"

# 1. Set Active GCP Project
Write-Host "[1/7] Setting active GCP project to $ProjectId..." -ForegroundColor Yellow
gcloud config set project $ProjectId --quiet

# 2. Enable Required APIs
Write-Host "`n[2/7] Enabling required Google Cloud APIs..." -ForegroundColor Yellow
gcloud services enable `
    run.googleapis.com `
    cloudbuild.googleapis.com `
    artifactregistry.googleapis.com `
    firestore.googleapis.com `
    cloudscheduler.googleapis.com `
    secretmanager.googleapis.com `
    gmail.googleapis.com `
    --project=$ProjectId

# 3. Create Firestore Database if needed
Write-Host "`n[3/7] Verifying Firestore database ($FirestoreDatabaseId)..." -ForegroundColor Yellow
if ($FirestoreDatabaseId -eq "(default)") {
    try { gcloud firestore databases create --location=$Region --project=$ProjectId 2>$null } catch {}
} else {
    try { gcloud firestore databases create --database=$FirestoreDatabaseId --location=$Region --project=$ProjectId 2>$null } catch {}
}

# 4. Create Service Account and IAM Permissions
Write-Host "`n[4/7] Configuring IAM Service Account..." -ForegroundColor Yellow
try {
    gcloud iam service-accounts create $ServiceName `
        --display-name="Website Monitor Cloud Run Account" `
        --project=$ProjectId 2>$null
} catch {}

gcloud projects add-iam-policy-binding $ProjectId `
    --member="serviceAccount:$SaEmail" `
    --role="roles/datastore.user" `
    --condition=None `
    --quiet >$null

# Ensure Cloud Build has Artifact Registry permissions
$ProjectNumber = gcloud projects describe $ProjectId --format='value(projectNumber)'
try {
    gcloud projects add-iam-policy-binding $ProjectId `
        --member="serviceAccount:$ProjectNumber-compute@developer.gserviceaccount.com" `
        --role="roles/artifactregistry.writer" `
        --condition=None `
        --quiet >$null
} catch {}
try {
    gcloud projects add-iam-policy-binding $ProjectId `
        --member="serviceAccount:$ProjectNumber@cloudbuild.gserviceaccount.com" `
        --role="roles/artifactregistry.writer" `
        --condition=None `
        --quiet >$null
} catch {}

# 5. Deploy Cloud Run Service
Write-Host "`n[5/7] Deploying application to Cloud Run..." -ForegroundColor Yellow

@"
FIRESTORE_DATABASE_ID: "$FirestoreDatabaseId"
GMAIL_SENDER: "$GmailSender"
GMAIL_SENDER_NAME: "$GmailSenderName"
ALERT_RECIPIENTS: "$AlertRecipients"
GMAIL_OAUTH_CLIENT_ID: "$GmailOAuthClientId"
GMAIL_OAUTH_CLIENT_SECRET: "$GmailOAuthClientSecret"
GMAIL_OAUTH_REFRESH_TOKEN: "$GmailOAuthRefreshToken"
HEARTBEAT_URL: "$HeartbeatUrl"
SSL_EXPIRY_THRESHOLD_DAYS: "$SslExpiryThresholdDays"
"@ | Set-Content -Path ".env.yaml" -Encoding UTF8

gcloud run deploy $ServiceName `
    --source . `
    --region $Region `
    --platform managed `
    --service-account $SaEmail `
    --allow-unauthenticated `
    --env-vars-file .env.yaml `
    --project $ProjectId `
    --quiet

Remove-Item -Path ".env.yaml" -Force -ErrorAction SilentlyContinue

# Retrieve Service URL
$ServiceUrl = gcloud run services describe $ServiceName --region $Region --project $ProjectId --format='value(status.url)'

# Update DASHBOARD_URL
Write-Host "`n[6/7] Updating DASHBOARD_URL environment variable with $ServiceUrl..." -ForegroundColor Yellow
gcloud run services update $ServiceName `
    --region $Region `
    --update-env-vars "DASHBOARD_URL=$ServiceUrl/" `
    --project $ProjectId `
    --quiet

# 6. Create or Update Cloud Scheduler Job
Write-Host "`n[7/7] Configuring automated 5-minute Cloud Scheduler trigger..." -ForegroundColor Yellow
$SchedulerJob = "$ServiceName-cron"

$jobExists = gcloud scheduler jobs describe $SchedulerJob --location=$Region --project=$ProjectId 2>$null
if ($jobExists) {
    gcloud scheduler jobs update http $SchedulerJob `
        --uri="$ServiceUrl/" `
        --schedule="*/5 * * * *" `
        --http-method=GET `
        --location=$Region `
        --project=$ProjectId `
        --quiet
} else {
    gcloud scheduler jobs create http $SchedulerJob `
        --schedule="*/5 * * * *" `
        --uri="$ServiceUrl/" `
        --http-method=GET `
        --location=$Region `
        --project=$ProjectId `
        --description="Automated 5-minute website health check trigger" `
        --quiet
}

Write-Host "`n============================================================" -ForegroundColor Green
Write-Host "   Deployment Successfully Completed!                       " -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host "Cloud Run Service URL:    $ServiceUrl/" -ForegroundColor Cyan
Write-Host "Health Check Endpoint:    $ServiceUrl/healthz" -ForegroundColor Cyan
Write-Host "Status API Endpoint:      $ServiceUrl/api/status" -ForegroundColor Cyan
Write-Host "Cloud Scheduler:          Every 5 Minutes (*/5 * * * *)"
Write-Host "`nYou can open $ServiceUrl/ in your browser to view the Live Operations Dashboard.`n"
