# Gemini Live — MOFSL Contact Center — Deployment Guide

## Overview

A voice-based AI contact center agent for **Motilal Oswal Financial Services (MOFSL)**.
Exotel delivers inbound phone calls as WebSocket audio streams. The backend bridges them
to the **Gemini Live API** via Google ADK. The AI agent ("Arjun") handles customer
queries in Hindi, Hinglish, Marathi, Gujarati, and English, and verifies customer
identity against a Vertex AI RAG corpus.

---

## Why GKE (not Cloud Run)

The Gemini Live API requires a **persistent, stateful WebSocket connection** per call.
Per the [Gemini Live API Best Practices](go/gemini-live-bible), serverless platforms
like Cloud Run are not well-suited for this workload because:

- **No session affinity** — Cloud Run may route requests to different instances,
  breaking the in-memory WebSocket state.
- **Connection timeouts** — Cloud Run's max request timeout is 60 minutes; long
  calls may be cut off.
- **Cold starts** — Scale-to-zero adds unacceptable latency for real-time voice.

GKE Autopilot solves all three:
- `sessionAffinity: ClientIP` pins each caller to the same pod for the call's duration.
- No artificial connection timeout; long calls run until the caller hangs up.
- `minReplicas: 1` in the HPA keeps one pod always warm.

---

## Architecture

```
Caller (Phone)
    │  PSTN
    ▼
Exotel
    │  HTTP POST  →  /exotel/webhook  →  ExoML (<Stream url="wss://..."/>)
    │  WebSocket  →  /exotel/stream
    │   ├─ inbound  PCM 16kHz  ─────────────────────────────►  Gemini Live API
    │   └─ outbound PCM 16kHz  ◄── downsample 24→16kHz ──────  (via ADK Runner)
    │                                                                 │
    │                                                                 └─► customer_verification_agent
    │                                                                       (gemini-2.5-flash + RAG)
    ▼                                                                       ▼
  Call ends  →  transcript saved to GCS                     Vertex AI RAG Corpus
                                                              (MOFSL account records)

GKE HTTP(S) Global Load Balancer
    │  TLS termination (Google-managed cert)
    │  Static global IP
    ▼
GKE Ingress  →  Service (sessionAffinity: ClientIP)  →  Pod(s)
```

**Authentication**: Workload Identity — pods authenticate to GCP APIs as the
`gemini-live-backend` service account without key files.

---

## Technology Stack

| Layer | Technology |
|---|---|
| Telephony | Exotel Media Streaming WebSocket |
| Voice AI | `gemini-live-2.5-flash-native-audio` via Vertex AI |
| Verification | `gemini-2.5-flash` + Vertex AI RAG Engine |
| Agent framework | Google ADK (`google-adk`) |
| Web server | FastAPI + Uvicorn |
| Compute | GKE Autopilot (managed Kubernetes) |
| CI/CD + Build | Cloud Build → Google Container Registry |
| Transcripts | Google Cloud Storage |
| Auth | Workload Identity (no API keys) |

---

## Repository Structure

```
/
├── deploy.sh                        # ← Full automated GKE deployment script
├── cloudbuild.yaml                  # Cloud Build: build image + rolling update on GKE
├── DEPLOYMENT.md                    # This file
├── .gcloudignore
│
├── k8s/                             # Kubernetes manifests
│   ├── namespace.yaml               # gemini-live namespace
│   ├── serviceaccount.yaml          # KSA with Workload Identity annotation
│   ├── configmap.yaml               # Non-secret config (env vars)
│   ├── deployment.yaml              # Deployment + HorizontalPodAutoscaler
│   ├── service.yaml                 # NodePort Service + BackendConfig (3600s timeout)
│   └── ingress.yaml                 # HTTPS Ingress + ManagedCertificate + FrontendConfig
│
└── backend/
    ├── config.py                    # ← Edit defaults here (or use env vars / configmap)
    ├── main.py                      # FastAPI app — Exotel WebSocket bridge
    ├── audio_utils.py               # PCM 24kHz → 16kHz resampler
    ├── storage_utils.py             # GCS transcript upload
    ├── requirements.txt
    ├── Dockerfile
    ├── .env.example                 # Copy to .env for local dev
    └── gemini_agent/
        ├── agent.py                 # Root voice agent (Arjun)
        └── sub_agents/
            └── customer_verification_agent.py   # Vertex AI RAG verification
```

---

## Configuration

### `backend/config.py` — code defaults (local dev)

| Variable | Default | Description |
|---|---|---|
| `PROJECT_ID` | `general-ak` | GCP project ID |
| `LOCATION` | `us-central1` | GCP region |
| `RAG_CORPUS_ID` | `6917529027641081856` | Vertex AI RAG corpus numeric ID |
| `DEMO_AGENT_MODEL` | `gemini-live-2.5-flash-native-audio` | Gemini Live model |
| `GCS_RECORDINGS_BUCKET` | `mofsl-contact-center-recordings` | GCS transcript bucket |
| `BACKEND_WS_URL` | *(empty)* | Public `wss://` URL — set automatically by deploy.sh |
| `APP_NAME` | `mofsl-contact-center` | ADK app name |

In GKE, all values are set in `k8s/configmap.yaml` and override the code defaults.

---

## Kubernetes Manifests

### Key design decisions

