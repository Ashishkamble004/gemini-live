"""FastAPI application — Exotel ↔ Gemini Live API bridge.

Architecture:
  Exotel (caller) ──WS──► /exotel/stream ──► Gemini Live (ADK)
                               ◄──────────────────────────────

Call flow:
  1. Exotel places a call and hits /exotel/webhook (HTTP POST/GET).
  2. Server responds with ExoML directing Exotel to stream audio to
     /exotel/stream via WebSocket.
  3. Exotel opens the WebSocket and sends PCM 16kHz audio chunks as
     base64 JSON {"event": "media", "media": {"track": "inbound", ...}}.
  4. Server passes the 16kHz PCM directly to Gemini Live (no conversion).
  5. Gemini responds with PCM 24kHz audio; server downsamples to 16kHz
     PCM and streams back to Exotel.
  6. On call end Exotel sends {"event": "stop"} and the WebSocket closes.
  7. Conversation transcript is saved to GCS.

Authentication:
  Uses Vertex AI with Workload Identity — no API key required.
"""

import asyncio
from contextlib import asynccontextmanager
import base64
import json
import logging
import os
import uuid
import warnings
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List

from dotenv import load_dotenv

# Load .env before importing config or ADK/agent modules
load_dotenv(Path(__file__).parent / ".env")

import config  # noqa: E402 — must come after load_dotenv

os.environ.setdefault("GOOGLE_GENAI_USE_VERTEXAI", "TRUE")
os.environ.setdefault("GOOGLE_CLOUD_PROJECT", config.PROJECT_ID)
os.environ.setdefault("GOOGLE_CLOUD_LOCATION", config.LOCATION)

from fastapi import FastAPI, Request, WebSocket, WebSocketDisconnect
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import Response
from google.adk.agents.live_request_queue import LiveRequestQueue
from google.adk.agents.run_config import RunConfig, StreamingMode
from google.adk.runners import Runner
from google.adk.sessions import InMemorySessionService
from google.genai import types

import audio_utils
from gemini_agent.agent import agent
from storage_utils import save_transcript

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

logging.basicConfig(
    level=logging.DEBUG,
    format="%(asctime)s - %(name)s - %(levelname)s - %(message)s",
)
logger = logging.getLogger(__name__)
warnings.filterwarnings("ignore", category=UserWarning, module="pydantic")

# ---------------------------------------------------------------------------
# Application setup
# ---------------------------------------------------------------------------

APP_NAME = config.APP_NAME


# ---------------------------------------------------------------------------
# Application lifespan (startup / shutdown)
# ---------------------------------------------------------------------------


@asynccontextmanager
async def lifespan(app: FastAPI):
    logger.info("Motilal Oswal Contact Center (Exotel bridge) starting...")
    logger.info(f"Project: {config.PROJECT_ID}")
    logger.info(f"Location: {config.LOCATION}")
    logger.info(f"Agent model: {agent.model}")
    yield
    logger.info("Motilal Oswal Contact Center (Exotel bridge) shutting down...")


app = FastAPI(title="Motilal Oswal Contact Center — Exotel/Gemini Live Bridge", lifespan=lifespan)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

session_service = InMemorySessionService()
runner = Runner(app_name=APP_NAME, agent=agent, session_service=session_service)


# ---------------------------------------------------------------------------
# RunConfig (audio-only telephony — always native-audio path)
# ---------------------------------------------------------------------------

def _build_run_config() -> RunConfig:
    """Build a RunConfig for native-audio models (telephony use-case)."""
    return RunConfig(
        streaming_mode=StreamingMode.BIDI,
        response_modalities=["AUDIO"],
        input_audio_transcription=types.AudioTranscriptionConfig(),
        output_audio_transcription=types.AudioTranscriptionConfig(),
        session_resumption=types.SessionResumptionConfig(transparent=True),
        context_window_compression=types.ContextWindowCompressionConfig(
            trigger_tokens=64000,
            sliding_window=types.SlidingWindow(target_tokens=32000),
        ),
        realtime_input_config=types.RealtimeInputConfig(
            automatic_activity_detection=types.AutomaticActivityDetection(
                disabled=False,
                start_of_speech_sensitivity=types.StartSensitivity.START_SENSITIVITY_LOW,
                end_of_speech_sensitivity=types.EndSensitivity.END_SENSITIVITY_HIGH,
                prefix_padding_ms=100,
                silence_duration_ms=500,
            )
        ),
        speech_config=types.SpeechConfig(
            voice_config=types.VoiceConfig(
                prebuilt_voice_config=types.PrebuiltVoiceConfig(voice_name="Charon")
            )
        ),
    )


