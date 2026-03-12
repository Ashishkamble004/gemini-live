"""Cloud Storage utilities for saving session transcripts.

Handles saving conversation transcripts as JSON to GCS.
Bucket name is read from config.py (GCS_RECORDINGS_BUCKET).
"""

import asyncio
import json
import logging
from datetime import datetime, timezone
from typing import List, Dict, Any, Optional

from google.cloud import storage

from config import GCS_RECORDINGS_BUCKET

logger = logging.getLogger(__name__)

BUCKET_NAME = GCS_RECORDINGS_BUCKET


def get_storage_client():
    """Get a Cloud Storage client."""
    return storage.Client()


def get_timestamp_prefix() -> str:
    """Generate a timestamp-based prefix for filenames."""
    return datetime.now(timezone.utc).strftime("%Y%m%d_%H%M%S")


async def save_transcript(
    session_id: str,
    user_id: str,
    messages: List[Dict[str, Any]],
) -> Optional[str]:
    """Save call transcript to Cloud Storage as JSON.

    Args:
        session_id: The session identifier.
        user_id: The user / caller identifier.
        messages: List of conversation messages with role, text, timestamp.

    Returns:
        The GCS URI of the saved transcript, or None if the save failed.
    """
    try:
        client = get_storage_client()
        bucket = client.bucket(BUCKET_NAME)

        timestamp = get_timestamp_prefix()
        filename = f"transcripts/{timestamp}_{user_id}_{session_id}.json"

        transcript_data = {
            "metadata": {
                "session_id": session_id,
                "user_id": user_id,
                "timestamp": datetime.now(timezone.utc).isoformat(),
                "total_messages": len(messages),
            },
            "conversation": messages,
        }

        json_content = json.dumps(transcript_data, indent=2, ensure_ascii=False)

        blob = bucket.blob(filename)
        # Run the blocking GCS upload in a thread so the event loop is not stalled.
        loop = asyncio.get_event_loop()
        await loop.run_in_executor(
            None,
            lambda: blob.upload_from_string(json_content, content_type="application/json"),
        )

        gcs_uri = f"gs://{BUCKET_NAME}/{filename}"
        logger.info(f"Transcript saved to: {gcs_uri}")
        return gcs_uri

    except Exception as exc:
        logger.error(f"Error saving transcript: {exc}", exc_info=True)
        return None
