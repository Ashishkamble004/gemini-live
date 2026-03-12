#!/usr/bin/env bash
# =============================================================================
# deploy.sh — Automated GKE deployment for Gemini Live MOFSL Contact Center
# =============================================================================
#
# Run from the repository root:  ./deploy.sh
#
# Prerequisites (must be installed and authenticated):
#   - gcloud  (gcloud auth login && gcloud auth configure-docker)
#   - kubectl (automatically configured by gcloud after cluster creation)
#
# This script will:
#   1. Enable required GCP APIs
#   2. Create the GCP service account if it does not exist
#   3. Grant required IAM roles to the service account
#   4. Grant the Cloud Build SA permissions to build and update GKE workloads
#   5. Create the GCS transcript bucket if it does not exist
#   6. Reserve a global static IP for the Ingress
#   7. Create a GKE Autopilot cluster if it does not exist
#   8. Configure Workload Identity (bind KSA to GSA)
#   9. Build the container image with Cloud Build and push to GCR
#  10. Apply all Kubernetes manifests (namespace, SA, configmap, deployment,
#      service, ingress) with project-specific values substituted
#  11. Wait for the Deployment rollout to complete
#  12. Set BACKEND_WS_URL in the ConfigMap and restart the Deployment
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

# ── Prerequisite checks ────────────────────────────────────────────────────────
command -v gcloud &>/dev/null || error "'gcloud' not found. Install the Google Cloud SDK."
command -v kubectl &>/dev/null || error "'kubectl' not found. Install it: gcloud components install kubectl"

gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null \
  | grep -q "." \
  || error "No active gcloud account. Run: gcloud auth login"

# gke-gcloud-auth-plugin is required for kubectl to authenticate to GKE clusters.
# We check for the actual binary in PATH — not gcloud component state, which is
# unreliable when gcloud was installed via apt rather than the standalone SDK.
if ! command -v gke-gcloud-auth-plugin &>/dev/null; then
  echo -e "  ${YELLOW}gke-gcloud-auth-plugin not found — installing...${RESET}"

  # Path 1: standalone SDK installer (gcloud components install)
  if gcloud components install gke-gcloud-auth-plugin --quiet 2>/dev/null \
      && command -v gke-gcloud-auth-plugin &>/dev/null; then
    info "gke-gcloud-auth-plugin installed via gcloud components"

  # Path 2: apt-get (Debian/Ubuntu with package-manager-installed gcloud)
  elif command -v apt-get &>/dev/null; then
    echo -e "  ${YELLOW}gcloud components install failed — trying apt-get...${RESET}"
    sudo apt-get install -y google-cloud-sdk-gke-gcloud-auth-plugin
    info "gke-gcloud-auth-plugin installed via apt-get"

  else
    error "Cannot install gke-gcloud-auth-plugin automatically.\nInstall it manually:\n  gcloud components install gke-gcloud-auth-plugin\n  OR (Debian/Ubuntu): sudo apt-get install google-cloud-sdk-gke-gcloud-auth-plugin"
  fi
fi

# Final guard — abort now rather than get a cryptic kubectl error later
command -v gke-gcloud-auth-plugin &>/dev/null \
  || error "gke-gcloud-auth-plugin is still not in PATH after installation.\nPlease install manually and re-run:\n  gcloud components install gke-gcloud-auth-plugin\n  OR (Debian/Ubuntu): sudo apt-get install google-cloud-sdk-gke-gcloud-auth-plugin"

export USE_GKE_GCLOUD_AUTH_PLUGIN=True
info "gke-gcloud-auth-plugin ready"

# ── Banner ─────────────────────────────────────────────────────────────────────
echo ""
hr
echo -e "  ${BOLD}Gemini Live — MOFSL Contact Center  |  GKE Deployment${RESET}"
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

ask PROJECT_ID     "GCP Project ID"                   "general-ak"
ask CLUSTER_NAME   "GKE cluster name"                 "gemini-live-cluster"
ask REGION         "GCP Region"                       "us-central1"
ask DOMAIN         "Domain for TLS (leave blank to skip TLS)" ""
ask RAG_CORPUS_ID  "Vertex AI RAG Corpus ID"          "6917529027641081856"
ask GCS_BUCKET     "GCS Bucket (transcripts)"         "mofsl-contact-center-recordings"
ask AGENT_MODEL    "Gemini Live model"                "gemini-live-2.5-flash-native-audio"

# ── Derived constants ──────────────────────────────────────────────────────────
GCP_SA_NAME="gemini-live-backend"
GCP_SA_EMAIL="${GCP_SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
IMAGE="gcr.io/${PROJECT_ID}/geminilive-glive"
STATIC_IP_NAME="gemini-live-ip"
KSA_NAMESPACE="gemini-live"
KSA_NAME="gemini-live-sa"