# ---------------------------------------------------------------------------
# HTTP endpoints
# ---------------------------------------------------------------------------


@app.get("/health")
async def health_check():
    return {"status": "healthy", "app": APP_NAME}


@app.get("/")
async def root():
    return {
        "message": "Motilal Oswal Contact Center — Exotel/Gemini Live Bridge",
        "exotel_webhook": "/exotel/webhook",
        "exotel_stream": "/exotel/stream (WebSocket)",
        "health_check": "/health",
    }


@app.api_route("/exotel/webhook", methods=["GET", "POST"])
async def exotel_webhook(request: Request) -> Response:
    """Called by Exotel when an inbound call arrives.

    Exotel sends call metadata as form data (POST) or query params (GET).
    We respond with ExoML that instructs Exotel to stream audio to
    /exotel/stream via WebSocket.

    NOTE: Verify the exact ExoML <Stream> syntax against your Exotel account
    plan — Exotel's streaming verb is available on select plans and the XML
    attribute names may differ across API versions.
    """
    # Resolve the public WebSocket base URL from env, falling back to the
    # request's own host so the server is self-describing in local dev.
    backend_ws_url = config.BACKEND_WS_URL.rstrip("/")
    if not backend_ws_url:
        host = request.headers.get("host", "localhost:8080")
        scheme = "wss" if request.url.scheme == "https" else "ws"
        backend_ws_url = f"{scheme}://{host}"

    stream_url = f"{backend_ws_url}/exotel/stream"

    exoml = f"""<?xml version="1.0" encoding="UTF-8"?>
<Response>
    <Connect>
        <Stream url="{stream_url}" />
    </Connect>
</Response>"""

    logger.info(f"Exotel webhook hit — returning stream URL: {stream_url}")
    return Response(content=exoml, media_type="application/xml")


# ---------------------------------------------------------------------------
# Exotel WebSocket stream endpoint
# ---------------------------------------------------------------------------


