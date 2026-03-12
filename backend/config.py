"""Central configuration for Motilal Oswal Contact Center.

Edit the default values in this file to change project-wide settings.
Any setting can be overridden at runtime via the matching environment variable
(set in k8s/configmap.yaml for GKE deployments, or backend/.env for local dev).

Variables
---------
PROJECT_ID            GCP project ID.
LOCATION              GCP region (must match where the RAG corpus lives).
RAG_CORPUS_ID         Numeric ID of the Vertex AI RAG corpus.
RAG_CORPUS            Full resource path — built automatically from the above three.
DEMO_AGENT_MODEL      Gemini Live model used for the voice agent.
GCS_RECORDINGS_BUCKET GCS bucket where transcripts are stored.
BACKEND_WS_URL        Public wss:// URL returned to Exotel in ExoML.
HOST / PORT           Uvicorn bind address (local dev only).
APP_NAME              ADK application name — also used as the GCS folder prefix.
"""

import os

# ── Google Cloud ──────────────────────────────────────────────────────────────
PROJECT_ID = os.getenv("PROJECT_ID", "general-ak")
LOCATION   = os.getenv("LOCATION",   "us-central1")

# ── Vertex AI RAG Corpus ──────────────────────────────────────────────────────
# Only change RAG_CORPUS_ID. RAG_CORPUS is built automatically.
RAG_CORPUS_ID = os.getenv("RAG_CORPUS_ID", "6917529027641081856")
RAG_CORPUS    = (
    f"projects/{PROJECT_ID}/locations/{LOCATION}"
    f"/ragCorpora/{RAG_CORPUS_ID}"
)

# ── Agent Model ───────────────────────────────────────────────────────────────
DEMO_AGENT_MODEL = os.getenv(
    "DEMO_AGENT_MODEL", "gemini-live-2.5-flash-native-audio"
)

# ── GCS Transcript Storage ────────────────────────────────────────────────────
GCS_RECORDINGS_BUCKET = os.getenv(
    "GCS_RECORDINGS_BUCKET", "mofsl-contact-center-recordings"
)

# ── Exotel / Server ───────────────────────────────────────────────────────────
# BACKEND_WS_URL: set to your public wss:// address so Exotel can reach the
# WebSocket stream endpoint.  Leave empty for local dev (auto-detected).
BACKEND_WS_URL = os.getenv("BACKEND_WS_URL", "")
HOST           = os.getenv("HOST", "0.0.0.0")
PORT           = int(os.getenv("PORT", "8080"))

# ── ADK Application Name ──────────────────────────────────────────────────────
APP_NAME = "mofsl-contact-center"
