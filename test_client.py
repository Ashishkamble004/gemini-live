#!/usr/bin/env python3
"""Exotel WebSocket test client — simulate a phone call without Exotel.

Mimics the exact Exotel streaming protocol so you can test the backend locally
or against a deployed GKE endpoint without a real Exotel account.

Requirements (already in backend/requirements.txt):
  websockets>=13.0

Optional (for WAV resampling):
  numpy>=1.26.0   — install if your WAV isn't already 16kHz/mono

Usage
-----
# 1. Start the backend first:
#    cd backend && python main.py
#    (needs backend/.env with PROJECT_ID etc.)

# 2. Run the test client in another terminal:

# Just test the connection — listen to Arjun's greeting:
python test_client.py

# Send a WAV file as the caller's voice:
python test_client.py --wav /path/to/question.wav

# Point at a deployed GKE endpoint:
python test_client.py --url wss://your-domain.com/exotel/stream

# Extend greeting silence / response wait:
python test_client.py --wav question.wav --pre-silence 5 --post-silence 15

Protocol simulated
------------------
  → connected
  → start
  → media (audio chunks at real-time pace)
  → stop
  ← media, mark, clear
"""

import argparse
import asyncio
import base64
import json
import os
import struct
import sys
import time
import uuid
import wave
from datetime import datetime
from pathlib import Path

# ---------------------------------------------------------------------------
# Dependency check
# ---------------------------------------------------------------------------

try:
    import websockets
    import websockets.exceptions
except ImportError:
    print("ERROR: websockets not installed.")
    print("  pip install 'websockets>=13.0'")
    sys.exit(1)

# ---------------------------------------------------------------------------
# Audio constants (Exotel telephony spec)
# ---------------------------------------------------------------------------

SAMPLE_RATE = 16_000   # 16kHz
SAMPLE_WIDTH = 2       # 16-bit PCM
CHANNELS = 1           # mono
CHUNK_MS = 20          # 20ms chunks — matches Exotel's default
CHUNK_SAMPLES = int(SAMPLE_RATE * CHUNK_MS / 1000)   # 320 samples
CHUNK_BYTES = CHUNK_SAMPLES * SAMPLE_WIDTH            # 640 bytes


# ---------------------------------------------------------------------------
# Colour helpers (degrade gracefully on Windows without ANSI support)
# ---------------------------------------------------------------------------

_USE_COLOUR = sys.stdout.isatty() and os.name != "nt"

def _c(code: str, text: str) -> str:
    return f"\033[{code}m{text}\033[0m" if _USE_COLOUR else text

def info(msg: str)  -> None: print(_c("36", "[INFO]") + f" {msg}")
def send(msg: str)  -> None: print(_c("33", "[SEND]") + f" {msg}")
def recv(msg: str)  -> None: print(_c("32", "[RECV]") + f" {msg}")
def error(msg: str) -> None: print(_c("31", "[ERROR]") + f" {msg}")


# ---------------------------------------------------------------------------
# WAV → 16kHz mono PCM converter
# ---------------------------------------------------------------------------

