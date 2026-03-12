#!/usr/bin/env bash
# =============================================================================
# deploy.sh — Automated GKE deployment for Gemini Live MOFSL Contact Center
# =============================================================================
#
# Run from the repository root:  ./deploy.sh
#
# Prerequisites (must be installed and authenticated):
#   - gcloud  (authenticated: gcloud auth login)
#             kubectl is installed automatically via gcloud components if missing
#
# This script will:
#   1. Enable required GCP APIs
#   2. Create the GKE cluster if it does not exist (Workload Identity enabled)
#   3. Create the GCP service account if it does not exist
#   4. Grant required IAM roles (condition=None)
#   5. Bind Workload Identity (condition=None)
#   6. Grant the Cloud Build SA permissions to deploy to GKE
#   7. Create the GCS transcript bucket if it does not exist
#   8. Update all configuration files with your values
#   9. Submit Cloud Build (builds image, pushes to GCR, deploys to GKE)
#  10. Reserve global static IP + configure Ingress domain
#  11. Submit Cloud Build (builds image, pushes to GCR, deploys to GKE)
#  12. Patch BACKEND_WS_URL with your domain; display DNS setup instructions
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ── Terminal formatting ────────────────────────────────────────────────────────
BOLD="\033[1m"
GREEN="\033[0;32m"
YELLOW="\033[0;33m"
RED="\033[0;31m"
CYAN="\033[0;36m"
RESET="\033[0m"

info()  { echo -e "  ${GREEN}✓${RESET}  $*"; }
warn()  { echo -e "  ${YELLOW}⚠${RESET}  $*"; }
error() { echo -e "\n${RED}✗ ERROR:${RESET} $*\n" >&2; exit 1; }
step()  { echo -e "\n${CYAN}${BOLD}▶ $*${RESET}"; }
hr()    { echo -e "${BOLD}──────────────────────────────────────────────────${RESET}"; }

# ── Prerequisite check ─────────────────────────────────────────────────────────
command -v gcloud &>/dev/null || error "'gcloud' not found. Install the Google Cloud SDK: https://cloud.google.com/sdk/docs/install"
command -v sed    &>/dev/null || error "'sed' not found."

gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null \
  | grep -q "." \
  || error "No active gcloud account. Run: gcloud auth login"

# kubectl — try multiple install paths then give up gracefully
if ! command -v kubectl &>/dev/null; then
  echo -e "  ${YELLOW}⚠${RESET}  kubectl not found — trying gcloud components..."
  if gcloud components install kubectl --quiet 2>/dev/null && command -v kubectl &>/dev/null; then
    info "kubectl installed via gcloud components"
  else
    echo -e "  ${YELLOW}⚠${RESET}  gcloud components unavailable — trying apt-get..."
    if command -v apt-get &>/dev/null \
        && sudo apt-get install -y kubectl > /dev/null 2>&1 \
        && command -v kubectl &>/dev/null; then
      info "kubectl installed via apt-get"
    else
      error "kubectl not found and could not be installed automatically.\n"\
            "  Install it manually, then re-run:\n"\
            "    apt/deb:  sudo apt-get install -y kubectl\n"\
            "    snap:     sudo snap install kubectl --classic\n"\
            "    brew:     brew install kubectl\n"\
            "    gcloud:   gcloud components install kubectl"
    fi
  fi
fi

# ── Banner ─────────────────────────────────────────────────────────────────────
echo ""
hr
echo -e "  ${BOLD}Gemini Live — MOFSL Contact Center  |  Deployment Setup${RESET}"
hr
echo ""
echo "  This script automates the full GKE deployment."
echo "  All prompts show their current default in [ ]."
echo "  Press Enter to accept the default."
echo ""

# ── Input prompts ──────────────────────────────────────────────────────────────
step "Configuration"

ask() {
  local var="$1" label="$2" default="$3"
  echo -en "  ${BOLD}${label}${RESET} [${default}]: "
  read -r _input
  printf -v "$var" '%s' "${_input:-$default}"
}

ask PROJECT_ID    "GCP Project ID"                   "general-ak"
ask CLUSTER       "GKE Cluster name"                 "gemini-live-cluster"
ask REGION        "GKE Region"                       "us-central1"
ask RAG_CORPUS_ID "Vertex AI RAG Corpus ID"          "6917529027641081856"
ask GCS_BUCKET    "GCS Bucket (transcripts)"         "mofsl-contact-center-recordings"
ask AGENT_MODEL      "Gemini Live model"                "gemini-live-2.5-flash-native-audio"
ask DOMAIN           "Domain name (e.g. gemini.your-company.com)"  ""
ask STATIC_IP_NAME   "GCP global static IP resource name"          "gemini-live-ip"

