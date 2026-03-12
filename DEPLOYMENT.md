# Gemini Live — MOFSL Contact Center — Deployment Guide

## Overview

A voice-based AI contact center agent for **Motilal Oswal Financial Services (MOFSL)**.
Exotel delivers inbound phone calls as WebSocket audio streams. The backend bridges them
to the **Gemini Live API** via Google ADK. The AI agent ("Arjun") handles customer
queries in Hindi, Hinglish, Marathi, Gujarati, and English, and verifies customer
identity against a Vertex AI RAG corpus.

---

## Architecture

```
Caller (Phone)
    │  PSTN
    ▼
Exotel
    │  HTTP POST  →  /exotel/webhook   →  ExoML (<Stream url="wss://..."/>)
    │  WebSocket  →  /exotel/stream
    │   ├─ inbound  PCM 16kHz  ─────────────────────────────►  Gemini Live API
    │   └─ outbound PCM 16kHz  ◄── downsample 24→16kHz ──────  (via ADK Runner)
    │                                                                 │
    │                                                                 └─► customer_verification_agent
    │                                                                       (gemini-2.5-flash + RAG)
    ▼                                                                       ▼
  Call ends  →  transcript saved to GCS                     Vertex AI RAG Corpus
                                                              (MOFSL account records)
```

**Authentication**: GKE Workload Identity — no API keys or secrets needed.

---

## Technology Stack

| Layer | Technology |
|---|---|
| Telephony | Exotel Media Streaming WebSocket |
| Voice AI | `gemini-live-2.5-flash-native-audio` via Vertex AI |
| Verification | `gemini-2.5-flash` + Vertex AI RAG Engine |
| Agent framework | Google ADK (`google-adk`) |
| Web server | FastAPI + Uvicorn |
| CI/CD + Build | Cloud Build → Google Container Registry |
| Orchestration | Google Kubernetes Engine (GKE) |
| Transcripts | Google Cloud Storage |
| Auth | GKE Workload Identity (no API keys) |

---

## Repository Structure

```
/
├── deploy.sh                        # ← Full automated deployment script
├── cloudbuild.yaml                  # Cloud Build: build image + deploy to GKE
├── DEPLOYMENT.md                    # This file
├── .gcloudignore
│
├── backend/
│   ├── config.py                    # ← Edit defaults here (or use env vars)
│   ├── main.py                      # FastAPI app — Exotel WebSocket bridge
│   ├── audio_utils.py               # PCM 24kHz → 16kHz resampler
│   ├── storage_utils.py             # GCS transcript upload
│   ├── requirements.txt
│   ├── Dockerfile
│   ├── .env.example                 # Copy to .env for local dev
│   └── gemini_agent/
│       ├── agent.py                 # Root voice agent (Arjun)
│       └── sub_agents/
│           └── policy_agent.py      # Customer verification (Vertex AI RAG)
│
└── k8s/
    ├── namespace.yaml
    ├── serviceaccount.yaml          # Workload Identity KSA
    ├── configmap.yaml               # ← Edit for GKE environment config
    ├── deployment.yaml              # Deployment + HPA (1–5 pods)
    └── service.yaml                 # LoadBalancer + BackendConfig (3600s timeout)
```

---

## Configuration

### `backend/config.py` — code defaults (local dev)

The single file to edit for project-wide Python defaults. Every module imports
from it. Environment variables always override these defaults at runtime.

| Variable | Default | Description |
|---|---|---|
| `PROJECT_ID` | `general-ak` | GCP project ID |
| `LOCATION` | `us-central1` | GCP region |
| `RAG_CORPUS_ID` | `6917529027641081856` | Vertex AI RAG corpus numeric ID |
| `DEMO_AGENT_MODEL` | `gemini-live-2.5-flash-native-audio` | Gemini Live model |
| `GCS_RECORDINGS_BUCKET` | `mofsl-contact-center-recordings` | GCS transcript bucket |
| `BACKEND_WS_URL` | *(empty)* | Public `wss://` URL for Exotel |
| `APP_NAME` | `mofsl-contact-center` | ADK app name |

### `k8s/configmap.yaml` — GKE runtime config

Mirrors the same keys as `config.py`. Values here are injected as environment
variables into every pod. `deploy.sh` updates both files automatically.

---

## Automated Deployment (Recommended)

