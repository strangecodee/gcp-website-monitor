#!/usr/bin/env bash
# ==============================================================================
# Website Monitor V2 - Automated Universal GCP Deployment Script
# ==============================================================================
# Deploys Website Monitor to any Google Cloud Platform (GCP) account/project.
#
# Usage:
#   ./deploy.sh
#   Or with parameters:
#   PROJECT_ID="your-project-id" REGION="asia-south2" ./deploy.sh
# ==============================================================================

set -euo pipefail

# Text formatting
BOLD="\033[1m"
GREEN="\033[0;32m"
BLUE="\033[0;34m"
YELLOW="\033[1;33m"
RED="\033[0;31m"
RESET="\033[0m"

echo -e "${BOLD}${BLUE}============================================================${RESET}"
echo -e "${BOLD}${BLUE}   Website Monitor V2 - Universal GCP Deployment Script    ${RESET}"
echo -e "${BOLD}${BLUE}============================================================${RESET}\n"

# 1. Check prerequisites
if ! command -v gcloud &> /dev/null; then
  echo -e "${RED}[ERROR] gcloud CLI is not installed. Please install Google Cloud SDK first:${RESET}"
  echo "https://cloud.google.com/sdk/docs/install"
  exit 1
fi

# Load .env file if present
if [[ -f ".env" ]]; then
  echo -e "${GREEN}[INFO] Loading configuration from local .env file...${RESET}"
  set -a
  source .env
  set +a
fi

# Determine GCP Project ID
PROJECT_ID="${PROJECT_ID:-${GOOGLE_CLOUD_PROJECT:-}}"
if [[ -z "${PROJECT_ID}" ]]; then
  CURRENT_PROJECT=$(gcloud config get-value project 2>/dev/null || true)
  read -rp "Enter your Google Cloud Project ID [${CURRENT_PROJECT}]: " INPUT_PROJECT
  PROJECT_ID="${INPUT_PROJECT:-${CURRENT_PROJECT}}"
fi

if [[ -z "${PROJECT_ID}" ]]; then
  echo -e "${RED}[ERROR] Project ID is required to deploy.${RESET}"
  exit 1
fi

# Region
REGION="${GCP_REGION:-${REGION:-asia-south2}}"

# Service Name
SERVICE_NAME="website-monitor-v2"

# Firestore database ID (defaults to 'website-monitor-v2' or '(default)')
FIRESTORE_DATABASE_ID="${FIRESTORE_DATABASE_ID:-website-monitor-v2}"

# Gmail & Alerting credentials
GMAIL_SENDER="${GMAIL_SENDER:-}"
GMAIL_SENDER_NAME="${GMAIL_SENDER_NAME:-Website Operations Monitor}"
ALERT_RECIPIENTS="${ALERT_RECIPIENTS:-}"
GMAIL_OAUTH_CLIENT_ID="${GMAIL_OAUTH_CLIENT_ID:-1096824898465-749me4f7fiopdmnellggjv2d4jc8sdd9.apps.googleusercontent.com}"
GMAIL_OAUTH_CLIENT_SECRET="${GMAIL_OAUTH_CLIENT_SECRET:-}"
GMAIL_OAUTH_REFRESH_TOKEN="${GMAIL_OAUTH_REFRESH_TOKEN:-}"
HEARTBEAT_URL="${HEARTBEAT_URL:-}"
SSL_EXPIRY_THRESHOLD_DAYS="${SSL_EXPIRY_THRESHOLD_DAYS:-14}"

if [[ -z "${GMAIL_SENDER}" ]]; then
  read -rp "Enter Gmail Sender Email (e.g., monitor@gmail.com): " GMAIL_SENDER
fi

if [[ -z "${ALERT_RECIPIENTS}" ]]; then
  read -rp "Enter Alert Recipient Emails (comma-separated): " ALERT_RECIPIENTS
fi

if [[ -z "${GMAIL_OAUTH_CLIENT_SECRET}" ]]; then
  read -rp "Enter Gmail OAuth Client Secret: " GMAIL_OAUTH_CLIENT_SECRET
fi

if [[ -z "${GMAIL_OAUTH_REFRESH_TOKEN}" ]]; then
  read -rp "Enter Gmail OAuth Refresh Token: " GMAIL_OAUTH_REFRESH_TOKEN
fi

echo -e "\n${BOLD}Deployment Configuration:${RESET}"
echo -e "Project ID:           ${BLUE}${PROJECT_ID}${RESET}"
echo -e "Region:               ${BLUE}${REGION}${RESET}"
echo -e "Service Name:         ${BLUE}${SERVICE_NAME}${RESET}"
echo -e "Firestore Database:   ${BLUE}${FIRESTORE_DATABASE_ID}${RESET}"
echo -e "Gmail Sender:         ${BLUE}${GMAIL_SENDER}${RESET}"
echo -e "Alert Recipients:     ${BLUE}${ALERT_RECIPIENTS}${RESET}\n"

# 2. Set Active GCP Project
echo -e "${YELLOW}[1/7] Setting active GCP project to ${PROJECT_ID}...${RESET}"
gcloud config set project "${PROJECT_ID}" --quiet

# 3. Enable Required Google Cloud APIs
echo -e "\n${YELLOW}[2/7] Enabling required Google Cloud APIs...${RESET}"
gcloud services enable \
  run.googleapis.com \
  cloudbuild.googleapis.com \
  artifactregistry.googleapis.com \
  firestore.googleapis.com \
  cloudscheduler.googleapis.com \
  secretmanager.googleapis.com \
  gmail.googleapis.com \
  --project="${PROJECT_ID}"