@app.websocket("/exotel/stream")
async def exotel_stream(websocket: WebSocket) -> None:
    """Bidirectional audio bridge between Exotel and Gemini Live.

    Exotel WebSocket message schema (inbound):
      {"event": "connected", "protocol": "Call", "version": "1.0.0"}
      {"event": "start",    "streamSid": "...", "start": {"callSid": "...", "from": "...", "to": "..."}}
      {"event": "media",    "streamSid": "...", "media": {"track": "inbound", "payload": "<b64 pcm16k>"}}
      {"event": "stop",     "streamSid": "...", "stop":  {"callSid": "..."}}

    Outbound messages to Exotel:
      {"event": "media", "streamSid": "...", "media": {"payload": "<b64 pcm16k>"}}
      {"event": "mark",  "streamSid": "...", "mark":  {"name": "<label>"}}
      {"event": "clear", "streamSid": "..."}
    """
    await websocket.accept()

    # --- per-call state --------------------------------------------------
    stream_sid: str | None = None
    call_sid: str | None = None
    call_from: str = "unknown"
    call_to: str = "unknown"
    user_id = f"exotel-{uuid.uuid4().hex[:8]}"
    session_id = f"call-{uuid.uuid4().hex[:8]}"

    conversation_messages: List[Dict[str, Any]] = []

    # per-call resampler state for outbound audio (24kHz → 16kHz)
    downsample_state: Any = None

    call_stop_event = asyncio.Event()

    logger.info(f"Exotel WebSocket connected — user_id={user_id}, session_id={session_id}")

    # --- ADK session -----------------------------------------------------
    await session_service.create_session(
        app_name=APP_NAME, user_id=user_id, session_id=session_id
    )
    run_config = _build_run_config()
    live_request_queue = LiveRequestQueue()

    # =================================================================
    # upstream_task: Exotel → Gemini
    # =================================================================

    async def upstream_task() -> None:
        nonlocal stream_sid, call_sid, call_from, call_to

        while not call_stop_event.is_set():
            try:
                message = await asyncio.wait_for(
                    websocket.receive(), timeout=30.0
                )
            except asyncio.TimeoutError:
                # Send a keepalive / heartbeat — do nothing, just loop
                continue

            if "text" not in message:
                continue

            try:
                data = json.loads(message["text"])
            except json.JSONDecodeError:
                logger.warning(f"Non-JSON message received: {message['text'][:100]}")
                continue

            event = data.get("event", "")

            if event == "connected":
                logger.info(f"Exotel stream connected: {data}")

            elif event == "start":
                stream_sid = data.get("streamSid") or data.get("stream_sid")
                start_info = data.get("start", {})
                call_sid = start_info.get("callSid") or start_info.get("call_sid")
                call_from = start_info.get("from", start_info.get("From", "unknown"))
                call_to = start_info.get("to", start_info.get("To", "unknown"))
                logger.info(
                    f"Call started — callSid={call_sid}, streamSid={stream_sid}, "
                    f"from={call_from}, to={call_to}"
                )

            elif event == "media":
                media = data.get("media", {})
                # Only forward inbound (caller) audio to Gemini
                if media.get("track", "inbound") != "inbound":
                    continue
                payload_b64 = media.get("payload", "")
                if not payload_b64:
                    continue
                try:
                    # Exotel sends PCM 16kHz — pass directly to Gemini
                    pcm_16k = base64.b64decode(payload_b64)
                    if pcm_16k:
                        blob = types.Blob(
                            mime_type="audio/pcm;rate=16000", data=pcm_16k
                        )
                        live_request_queue.send_realtime(blob)
                except Exception as exc:
                    logger.error(f"Error processing inbound audio: {exc}", exc_info=True)

            elif event == "stop":
                logger.info(f"Exotel stop event received: {data}")
                call_stop_event.set()
                break

    # =================================================================
    # downstream_task: Gemini → Exotel
    # =================================================================

    async def downstream_task() -> None:
        nonlocal conversation_messages, downsample_state

        async for event in runner.run_live(
            user_id=user_id,
            session_id=session_id,
            live_request_queue=live_request_queue,
            run_config=run_config,
        ):
            if call_stop_event.is_set():
                break

            try:
                # ---- collect transcriptions -----------------------------
                if event.input_transcription:
                    if (
                        event.input_transcription.finished
                        and event.input_transcription.text
                    ):
                        conversation_messages.append(
                            {
                                "role": "user",
                                "text": event.input_transcription.text,
                                "timestamp": datetime.now(timezone.utc).isoformat(),
                            }
                        )

                if event.output_transcription:
                    if (
                        event.output_transcription.finished
                        and event.output_transcription.text
                    ):
                        conversation_messages.append(
                            {
                                "role": "model",
                                "text": event.output_transcription.text,
                                "timestamp": datetime.now(timezone.utc).isoformat(),
                            }
                        )

                # ---- stream audio back to Exotel -------------------------
                if event.content and event.content.parts:
                    for part in event.content.parts:
                        if (
                            part.inline_data
                            and part.inline_data.data
                            and "audio" in (part.inline_data.mime_type or "")
                            and isinstance(part.inline_data.data, bytes)
                        ):
                            pcm_24k = part.inline_data.data
                            # Downsample 24kHz → 16kHz for Exotel
                            pcm_16k, downsample_state = (
                                audio_utils.pcm24khz_to_pcm16khz(
                                    pcm_24k, downsample_state
                                )
                            )
                            if pcm_16k and stream_sid:
                                payload_b64 = base64.b64encode(pcm_16k).decode(
                                    "ascii"
                                )
                                await websocket.send_json(
                                    {
                                        "event": "media",
                                        "streamSid": stream_sid,
                                        "media": {"payload": payload_b64},
                                    }
                                )

                # ---- send mark when model finishes a turn ----------------
                if event.turn_complete and stream_sid:
                    await websocket.send_json(
                        {
                            "event": "mark",
                            "streamSid": stream_sid,
                            "mark": {"name": "turn_complete"},
                        }
                    )

            except Exception as exc:
                logger.error(f"Error in downstream_task: {exc}", exc_info=True)

        logger.debug("run_live() generator finished")

    # =================================================================
    # Run upstream + downstream concurrently
    # =================================================================

    try:
        await asyncio.gather(upstream_task(), downstream_task())
    except WebSocketDisconnect:
        logger.info(f"WebSocket disconnected — session={session_id}")
    except Exception as exc:
        logger.error(f"Unhandled error in session {session_id}: {exc}", exc_info=True)
    finally:
        live_request_queue.close()
        logger.info(
            f"Session {session_id} ended — "
            f"messages={len(conversation_messages)}"
        )

        # Save transcript to GCS
        if conversation_messages:
            try:
                uri = await save_transcript(
                    session_id=session_id,
                    user_id=user_id,
                    messages=conversation_messages,
                )
                if uri:
                    logger.info(f"Transcript saved: {uri}")
            except Exception as exc:
                logger.error(f"Failed to save transcript: {exc}", exc_info=True)




# ---------------------------------------------------------------------------
# Local dev entry point
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    import uvicorn

    uvicorn.run(
        "main:app",
        host=config.HOST,
        port=config.PORT,
        reload=True,
        log_level="info",
    )