# ── Validate required inputs ──────────────────────────────────────────────────
[[ -z "${DOMAIN:-}" ]] && error "Domain name is required for GKE Ingress + TLS.\n  Point an A record at the static IP, then re-run."

# ── Derived constants ──────────────────────────────────────────────────────────
GCP_SA_NAME="gemini-live-backend"
GCP_SA_EMAIL="${GCP_SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
GKE_NAMESPACE="gemini-live"
K8S_SA_NAME="gemini-live-sa"
IMAGE="gcr.io/${PROJECT_ID}/geminilive-glive"

echo ""
hr
echo -e "  ${BOLD}Summary${RESET}"
hr
echo -e "  Project ID   :  ${PROJECT_ID}"
echo -e "  GKE Cluster  :  ${CLUSTER}  (${REGION})"
echo -e "  Container    :  ${IMAGE}"
echo -e "  RAG Corpus   :  ${RAG_CORPUS_ID}"
echo -e "  GCS Bucket   :  gs://${GCS_BUCKET}"
echo -e "  Agent Model  :  ${AGENT_MODEL}"
echo -e "  Domain       :  ${DOMAIN}"
echo -e "  Static IP    :  ${STATIC_IP_NAME}"
hr
echo ""
echo -en "  ${BOLD}Proceed with deployment? [Y/n]:${RESET} "
read -r _confirm
[[ "${_confirm:-Y}" =~ ^[Yy]$ ]] || { echo "  Aborted."; exit 0; }

# ── Set active project ─────────────────────────────────────────────────────────
step "Setting active GCP project"
gcloud config set project "$PROJECT_ID" --quiet
info "Active project: ${PROJECT_ID}"

# ── Enable APIs ────────────────────────────────────────────────────────────────
step "Enabling required GCP APIs"
gcloud services enable \
  container.googleapis.com \
  aiplatform.googleapis.com \
  storage.googleapis.com \
  cloudbuild.googleapis.com \
  containerregistry.googleapis.com \
  iam.googleapis.com \
  compute.googleapis.com \
  --project="$PROJECT_ID" --quiet
info "APIs enabled"

# ── GKE Cluster ─────────────────────────────────────────────────────────────────
step "GKE Cluster: ${CLUSTER}"

if gcloud container clusters describe "$CLUSTER" \
    --region="$REGION" --project="$PROJECT_ID" \
    --format="value(name)" &>/dev/null 2>&1; then

  info "Cluster already exists"

  # Ensure Workload Identity is enabled
  _WI=$(gcloud container clusters describe "$CLUSTER" \
    --region="$REGION" --project="$PROJECT_ID" \
    --format="value(workloadIdentityConfig.workloadPool)" 2>/dev/null || true)

  if [[ -z "${_WI:-}" ]]; then
    warn "Workload Identity not enabled — enabling now (takes ~5 min)..."
    gcloud container clusters update "$CLUSTER" \
      --region="$REGION" --project="$PROJECT_ID" \
      --workload-pool="${PROJECT_ID}.svc.id.goog" --quiet
    info "Workload Identity enabled"
  else
    info "Workload Identity already enabled"
  fi

else
  warn "Cluster not found — creating with Workload Identity (takes ~10 min)..."
  gcloud container clusters create "$CLUSTER" \
    --region="$REGION" \
    --project="$PROJECT_ID" \
    --num-nodes=1 \
    --machine-type=e2-standard-4 \
    --workload-pool="${PROJECT_ID}.svc.id.goog" \
    --quiet
  info "Cluster created: ${CLUSTER}"
fi

# ── GCP Service Account ────────────────────────────────────────────────────────
step "GCP Service Account: ${GCP_SA_EMAIL}"

if gcloud iam service-accounts describe "$GCP_SA_EMAIL" \
    --project="$PROJECT_ID" &>/dev/null 2>&1; then
  info "Service account already exists"
else
  gcloud iam service-accounts create "$GCP_SA_NAME" \
    --project="$PROJECT_ID" \
    --display-name="Gemini Live Backend" \
    --quiet
  info "Service account created"
fi

# ── IAM Role Bindings (--condition=None) ──────────────────────────────────────
step "Granting IAM roles to backend SA (condition=None)"