# ── Summary ────────────────────────────────────────────────────────────────────
echo ""
hr
echo -e "  ${BOLD}Summary${RESET}"
hr
echo -e "  Project ID     :  ${PROJECT_ID}"
echo -e "  GKE Cluster    :  ${CLUSTER_NAME}  (${REGION})"
echo -e "  Container      :  ${IMAGE}:latest"
echo -e "  Domain         :  ${DOMAIN:-"(none — BACKEND_WS_URL must be set manually)"}"
echo -e "  RAG Corpus     :  ${RAG_CORPUS_ID}"
echo -e "  GCS Bucket     :  gs://${GCS_BUCKET}"
echo -e "  Agent Model    :  ${AGENT_MODEL}"
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

# ── IAM Role Bindings ─────────────────────────────────────────────────────────
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

# ── Cloud Build SA Permissions ────────────────────────────────────────────────
step "Granting Cloud Build SA access to GCR + GKE"

_PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" \
  --format="value(projectNumber)")
_CB_SA="${_PROJECT_NUMBER}@cloudbuild.gserviceaccount.com"

for ROLE in \
  "roles/container.developer" \
  "roles/storage.admin" \
  "roles/iam.serviceAccountUser"; do

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

# ── Reserve global static IP ───────────────────────────────────────────────────
step "Global static IP: ${STATIC_IP_NAME}"

if gcloud compute addresses describe "$STATIC_IP_NAME" \
    --global --project="$PROJECT_ID" &>/dev/null 2>&1; then
  info "Static IP already reserved"
else
  gcloud compute addresses create "$STATIC_IP_NAME" \
    --global \
    --project="$PROJECT_ID"
  info "Static IP reserved"
fi

_STATIC_IP=$(gcloud compute addresses describe "$STATIC_IP_NAME" \
  --global --project="$PROJECT_ID" --format="value(address)")
info "Static IP: ${_STATIC_IP}"

# ── GKE Autopilot cluster ─────────────────────────────────────────────────────
step "GKE Autopilot cluster: ${CLUSTER_NAME}"

if gcloud container clusters describe "$CLUSTER_NAME" \
    --region="$REGION" --project="$PROJECT_ID" &>/dev/null 2>&1; then
  info "Cluster already exists"
else
  echo "  Creating GKE Autopilot cluster — this may take a few minutes..."
  gcloud container clusters create-auto "$CLUSTER_NAME" \
    --region="$REGION" \
    --project="$PROJECT_ID" \
    --quiet
  info "Cluster created"
fi

# ── Get cluster credentials ────────────────────────────────────────────────────
step "Fetching cluster credentials"

# For private clusters (control plane has no public IP), standard get-credentials
# writes the private RFC-1918 IP which is unreachable from outside the VPC.
# --dns-endpoint (gcloud 454+) uses a DNS FQDN that routes through Google's
# network instead, making it accessible from outside the VPC without a VPN.
# We try --dns-endpoint first and fall back to the standard method.
if gcloud container clusters get-credentials "$CLUSTER_NAME" \
    --region="$REGION" \
    --project="$PROJECT_ID" \
    --dns-endpoint 2>/dev/null; then
  info "kubectl context configured (DNS endpoint)"
else
  gcloud container clusters get-credentials "$CLUSTER_NAME" \
    --region="$REGION" \
    --project="$PROJECT_ID"
  info "kubectl context configured (standard endpoint)"
  warn "If kubectl commands fail with a connection timeout, your cluster may be"
  warn "private with no public endpoint. Run deploy.sh from Cloud Shell instead,"
  warn "or add your IP to Master Authorized Networks:"
  warn "  MY_IP=\$(curl -s https://checkip.amazonaws.com)"
  warn "  gcloud container clusters update ${CLUSTER_NAME} \\"
  warn "    --region=${REGION} --enable-master-authorized-networks \\"
  warn "    --master-authorized-networks=\"\${MY_IP}/32\""
fi

# ── Build and push container image ────────────────────────────────────────────
step "Building and pushing container image"
echo ""
echo -e "  ${YELLOW}Submitting Cloud Build — this may take several minutes.${RESET}"
echo ""

gcloud builds submit \
  --project="$PROJECT_ID" \
  --tag="${IMAGE}:latest" \
  ./backend

info "Image pushed to ${IMAGE}:latest"

# ── Apply Kubernetes manifests ─────────────────────────────────────────────────
step "Applying Kubernetes manifests"

# 1. Namespace
kubectl apply --validate=false -f k8s/namespace.yaml
info "Namespace applied"

# 2. ServiceAccount (substitute project ID)
sed "s|YOUR_PROJECT_ID|${PROJECT_ID}|g" k8s/serviceaccount.yaml | kubectl apply --validate=false -f -
info "ServiceAccount applied"

# 3. ConfigMap (generate inline with actual values)
kubectl apply --validate=false -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: gemini-live-config
  namespace: gemini-live
data:
  PROJECT_ID: "${PROJECT_ID}"
  LOCATION: "${REGION}"
  GOOGLE_GENAI_USE_VERTEXAI: "TRUE"
  GOOGLE_CLOUD_PROJECT: "${PROJECT_ID}"
  GOOGLE_CLOUD_LOCATION: "${REGION}"
  RAG_CORPUS_ID: "${RAG_CORPUS_ID}"
  DEMO_AGENT_MODEL: "${AGENT_MODEL}"
  GCS_RECORDINGS_BUCKET: "${GCS_BUCKET}"
  PORT: "8080"
  HOST: "0.0.0.0"
  BACKEND_WS_URL: ""