**Prerequisites**: `gcloud` authenticated, `kubectl` installed, a GCP project with billing enabled.

```bash
./deploy.sh
```

The script prompts for:

| Prompt | Default |
|---|---|
| GCP Project ID | `general-ak` |
| GKE Cluster name | `gemini-live-cluster` |
| GKE Region | `us-central1` |
| Vertex AI RAG Corpus ID | `6917529027641081856` |
| GCS Bucket | `mofsl-contact-center-recordings` |
| Gemini Live model | `gemini-live-2.5-flash-native-audio` |

It then fully automates:
1. Enables all required GCP APIs
2. Creates the GKE cluster (with Workload Identity) if it doesn't exist
3. Creates the GCP service account if it doesn't exist
4. Grants `roles/aiplatform.user` and `roles/storage.objectAdmin` (`--condition=None`)
5. Binds Workload Identity (`--condition=None`)
6. Grants the Cloud Build SA `roles/container.developer` + `roles/storage.admin`
7. Creates the GCS bucket if it doesn't exist
8. Updates `config.py`, `k8s/configmap.yaml`, `k8s/serviceaccount.yaml`, `k8s/deployment.yaml`
9. Submits Cloud Build → builds image → pushes to GCR → deploys to GKE
10. Patches `BACKEND_WS_URL` into the ConfigMap once the external IP is assigned

---

## Subsequent Deployments (code changes)

After the first `./deploy.sh`, re-deploying new code only requires:

```bash
gcloud builds submit \
  --config cloudbuild.yaml \
  --substitutions _GKE_CLUSTER=gemini-live-cluster,_GKE_REGION=us-central1 \
  .
```

Or set up a **Cloud Build trigger** in the Console to run this automatically on every push.

---

## Local Development

```bash
# 1. Copy and edit the env file
cp backend/.env.example backend/.env

# 2. Install dependencies
pip install -r backend/requirements.txt

# 3. Authenticate locally
gcloud auth application-default login

# 4. Run the server
cd backend
uvicorn main:app --host 0.0.0.0 --port 8080 --reload

# Test the webhook endpoint
curl http://localhost:8080/exotel/webhook
# Returns ExoML XML

# Expose locally for Exotel testing (optional)
# ngrok http 8080  →  set BACKEND_WS_URL=wss://<ngrok-host> in .env
```

---

## Exotel Configuration

1. In your Exotel dashboard, create or edit an **ExoML App**.
2. Set the **Webhook URL** to `https://<EXTERNAL_IP>/exotel/webhook`.
3. Exotel calls the webhook on inbound calls, receives the ExoML, and opens a
   WebSocket to `wss://<EXTERNAL_IP>/exotel/stream`.
4. **Production TLS**: Exotel requires `wss://` (TLS). Options:
   - **GKE Managed Certificate** (recommended): Reserve a static IP → point a domain → add a `ManagedCertificate` + Ingress resource.
   - **nginx-ingress + cert-manager**: Install via Helm, add an Ingress with cert-manager annotations.

---

## Scaling

The HPA in `k8s/deployment.yaml` auto-scales between **1 and 5 pods** at 60% CPU.
`terminationGracePeriodSeconds: 600` lets in-flight calls (up to 10 min) complete
gracefully before a pod shuts down.

---

## Troubleshooting

```bash
# Pod status
kubectl get pods -n gemini-live

# Live logs
kubectl logs -l app=gemini-live-backend -n gemini-live --follow

# Health check
curl http://<EXTERNAL_IP>/health
# Expected: {"status":"healthy","app":"mofsl-contact-center"}

# Check current ConfigMap
kubectl get configmap gemini-live-config -n gemini-live -o yaml
```

| Symptom | Likely Cause |
|---|---|
| Pods CrashLoopBackOff | Check logs — missing env vars or Workload Identity not bound |
| Exotel webhook error | Verify the URL is publicly reachable; check HTTPS vs HTTP |
| No audio response | Verify `DEMO_AGENT_MODEL` is correct; check `roles/aiplatform.user` |
| RAG returns no results | Check `RAG_CORPUS_ID`; ensure corpus has indexed documents |
| Transcripts not saved | Verify bucket name and `roles/storage.objectAdmin` on the SA |
| WebSocket drops mid-call | Confirm `BackendConfig timeoutSec: 3600` is applied via an Ingress |