for ROLE in \
  "roles/aiplatform.user" \
  "roles/storage.objectAdmin"; do

  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:${GCP_SA_EMAIL}" \
    --role="$ROLE" \
    --condition=None \
    --quiet
  info "Granted ${ROLE}"
done

# ── Workload Identity Binding (--condition=None) ───────────────────────────────
step "Binding Workload Identity (condition=None)"

_WI_MEMBER="serviceAccount:${PROJECT_ID}.svc.id.goog[${GKE_NAMESPACE}/${K8S_SA_NAME}]"

gcloud iam service-accounts add-iam-policy-binding "$GCP_SA_EMAIL" \
  --role="roles/iam.workloadIdentityUser" \
  --member="$_WI_MEMBER" \
  --condition=None \
  --quiet

info "Bound: ${_WI_MEMBER}"

# ── Cloud Build SA Permissions (--condition=None) ─────────────────────────────
step "Granting Cloud Build SA access to GKE + GCR"

_PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" \
  --format="value(projectNumber)")
_CB_SA="${_PROJECT_NUMBER}@cloudbuild.gserviceaccount.com"

for ROLE in \
  "roles/container.developer" \
  "roles/storage.admin"; do

  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:${_CB_SA}" \
    --role="$ROLE" \
    --condition=None \
    --quiet
  info "Granted ${ROLE} to Cloud Build SA"
done

# ── GCS Bucket ─────────────────────────────────────────────────────────────────
step "GCS Bucket: gs://${GCS_BUCKET}"

if gcloud storage buckets describe "gs://${GCS_BUCKET}" \
    --project="$PROJECT_ID" &>/dev/null 2>&1; then
  info "Bucket already exists"
else
  gcloud storage buckets create "gs://${GCS_BUCKET}" \
    --project="$PROJECT_ID" \
    --location="$REGION"
  info "Bucket created"
fi

# ── Global static IP ──────────────────────────────────────────────────────────
step "Global static IP: ${STATIC_IP_NAME}"

if gcloud compute addresses describe "$STATIC_IP_NAME" \
    --global --project="$PROJECT_ID" &>/dev/null 2>&1; then
  info "Static IP already exists"
else
  gcloud compute addresses create "$STATIC_IP_NAME" \
    --global --project="$PROJECT_ID"
  info "Static IP reserved"
fi

_STATIC_IP=$(gcloud compute addresses describe "$STATIC_IP_NAME" \
  --global --project="$PROJECT_ID" --format="value(address)")
info "Static IP address: ${_STATIC_IP}"

# ── Update configuration files ─────────────────────────────────────────────────
step "Updating configuration files"

# backend/config.py — update default values
sed -i \
  -e "s|os.getenv(\"PROJECT_ID\",[ ]*\"[^\"]*\")|os.getenv(\"PROJECT_ID\", \"${PROJECT_ID}\")|g" \
  -e "s|os.getenv(\"LOCATION\",[ ]*\"[^\"]*\")|os.getenv(\"LOCATION\", \"${REGION}\")|g" \
  -e "s|os.getenv(\"RAG_CORPUS_ID\",[ ]*\"[^\"]*\")|os.getenv(\"RAG_CORPUS_ID\", \"${RAG_CORPUS_ID}\")|g" \
  -e "s|os.getenv(\"DEMO_AGENT_MODEL\",[ ]*\"[^\"]*\")|os.getenv(\"DEMO_AGENT_MODEL\", \"${AGENT_MODEL}\")|g" \
  -e "s|os.getenv(\"GCS_RECORDINGS_BUCKET\",[ ]*\"[^\"]*\")|os.getenv(\"GCS_RECORDINGS_BUCKET\", \"${GCS_BUCKET}\")|g" \
  backend/config.py
info "backend/config.py"

# k8s/configmap.yaml — environment variables injected into GKE pods
sed -i \
  -e "s|PROJECT_ID: \"[^\"]*\"|PROJECT_ID: \"${PROJECT_ID}\"|g" \
  -e "s|LOCATION: \"[^\"]*\"|LOCATION: \"${REGION}\"|g" \
  -e "s|GOOGLE_CLOUD_PROJECT: \"[^\"]*\"|GOOGLE_CLOUD_PROJECT: \"${PROJECT_ID}\"|g" \
  -e "s|GOOGLE_CLOUD_LOCATION: \"[^\"]*\"|GOOGLE_CLOUD_LOCATION: \"${REGION}\"|g" \
  -e "s|RAG_CORPUS_ID: \"[^\"]*\"|RAG_CORPUS_ID: \"${RAG_CORPUS_ID}\"|g" \
  -e "s|DEMO_AGENT_MODEL: \"[^\"]*\"|DEMO_AGENT_MODEL: \"${AGENT_MODEL}\"|g" \
  -e "s|GCS_RECORDINGS_BUCKET: \"[^\"]*\"|GCS_RECORDINGS_BUCKET: \"${GCS_BUCKET}\"|g" \
  k8s/configmap.yaml