EOF
info "ConfigMap applied"

# 4. Deployment + HPA (substitute image registry project)
sed "s|YOUR_PROJECT_ID|${PROJECT_ID}|g" k8s/deployment.yaml | kubectl apply --validate=false -f -
info "Deployment + HPA applied"

# 5. Service + BackendConfig
kubectl apply --validate=false -f k8s/service.yaml
info "Service + BackendConfig applied"

# 6. Ingress (with ManagedCertificate + FrontendConfig)
if [[ -n "${DOMAIN}" ]]; then
  sed -e "s|REPLACE_WITH_DOMAIN|${DOMAIN}|g" \
      -e "s|REPLACE_WITH_STATIC_IP_NAME|${STATIC_IP_NAME}|g" \
      k8s/ingress.yaml | kubectl apply --validate=false -f -
  info "Ingress + ManagedCertificate applied"
  warn "DNS: create an A record pointing ${DOMAIN} → ${_STATIC_IP}"
  warn "TLS cert provisioning takes 15–60 min after DNS propagation."
else
  warn "No domain provided — skipping Ingress/TLS. You must set BACKEND_WS_URL manually."
  warn "To add TLS later, re-run: ./deploy.sh and provide a domain."
fi

# ── Workload Identity binding ──────────────────────────────────────────────────
step "Configuring Workload Identity"

gcloud iam service-accounts add-iam-policy-binding "${GCP_SA_EMAIL}" \
  --role="roles/iam.workloadIdentityUser" \
  --member="serviceAccount:${PROJECT_ID}.svc.id.goog[${KSA_NAMESPACE}/${KSA_NAME}]" \
  --project="$PROJECT_ID" \
  --quiet

info "Workload Identity binding created"

# Annotate the KSA so GKE knows which GSA it maps to
kubectl annotate serviceaccount "${KSA_NAME}" \
  --namespace="${KSA_NAMESPACE}" \
  iam.gke.io/gcp-service-account="${GCP_SA_EMAIL}" \
  --overwrite
info "KSA annotation confirmed"

# ── Wait for rollout ───────────────────────────────────────────────────────────
step "Waiting for Deployment rollout"
kubectl rollout status deployment/gemini-live-backend \
  --namespace=gemini-live \
  --timeout=300s
info "Deployment is ready"

# ── Set BACKEND_WS_URL ─────────────────────────────────────────────────────────
step "Configuring BACKEND_WS_URL"

if [[ -n "${DOMAIN}" ]]; then
  _WS_URL="wss://${DOMAIN}"
else
  _WS_URL="wss://${_STATIC_IP}"
fi

kubectl patch configmap gemini-live-config \
  --namespace=gemini-live \
  --type=merge \
  -p "{\"data\":{\"BACKEND_WS_URL\":\"${_WS_URL}\"}}"

kubectl rollout restart deployment/gemini-live-backend \
  --namespace=gemini-live

kubectl rollout status deployment/gemini-live-backend \
  --namespace=gemini-live \
  --timeout=300s

info "BACKEND_WS_URL = ${_WS_URL}"

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
hr
echo -e "  ${GREEN}${BOLD}Deployment complete!${RESET}"
hr
echo ""
echo -e "  GKE Cluster    :  ${BOLD}${CLUSTER_NAME}${RESET} (${REGION})"
echo -e "  Static IP      :  ${BOLD}${_STATIC_IP}${RESET}"
if [[ -n "${DOMAIN}" ]]; then
  echo -e "  Domain         :  ${BOLD}${DOMAIN}${RESET}"
  echo -e "  Backend URL    :  ${BOLD}${_WS_URL}${RESET}"
fi
echo ""
echo -e "  ${YELLOW}⚠  Configure Exotel:${RESET}"
if [[ -n "${DOMAIN}" ]]; then
  echo -e "     Webhook URL  : ${BOLD}https://${DOMAIN}/exotel/webhook${RESET}"
  echo -e "     WebSocket URL: ${BOLD}${_WS_URL}/exotel/stream${RESET}"
else
  echo -e "     Once your domain is configured, re-run ./deploy.sh to set BACKEND_WS_URL."
fi
echo ""
echo -e "  ${YELLOW}⚠  Re-deploy after code changes:${RESET}"
echo -e "     gcloud builds submit \\"
echo -e "       --config cloudbuild.yaml \\"
echo -e "       --substitutions \"_CLUSTER_NAME=${CLUSTER_NAME},_REGION=${REGION}\" \\"
echo -e "       ."
echo ""
echo -e "  ${YELLOW}⚠  Check pod status:${RESET}"
echo -e "     kubectl get pods -n gemini-live"
echo -e "     kubectl logs -f -n gemini-live deploy/gemini-live-backend"
echo ""