| Resource | Setting | Rationale |
|---|---|---|
| `service.yaml` | `sessionAffinity: ClientIP` | Pins each caller to the same pod. Required for stateful WebSocket connections (Gemini Live Bible §4.2.1). |
| `service.yaml` | `sessionAffinityConfig.timeoutSeconds: 3600` | Session affinity persists for the full max call duration. |
| `service.yaml` (BackendConfig) | `timeoutSec: 3600` | Prevents GCP LB from dropping long calls (default 30 s). |
| `deployment.yaml` | `terminationGracePeriodSeconds: 600` | Active calls drain gracefully on rolling updates. |
| `deployment.yaml` (HPA) | `minReplicas: 1, maxReplicas: 5` | Always-warm pod avoids cold-start latency; scales under load. |
| `ingress.yaml` | Google-managed cert | Automatic TLS — zero maintenance. |

---

## Automated Deployment (Recommended)

**Prerequisites**:
- `gcloud` CLI installed and authenticated (`gcloud auth login`)
- `kubectl` installed (`gcloud components install kubectl`)
- A GCP project with billing enabled
- A domain name with DNS access (for TLS; optional but recommended for production)

```bash
./deploy.sh
```

The script prompts for:

| Prompt | Default |
|---|---|
| GCP Project ID | `general-ak` |
| GKE cluster name | `gemini-live-cluster` |
| Region | `us-central1` |
| Domain for TLS | *(blank — ask for the domain you'll use)* |
| Vertex AI RAG Corpus ID | `6917529027641081856` |
| GCS Bucket | `mofsl-contact-center-recordings` |
| Gemini Live model | `gemini-live-2.5-flash-native-audio` |

It then fully automates:
1. Enables all required GCP APIs
2. Creates the GCP service account and grants `roles/aiplatform.user` + `roles/storage.objectAdmin`
3. Grants the Cloud Build SA `roles/container.developer` + `roles/storage.admin` + `roles/iam.serviceAccountUser`
4. Creates the GCS transcript bucket
5. Reserves a global static IP (`gemini-live-ip`)
6. Creates a GKE Autopilot cluster
7. Configures Workload Identity
8. Builds and pushes the container image via Cloud Build
9. Applies all Kubernetes manifests with project-specific values substituted
10. Waits for the Deployment rollout to complete
11. Sets `BACKEND_WS_URL` and restarts the Deployment

---

## Subsequent Deployments (code changes)

After the initial `./deploy.sh`, re-deploying new code only requires:

```bash
gcloud builds submit \
  --config cloudbuild.yaml \
  --substitutions "_CLUSTER_NAME=gemini-live-cluster,_REGION=us-central1" \
  .
```

Cloud Build will:
1. Build the new image
2. Push to GCR
3. Run `kubectl set image` for a zero-downtime rolling update
4. Wait for the rollout to complete (fails the build if pods do not become ready)

Or set up a **Cloud Build trigger** in the Console to run this automatically on every push to `main`.

---

## Local Development

```bash
# 1. Copy and edit the env file
cp backend/.env.example backend/.env

# 2. Install dependencies
pip install -r backend/requirements.txt

# 3. Authenticate locally (uses your gcloud credentials for Vertex AI)
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
2. Set the **Webhook URL** to `https://<DOMAIN>/exotel/webhook`.
3. Exotel calls the webhook on inbound calls, receives the ExoML, and opens a
   WebSocket to `wss://<DOMAIN>/exotel/stream`.

---

## GKE Settings Summary

| Resource | Setting | Value | Reason |
|---|---|---|---|
| HPA | `minReplicas` | 1 | Avoids cold start; always one warm pod |
| HPA | `maxReplicas` | 5 | Scales under concurrent call load |
| Deployment | `terminationGracePeriodSeconds` | 600 s | Graceful drain of in-flight calls |
| Service | `sessionAffinity` | `ClientIP` | WebSocket state pinned to one pod |
| Service | `sessionAffinityConfig.timeoutSeconds` | 3600 s | Persists for full call duration |
| BackendConfig | `timeoutSec` | 3600 s | LB does not drop long calls |
| BackendConfig | `drainingTimeoutSec` | 600 s | Matches pod termination grace period |

---

## Troubleshooting

```bash
# Check pod status
kubectl get pods -n gemini-live

# Stream live logs
kubectl logs -f -n gemini-live deploy/gemini-live-backend

# Describe a crashing pod
kubectl describe pod -n gemini-live <pod-name>

# View ConfigMap (check env vars)
kubectl describe configmap gemini-live-config -n gemini-live

# Check Ingress IP and TLS status
kubectl describe ingress gemini-live-ingress -n gemini-live
kubectl describe managedcertificate gemini-live-cert -n gemini-live

# Health check (replace IP/domain)
curl https://<DOMAIN>/health
# Expected: {"status":"healthy","app":"mofsl-contact-center"}

# Force a re-deploy (e.g. to pick up new ConfigMap values)
kubectl rollout restart deployment/gemini-live-backend -n gemini-live
kubectl rollout status deployment/gemini-live-backend -n gemini-live
```

| Symptom | Likely Cause |
|---|---|
| Pod in `CrashLoopBackOff` | Check logs — missing env vars or Workload Identity not bound |
| No audio response | Verify `DEMO_AGENT_MODEL`; confirm pod has `roles/aiplatform.user` via Workload Identity |
| Exotel webhook error | Verify the domain A record and TLS cert are active; check Ingress IP |
| RAG returns no results | Check `RAG_CORPUS_ID`; ensure corpus has indexed documents |
| Transcripts not saved | Verify bucket name and `roles/storage.objectAdmin` on the GSA |
| Call drops mid-conversation | Check `sessionAffinity: ClientIP` is set; check BackendConfig `timeoutSec: 3600` |
| TLS cert not provisioning | DNS A record may not have propagated; can take up to 60 min |
| Cold start on first call | Ensure HPA `minReplicas: 1`; pod should always be running |