# 4. Check / Provision Firestore Database
echo -e "\n${YELLOW}[3/7] Verifying Firestore database (${FIRESTORE_DATABASE_ID})...${RESET}"
if [[ "${FIRESTORE_DATABASE_ID}" == "(default)" ]]; then
  gcloud firestore databases create --location="${REGION}" --project="${PROJECT_ID}" --type=firestore-native 2>/dev/null || true
else
  gcloud firestore databases create --database="${FIRESTORE_DATABASE_ID}" --location="${REGION}" --project="${PROJECT_ID}" --type=firestore-native 2>/dev/null || true
fi

# 5. Create Service Account and assign IAM permissions
echo -e "\n${YELLOW}[4/7] Configuring IAM Service Account...${RESET}"
SA_NAME="${SERVICE_NAME}"
SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

# Create Service Account if it does not exist
gcloud iam service-accounts create "${SA_NAME}" \
  --display-name="Website Monitor Cloud Run Account" \
  --project="${PROJECT_ID}" 2>/dev/null || true

# Assign Datastore User role for Firestore
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="roles/datastore.user" \
  --condition=None \
  --quiet > /dev/null

# Ensure Cloud Build has Artifact Registry permissions
PROJECT_NUMBER=$(gcloud projects describe "${PROJECT_ID}" --format='value(projectNumber)')
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${PROJECT_NUMBER}-compute@developer.gserviceaccount.com" \
  --role="roles/artifactregistry.writer" \
  --condition=None \
  --quiet > /dev/null 2>&1 || true
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${PROJECT_NUMBER}@cloudbuild.gserviceaccount.com" \
  --role="roles/artifactregistry.writer" \
  --condition=None \
  --quiet > /dev/null 2>&1 || true

# 6. Deploy to Google Cloud Run
echo -e "\n${YELLOW}[5/7] Deploying application to Cloud Run...${RESET}"

# Generate YAML env vars file to handle comma-separated recipients and special characters cleanly
cat <<EOF > .env.yaml
FIRESTORE_DATABASE_ID: "${FIRESTORE_DATABASE_ID}"
GMAIL_SENDER: "${GMAIL_SENDER}"
GMAIL_SENDER_NAME: "${GMAIL_SENDER_NAME}"
ALERT_RECIPIENTS: "${ALERT_RECIPIENTS}"
GMAIL_OAUTH_CLIENT_ID: "${GMAIL_OAUTH_CLIENT_ID}"
GMAIL_OAUTH_CLIENT_SECRET: "${GMAIL_OAUTH_CLIENT_SECRET}"
GMAIL_OAUTH_REFRESH_TOKEN: "${GMAIL_OAUTH_REFRESH_TOKEN}"
HEARTBEAT_URL: "${HEARTBEAT_URL}"
SSL_EXPIRY_THRESHOLD_DAYS: "${SSL_EXPIRY_THRESHOLD_DAYS}"
EOF

gcloud run deploy "${SERVICE_NAME}" \
  --source . \
  --region "${REGION}" \
  --platform managed \
  --service-account "${SA_EMAIL}" \
  --allow-unauthenticated \
  --env-vars-file .env.yaml \
  --project "${PROJECT_ID}" \
  --quiet

rm -f .env.yaml

# Retrieve the deployed Service URL
SERVICE_URL=$(gcloud run services describe "${SERVICE_NAME}" --region "${REGION}" --project "${PROJECT_ID}" --format='value(status.url)')

# Update DASHBOARD_URL environment variable to match the deployed Cloud Run URL
echo -e "\n${YELLOW}[6/7] Updating DASHBOARD_URL environment variable with ${SERVICE_URL}...${RESET}"
gcloud run services update "${SERVICE_NAME}" \
  --region "${REGION}" \
  --update-env-vars "DASHBOARD_URL=${SERVICE_URL}/" \
  --project "${PROJECT_ID}" \
  --quiet

# 7. Create or update Cloud Scheduler 5-Minute automated cron trigger
echo -e "\n${YELLOW}[7/7] Configuring automated 5-minute Cloud Scheduler trigger...${RESET}"
SCHEDULER_JOB="${SERVICE_NAME}-cron"
if gcloud scheduler jobs describe "${SCHEDULER_JOB}" --location="${REGION}" --project="${PROJECT_ID}" &>/dev/null; then
  gcloud scheduler jobs update http "${SCHEDULER_JOB}" \
    --uri="${SERVICE_URL}/" \
    --schedule="*/5 * * * *" \
    --http-method=GET \
    --location="${REGION}" \
    --project="${PROJECT_ID}" \
    --quiet
else
  gcloud scheduler jobs create http "${SCHEDULER_JOB}" \
    --schedule="*/5 * * * *" \
    --uri="${SERVICE_URL}/" \
    --http-method=GET \
    --location="${REGION}" \
    --project="${PROJECT_ID}" \
    --description="Automated 5-minute website health check trigger" \
    --quiet
fi

# Completion Summary
echo -e "\n${BOLD}${GREEN}============================================================${RESET}"
echo -e "${BOLD}${GREEN}   Deployment Successfully Completed!                      ${RESET}"
echo -e "${BOLD}${GREEN}============================================================${RESET}"
echo -e "Cloud Run Service URL:    ${BOLD}${BLUE}${SERVICE_URL}/${RESET}"
echo -e "Health Check Endpoint:    ${BOLD}${BLUE}${SERVICE_URL}/healthz${RESET}"
echo -e "Status API Endpoint:      ${BOLD}${BLUE}${SERVICE_URL}/api/status${RESET}"
echo -e "Cloud Scheduler:          ${BOLD}Every 5 Minutes (*/5 * * * *)${RESET}"
echo -e "\nYou can open ${BOLD}${BLUE}${SERVICE_URL}/${RESET} in your browser to view the Live Operations Dashboard."