def load_wav_as_pcm16k(path: str) -> bytes:
    """Read a WAV file and return raw PCM bytes at 16kHz mono 16-bit."""
    with wave.open(path, "rb") as wf:
        orig_rate = wf.getframerate()
        orig_ch   = wf.getnchannels()
        orig_sw   = wf.getsampwidth()
        n_frames  = wf.getnframes()
        raw       = wf.readframes(n_frames)

    info(f"WAV: {orig_rate} Hz, {orig_ch}-ch, {orig_sw*8}-bit, {n_frames} frames")

    # --- convert to 16-bit if needed ---
    if orig_sw == 1:
        # 8-bit unsigned → 16-bit signed
        samples_u8 = struct.unpack(f"{len(raw)}B", raw)
        samples_s16 = [(s - 128) * 256 for s in samples_u8]
        raw = struct.pack(f"<{len(samples_s16)}h", *samples_s16)
        orig_sw = 2

    if orig_sw != 2:
        error(f"Unsupported sample width: {orig_sw} bytes. Use 16-bit PCM WAV.")
        sys.exit(1)

    # --- downmix stereo → mono ---
    if orig_ch == 2:
        n = len(raw) // 2
        samples = struct.unpack(f"<{n}h", raw)
        mono = [(samples[i] + samples[i + 1]) // 2 for i in range(0, n, 2)]
        raw = struct.pack(f"<{len(mono)}h", *mono)
        info("Stereo → mono downmix done")

    # --- resample to 16kHz if needed ---
    if orig_rate != SAMPLE_RATE:
        try:
            import numpy as np
            src = np.frombuffer(raw, dtype=np.int16).astype(np.float32)
            target_len = int(len(src) * SAMPLE_RATE / orig_rate)
            resampled = np.interp(
                np.linspace(0, len(src) - 1, target_len),
                np.arange(len(src)),
                src,
            ).astype(np.int16)
            raw = resampled.tobytes()
            info(f"Resampled {orig_rate} Hz → {SAMPLE_RATE} Hz")
        except ImportError:
            error("numpy not installed — cannot resample. WAV must be 16kHz.")
            error("  pip install numpy   OR   convert your file first:")
            error("  ffmpeg -i input.wav -ar 16000 -ac 1 input_16k.wav")
            sys.exit(1)

    return raw


def silence_bytes(seconds: float) -> bytes:
    """Return raw PCM silence of the given duration at 16kHz."""
    n_samples = int(SAMPLE_RATE * seconds)
    return b"\x00" * (n_samples * SAMPLE_WIDTH)


# ---------------------------------------------------------------------------
# Main call simulation
# ---------------------------------------------------------------------------

async def simulate_call(
    ws_url: str,
    audio_pcm: bytes,          # caller audio to send (PCM 16kHz mono)
    pre_silence_secs: float,   # silence to send before caller audio
    post_silence_secs: float,  # silence to send after caller audio (wait for response)
    output_path: str,
) -> None:
    stream_sid = f"SS{uuid.uuid4().hex[:20].upper()}"
    call_sid   = f"CA{uuid.uuid4().hex[:20].upper()}"
    caller_number = "+919876543210"
    called_number = "+912269461234"

    received_chunks: list[bytes] = []
    turn_count = 0
    send_done  = asyncio.Event()

    # Build full audio track: pre-silence + caller audio + post-silence
    full_pcm = silence_bytes(pre_silence_secs) + audio_pcm + silence_bytes(post_silence_secs)
    total_chunks = (len(full_pcm) + CHUNK_BYTES - 1) // CHUNK_BYTES
    duration_s   = len(full_pcm) / (SAMPLE_RATE * SAMPLE_WIDTH)

    print()
    info(f"Connecting: {ws_url}")
    info(f"Stream SID: {stream_sid}")
    info(f"Total audio to send: {duration_s:.1f}s  ({total_chunks} chunks × {CHUNK_MS}ms)")
    print()

    async with websockets.connect(
        ws_url,
        ping_interval=20,
        ping_timeout=30,
        open_timeout=15,
    ) as ws:
        info("WebSocket connected")

        # ── 1. connected ──────────────────────────────────────────────────────
        await ws.send(json.dumps({
            "event": "connected",
            "protocol": "Call",
            "version": "1.0.0",
        }))
        send("event=connected")

        # ── 2. start ──────────────────────────────────────────────────────────
        await ws.send(json.dumps({
            "event": "start",
            "streamSid": stream_sid,
            "start": {
                "accountSid": "ACTEST000",
                "streamSid": stream_sid,
                "callSid": call_sid,
                "from": caller_number,
                "to": called_number,
                "tracks": ["inbound"],
            },
        }))
        send(f"event=start  callSid={call_sid}")
        print()

        # ── 3a. sender coroutine ──────────────────────────────────────────────

        async def sender() -> None:
            offset = 0
            sent   = 0
            while offset < len(full_pcm):
                chunk = full_pcm[offset : offset + CHUNK_BYTES]
                if len(chunk) < CHUNK_BYTES:
                    chunk = chunk + b"\x00" * (CHUNK_BYTES - len(chunk))
                offset += CHUNK_BYTES
                sent   += 1

                await ws.send(json.dumps({
                    "event": "media",
                    "streamSid": stream_sid,
                    "media": {
                        "track": "inbound",
                        "chunk": str(sent),
                        "timestamp": str(int(time.time() * 1000)),
                        "payload": base64.b64encode(chunk).decode("ascii"),
                    },
                }))
                # Real-time pacing (20ms per chunk)
                await asyncio.sleep(CHUNK_MS / 1000)

            send(f"audio done — {sent} chunks sent")
            send_done.set()

        # ── 3b. receiver coroutine ────────────────────────────────────────────

        async def receiver() -> None:
            nonlocal turn_count
            last_recv_time = time.monotonic()

            while True:
                # After sending is done, wait up to 10s for remaining responses
                recv_timeout = 10.0 if send_done.is_set() else 35.0
                try:
                    raw = await asyncio.wait_for(ws.recv(), timeout=recv_timeout)
                except asyncio.TimeoutError:
                    if send_done.is_set():
                        info("No more events from server — stopping")
                        break
                    continue
                except websockets.exceptions.ConnectionClosed:
                    info("Server closed the connection")
                    break

                try:
                    data = json.loads(raw)
                except json.JSONDecodeError:
                    error(f"Non-JSON: {raw[:80]}")
                    continue

                last_recv_time = time.monotonic()
                event = data.get("event", "")

                if event == "media":
                    payload = data.get("media", {}).get("payload", "")
                    if payload:
                        chunk_bytes = base64.b64decode(payload)
                        received_chunks.append(chunk_bytes)
                        n = len(received_chunks)
                        # Progress indicator — overwrite same line
                        print(
                            f"\r{_c('32', '[RECV]')} audio chunk {n:4d} "
                            f"| {len(chunk_bytes):5d} B received",
                            end="",
                            flush=True,
                        )

                elif event == "mark":
                    turn_count += 1
                    mark_name = data.get("mark", {}).get("name", "")
                    print()   # newline after progress line
                    recv(f"mark={mark_name}  (turn #{turn_count})")

                elif event == "clear":
                    print()
                    recv("clear — model interrupted (barge-in)")

                else:
                    print()
                    recv(f"unknown event: {event}")

            print()  # final newline

        # ── run sender + receiver concurrently ────────────────────────────────
        await asyncio.gather(sender(), receiver())

        # ── 4. stop ───────────────────────────────────────────────────────────
        await ws.send(json.dumps({
            "event": "stop",
            "streamSid": stream_sid,
            "stop": {
                "accountSid": "ACTEST000",
                "callSid": call_sid,
            },
        }))
        send("event=stop")

    # ── Save response audio ───────────────────────────────────────────────────
    print()
    info(f"Session ended — received {len(received_chunks)} audio chunks, {turn_count} turn(s)")

    if received_chunks:
        raw_out = b"".join(received_chunks)
        with wave.open(output_path, "wb") as wf:
            wf.setnchannels(CHANNELS)
            wf.setsampwidth(SAMPLE_WIDTH)
            wf.setframerate(SAMPLE_RATE)
            wf.writeframes(raw_out)
        duration = len(raw_out) / (SAMPLE_RATE * SAMPLE_WIDTH * CHANNELS)
        info(f"Response saved: {output_path}  ({duration:.1f}s)")
        print()
        info("Play the response:")
        info("  Linux:  aplay -r 16000 -f S16_LE -c 1 " + output_path)
        info("  macOS:  afplay " + output_path)
        info("  ffplay: ffplay -ar 16000 -ac 1 -f s16le " + output_path)
    else:
        info("No audio received — check backend logs for errors.")


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main() -> None:
    parser = argparse.ArgumentParser(
        description="Simulate an Exotel phone call to test the Gemini Live backend.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Listen to Arjun's greeting (no caller audio):
  python test_client.py

  # Send a WAV question after Arjun's greeting:
  python test_client.py --wav question.wav

  # Test against deployed GKE service:
  python test_client.py --url wss://your-domain.com/exotel/stream

  # Record a WAV on Linux/macOS to use as input:
  arecord -r 16000 -f S16_LE -c 1 -d 5 question.wav   # Linux
  rec -r 16000 -e signed -b 16 -c 1 question.wav trim 0 5  # macOS (sox)
        """,
    )
    parser.add_argument(
        "--url",
        default="ws://localhost:8080/exotel/stream",
        metavar="URL",
        help="Backend WebSocket URL (default: ws://localhost:8080/exotel/stream)",
    )
    parser.add_argument(
        "--wav",
        metavar="FILE",
        help="WAV file to send as caller audio (converted to 16kHz mono automatically)",
    )
    parser.add_argument(
        "--pre-silence",
        type=float,
        default=3.0,
        metavar="SECS",
        help="Silence (seconds) before sending WAV — gives Arjun time to greet (default: 3)",
    )
    parser.add_argument(
        "--post-silence",
        type=float,
        default=12.0,
        metavar="SECS",
        help="Silence (seconds) after sending WAV — wait for Arjun's response (default: 12)",
    )
    parser.add_argument(
        "--output",
        default="",
        metavar="FILE",
        help="Output WAV filename (default: output_YYYYMMDD_HHMMSS.wav)",
    )

    args = parser.parse_args()

    # Validate WAV path
    if args.wav:
        if not Path(args.wav).is_file():
            error(f"WAV file not found: {args.wav}")
            sys.exit(1)
        caller_pcm = load_wav_as_pcm16k(args.wav)
    else:
        info("No --wav provided — will send silence and listen for Arjun's greeting")
        # Just a bit of silence for the "caller audio" portion
        caller_pcm = silence_bytes(0)

    output_path = args.output or f"output_{datetime.now().strftime('%Y%m%d_%H%M%S')}.wav"

    try:
        asyncio.run(simulate_call(
            ws_url=args.url,
            audio_pcm=caller_pcm,
            pre_silence_secs=args.pre_silence,
            post_silence_secs=args.post_silence,
            output_path=output_path,
        ))
    except KeyboardInterrupt:
        print()
        info("Interrupted by user")
    except OSError as exc:
        error(f"Connection failed: {exc}")
        error("Is the backend running?  cd backend && python main.py")
        sys.exit(1)


if __name__ == "__main__":
    main()
