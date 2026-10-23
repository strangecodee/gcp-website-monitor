# Enterprise Website Monitor V2 - Installation and Setup Guide

This guide provides a comprehensive, step-by-step walkthrough for setting up, configuring, and deploying the Website Monitoring platform on Google Cloud Platform (GCP) from scratch.

---

## 1. System Requirements and Prerequisites

Before starting, ensure you have the following installed on your local workstation:

1.  **Node.js**: Version 20.x or 22.x LTS ([Download Node.js](https://nodejs.org/)).
2.  **Google Cloud SDK (`gcloud` CLI)**: ([Install gcloud CLI](https://cloud.google.com/sdk/docs/install)).
3.  **Git**: ([Install Git](https://git-scm.com/)).
4.  **Terminal Shell**:
    *   **Windows**: PowerShell 5.1+ or Windows Subsystem for Linux (WSL).
    *   **macOS / Linux**: Bash or Zsh.
5.  **Google Cloud Platform Account**: An active GCP account with billing enabled (usage remains within the monthly Free Tier).
6.  **Gmail Account**: An active Gmail or Google Workspace account to dispatch incident alerts.

---

## 2. Phase 1: Google Cloud Project Setup

### Step 1.1: Authenticate with Google Cloud
Open your terminal and authenticate your local `gcloud` CLI:
```bash
gcloud auth login
```

### Step 1.2: Create or Select Your Project
You can use an existing project or create a dedicated new project:
```bash
# Create a new project (replace with your globally unique project ID)
gcloud projects create my-website-monitor-prod --name="Website Monitor Production"

# Set the active project in gcloud
gcloud config set project my-website-monitor-prod
```

### Step 1.3: Link Billing to Your Project
Ensure your billing account is attached (Cloud Run requires an active billing profile, even within the free tier):
```bash
# List your billing accounts
gcloud billing accounts list

# Link billing account to your project
gcloud billing projects link my-website-monitor-prod --billing-account=YOUR_BILLING_ACCOUNT_ID
```

### Step 1.4: Enable Required Google Cloud APIs
Run the following command to enable all required APIs:
```bash
gcloud services enable \
  run.googleapis.com \
  firestore.googleapis.com \
  cloudscheduler.googleapis.com \
  gmail.googleapis.com \
  cloudbuild.googleapis.com \
  artifactregistry.googleapis.com \
  monitoring.googleapis.com \
  logging.googleapis.com
```

---

## 3. Phase 2: Gmail OAuth 2.0 Setup (Alert Dispatcher)

Google Cloud requires OAuth 2.0 authentication to send emails securely via the Gmail REST API on behalf of personal `@gmail.com` or Google Workspace accounts.

### Step 2.1: Configure the OAuth Consent Screen
1.  Open the [Google Cloud Console](https://console.cloud.google.com/).
2.  Navigate to **APIs & Services** > **OAuth consent screen**.
3.  Choose User Type:
    *   **External**: For standard `@gmail.com` accounts.
    *   **Internal**: For Google Workspace organizations.
4.  Click **Create**.
5.  Fill in the required fields:
    *   **App Name**: `Website Monitor Alerting Service`
    *   **User support email**: Select your email address.
    *   **Developer contact email**: Enter your email address.
6.  Click **Save and Continue**.
7.  **Scopes**: Click **Add or Remove Scopes**, select:
    *   `https://www.googleapis.com/auth/gmail.send` (Send messages on your behalf)
8.  Click **Save and Continue**.
9.  **Test Users (Crucial for External mode)**:
    *   Click **+ Add Users**.
    *   Add your sender email address (the account sending alerts).
    *   Click **Save and Continue**.

### Step 2.2: Create OAuth 2.0 Web Client Credentials
1.  Navigate to **APIs & Services** > **Credentials**.
2.  Click **+ Create Credentials** > **OAuth client ID**.
3.  Select Application Type: **Web application**.
4.  **Name**: `Website Monitor Web Client`.
5.  **Authorized redirect URIs**: Add the following URIs:
    *   `http://localhost:8080/login/oauth2/code/google`
    *   `http://localhost:3000`
6.  Click **Create**.
7.  A dialog will appear containing your **Client ID** and **Client Secret**. Save both securely.

### Step 2.3: Generate Your OAuth Refresh Token
To generate your permanent `GMAIL_OAUTH_REFRESH_TOKEN`, execute the bundled helper script locally:

1.  Edit `get_refresh_token.js` in the project root:
    ```javascript
    const CLIENT_ID = "YOUR_CLIENT_ID_HERE";
    const CLIENT_SECRET = "YOUR_CLIENT_SECRET_HERE";
    const REDIRECT_URI = "http://localhost:8080/login/oauth2/code/google";
    ```
2.  Run the token acquisition script in your terminal:
    ```bash
    node get_refresh_token.js
    ```
3.  The script will start a temporary local web server on port 8080 and print an authorization URL.
4.  Open the URL in your web browser, select your Gmail account, and click **Continue / Allow**.
5.  Upon consent, the script captures the OAuth code and displays your **Refresh Token** in the console:
    ```text
    ============================================================
    Refresh Token successfully generated:
    1//0g7PCQRNsQXSCCgYIARAAGBASNwF-L9IrfLLNboW...
    ============================================================
    ```
6.  Copy and store this token. It does not expire unless explicitly revoked in your Google Account security settings.

---

## 4. Phase 3: Cloud Firestore Database Setup

Firestore acts as the persistent atomic state machine, tracking incident start times, downtime durations, and Gmail thread IDs.

1.  In Google Cloud Console, navigate to **Firestore**.
2.  Click **Create Database**.
3.  Select **Firestore Native Mode** (Do not choose Datastore Mode).
4.  **Database ID**: Enter `website-monitor-v2` (or use `(default)`).
5.  **Location**: Choose a region close to your primary users (e.g. `asia-south2` for India, `us-central1` for US, `europe-west1` for Europe).
6.  Click **Create Database**.

---

## 5. Phase 4: Local Configuration File (`.env`)

In the root of your project directory, create your configuration file from the template:

```bash
# On Linux / macOS / WSL
cp .env.example .env

# On Windows PowerShell
Copy-Item .env.example .env
```

Edit `.env` with your preferred text editor and configure the fields:

```dotenv
# ============================================================
# Google Cloud Platform Configuration
# ============================================================
GOOGLE_CLOUD_PROJECT=my-website-monitor-prod
GCP_REGION=asia-south2
FIRESTORE_DATABASE_ID=website-monitor-v2
COLLECTION_NAME=website_monitoring

# ============================================================
# Alerting Configuration
# ============================================================
GMAIL_SENDER=monitor@gmail.com
GMAIL_SENDER_NAME="Website Operations Monitor"
ALERT_RECIPIENTS=devops@company.com,teamlead@company.com

# ============================================================
# Gmail OAuth 2.0 Credentials
# ============================================================
GMAIL_OAUTH_CLIENT_ID=123456789-abcdef.apps.googleusercontent.com
GMAIL_OAUTH_CLIENT_SECRET=GOCSPX-yourClientSecretHere
GMAIL_OAUTH_REFRESH_TOKEN=1//0g7PCQRNsQ...yourRefreshTokenHere
GMAIL_OAUTH_REDIRECT_URI=http://localhost:8080/login/oauth2/code/google

# ============================================================
# Operational Enhancements (Optional)
# ============================================================
SSL_EXPIRY_THRESHOLD_DAYS=14
HEARTBEAT_URL=
DASHBOARD_URL=
```

---

## 6. Phase 5: Executing the Universal Deployment Script

The deployment script automates IAM permissions, artifact container builds, Cloud Run deployment, and Cloud Scheduler configuration.

### For Linux / macOS / WSL Users:
```bash
chmod +x deploy.sh
./deploy.sh
```

### For Windows PowerShell Users:
```powershell
.\deploy.ps1
```

### What the script executes step-by-step:
1.  **Reads configuration** from `.env`.
2.  **Sets active GCP Project** and verifies API enablement.
3.  **Provisions IAM Service Account**:
    *   Creates `website-monitor-v2@<PROJECT_ID>.iam.gserviceaccount.com`.
    *   Binds the `roles/datastore.user` role for Firestore access.
    *   Binds `roles/artifactregistry.writer` for Cloud Build image generation.
4.  **Deploys to Cloud Run**:
    *   Uploads application source files.
    *   Builds container using Google Cloud Buildpacks (Node.js 22 runtime).
    *   Deploys revision with managed autoscaling.
5.  **Sets Environment Variables**:
    *   Populates database credentials, OAuth tokens, and alerting parameters.
    *   Updates `DASHBOARD_URL` with the generated Cloud Run URL.
6.  **Configures Cloud Scheduler**:
    *   Creates or updates cron job `website-monitor-v2-cron`.
    *   Sets execution cadence to every 5 minutes (`*/5 * * * *`).

---

## 7. Phase 6: Post-Deployment Verification & Testing

### Step 7.1: Verify Service Health Check
Verify system connectivity using `curl`:
```bash
curl -s "https://<YOUR_CLOUD_RUN_URL>/?health=true"
```
**Expected Response:**
```json
{
  "status": "OK",
  "service": "website-monitor-v2",
  "database": "CONNECTED",
  "domainsMonitored": 94,
  "uptimeSeconds": 45,
  "timestamp": "2026-10-23T09:30:00.000Z"
}
```

### Step 7.2: Verify the Live Operations Dashboard
1.  Copy your Cloud Run service URL (e.g., `https://website-monitor-v2-jlqsucho4a-em.a.run.app/`).
2.  Open it in any web browser.
3.  You should see the dark-mode dashboard displaying:
    *   Total Monitored Count, UP Count, DOWN Count, Error Count.
    *   Gmail connection status badge (**Gmail Active**).
    *   Search filter bar.
    *   Tabular list of endpoints with status badges, response latency, and SSL expiration badges.

### Step 7.3: Trigger a Manual Health Check Cycle
Trigger an immediate monitoring run without waiting for the 5-minute scheduler:
```bash
curl -s "https://<YOUR_CLOUD_RUN_URL>/" -H "User-Agent: Google-Cloud-Scheduler"
```
Check your terminal output for a JSON summary:
```json
{
  "success": true,
  "statistics": {
    "total": 94,
    "up": 66,
    "clientError": 1,
    "serverError": 8,
    "down": 19
  }
}
```

### Step 7.4: Verify Cloud Scheduler Status
Check that Cloud Scheduler is active and scheduled:
```bash
gcloud scheduler jobs list --location=asia-south2
```

---

## 8. Phase 7: Ongoing Maintenance & Administration

### Adding or Removing Monitored Websites
All monitored endpoints are maintained in [`index.js`](file:///c:/Users/Administrator/Desktop/GCP_Functions/index.js) in the `MONITORED_DOMAINS` array:
```javascript
const MONITORED_DOMAINS = [
  "https://compliance.jindalsteel.com/compliance/login.jspl",
  "https://hr.jspl.com/",
  "https://audit.jindalsteel.com/login.aspx",
  // Add new URLs here
];
```
After editing the array, re-deploy using:
```bash
./deploy.sh
```

### Updating Email Alert Recipients
To add or remove team members from incident alerts:
1.  Open `.env`.
2.  Update the `ALERT_RECIPIENTS` string:
    ```dotenv
    ALERT_RECIPIENTS=newperson@company.com,devops@company.com
    ```
3.  Re-run `./deploy.sh`. The new list takes effect immediately without downtime.

### Resetting Firestore Database Baseline
If you ever need to purge historical incident records, message IDs, or state flags to start from a clean baseline:
```bash
wsl bash -c "node -e 'const admin = require(\"firebase-admin\"); const { getFirestore } = require(\"firebase-admin/firestore\"); admin.initializeApp(); const db = getFirestore(admin.app(), \"website-monitor-v2\"); db.collection(\"website_monitoring\").get().then(s => Promise.all(s.docs.map(d => d.ref.delete()))).then(() => console.log(\"Firestore Cleaned Successfully\"));'"
```

---

## 9. Security Best Practices

1.  **Git Protection**: Never commit `.env`, `client_secret*.json`, or `token.json` to source control. Ensure they are listed in `.gitignore`.
2.  **Least Privilege IAM**: The Cloud Run runtime account only requires `roles/datastore.user` to access Firestore. Do not grant Owner or Editor roles.
3.  **Gmail Rate Limiting**: The built-in rate limiter enforces a 2000 ms interval between consecutive email dispatches with exponential backoff to ensure Gmail API quotas are strictly respected.