info "k8s/configmap.yaml"

# k8s/serviceaccount.yaml — Workload Identity annotation
sed -i \
  -e "s|iam.gke.io/gcp-service-account:.*|iam.gke.io/gcp-service-account: ${GCP_SA_EMAIL}|g" \
  k8s/serviceaccount.yaml
info "k8s/serviceaccount.yaml"

# k8s/deployment.yaml — container image (also patched by cloudbuild step 3)
sed -i \
  -e "s|image: gcr.io/[^/]*/geminilive-glive:[^[:space:]]*|image: ${IMAGE}:latest|g" \
  k8s/deployment.yaml
info "k8s/deployment.yaml"

# k8s/ingress.yaml — domain and static IP
sed -i \
  -e "s|REPLACE_WITH_DOMAIN|${DOMAIN}|g" \
  -e "s|REPLACE_WITH_STATIC_IP_NAME|${STATIC_IP_NAME}|g" \
  k8s/ingress.yaml
info "k8s/ingress.yaml"

# k8s/configmap.yaml — set BACKEND_WS_URL to the domain immediately
sed -i \
  -e "s|BACKEND_WS_URL: \"[^\"]*\"|BACKEND_WS_URL: \"wss://${DOMAIN}\"|g" \
  k8s/configmap.yaml
info "k8s/configmap.yaml (BACKEND_WS_URL)"

# ── Fetch GKE credentials ──────────────────────────────────────────────────────
step "Fetching GKE credentials for kubectl"
gcloud container clusters get-credentials "$CLUSTER" \
  --region="$REGION" --project="$PROJECT_ID" --quiet
info "kubectl context updated"

# ── Cloud Build — build image + deploy to GKE ─────────────────────────────────
step "Submitting Cloud Build  (build → push → deploy)"
echo ""
echo -e "  ${YELLOW}This may take several minutes. Progress is shown below.${RESET}"
echo ""

gcloud builds submit \
  --project="$PROJECT_ID" \
  --config cloudbuild.yaml \
  --substitutions "_GKE_CLUSTER=${CLUSTER},_GKE_REGION=${REGION}" \
  .

info "Cloud Build completed"

# ── Final ConfigMap patch with domain ────────────────────────────────────────
step "Patching ConfigMap with BACKEND_WS_URL"

kubectl patch configmap gemini-live-config \
  -n "$GKE_NAMESPACE" \
  --type merge \
  -p "{\"data\":{\"BACKEND_WS_URL\":\"wss://${DOMAIN}\"}}"

kubectl rollout restart deployment/gemini-live-backend -n "$GKE_NAMESPACE" --quiet
kubectl rollout status  deployment/gemini-live-backend -n "$GKE_NAMESPACE" \
  --timeout=120s

info "BACKEND_WS_URL = wss://${DOMAIN}"

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
hr
echo -e "  ${GREEN}${BOLD}Deployment complete!${RESET}"
hr
echo ""
echo -e "  Static IP     :  ${BOLD}${_STATIC_IP}${RESET}"
echo -e "  Domain        :  ${BOLD}${DOMAIN}${RESET}"
echo -e "  Health check  :  ${BOLD}https://${DOMAIN}/health${RESET}"
echo -e "  Exotel webhook:  ${BOLD}https://${DOMAIN}/exotel/webhook${RESET}"
echo -e "  WebSocket URL :  ${BOLD}wss://${DOMAIN}/exotel/stream${RESET}"
echo ""
echo -e "  ${YELLOW}⚠  DNS setup required (if not done already):${RESET}"
echo -e "     Create an A record:  ${BOLD}${DOMAIN}  →  ${_STATIC_IP}${RESET}"
echo ""
echo -e "  ${YELLOW}⚠  TLS certificate status:${RESET}"
echo -e "     kubectl describe managedcertificate gemini-live-cert -n ${GKE_NAMESPACE}"
echo -e "     Certificate provisioning takes 15–60 min after DNS propagates."
echo ""
