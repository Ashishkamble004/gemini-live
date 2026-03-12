"""Audio conversion utilities for Exotel ↔ Gemini Live API bridging.

Exotel media stream (inbound):
  - Format: PCM 16-bit LE, 16kHz, mono
  - Already the correct rate for Gemini — no conversion needed.

Gemini Live API output:
  - Format: PCM 16-bit LE, 24kHz, mono
  - Must be downsampled to 16kHz before sending back to Exotel.

Uses numpy for resampling (compatible with Python 3.11+, including 3.13+
where stdlib audioop was removed).

All functions accept and return resample state so callers keep their own
per-session state — concurrent calls do not interfere.
"""

from typing import Any, Tuple

import numpy as np


def pcm24khz_to_pcm16khz(
    pcm_24khz: bytes, resample_state: Any = None
) -> Tuple[bytes, Any]:
    """Downsample 16-bit PCM from 24kHz to 16kHz using linear interpolation.

    Stateful: resample_state carries leftover bytes and the fractional
    input offset so there are no discontinuities at chunk boundaries.

    Args:
        pcm_24khz: 16-bit little-endian PCM audio at 24kHz.
        resample_state: (leftover_bytes, in_offset) from the previous call,
                        or None to reset state.

    Returns:
        (pcm_16kHz_bytes, new_resample_state)
    """
    if not pcm_24khz:
        return b"", resample_state

    # Unpack state: leftover = partial sample bytes, in_offset = fractional
    # position (in input samples) where the next output sample will land.
    if resample_state is None:
        leftover: bytes = b""
        in_offset: float = 0.0
    else:
        leftover, in_offset = resample_state

    # Prepend any leftover bytes, then align to 2-byte (int16) boundary.
    data = leftover + pcm_24khz
    n_aligned = (len(data) // 2) * 2
    new_leftover = data[n_aligned:]
    data = data[:n_aligned]

    n_in = n_aligned // 2
    if n_in == 0:
        return b"", (new_leftover, in_offset)

    samples_in = np.frombuffer(data, dtype="<i2").astype(np.float32)
    in_positions = np.arange(n_in, dtype=np.float64)

    # input-to-output ratio: 24000/16000 = 1.5 input samples per output sample
    step = 24000.0 / 16000.0

    # How many output samples fit entirely within [0, n_in - 1]?
    n_out = max(0, int((n_in - 1 - in_offset) / step) + 1)
    if n_out == 0:
        # Not enough data; shift offset and wait for the next chunk.
        return b"", (new_leftover, in_offset - n_in)

    out_positions = in_offset + np.arange(n_out, dtype=np.float64) * step
    out_positions = np.clip(out_positions, 0.0, n_in - 1)

    samples_out = np.interp(out_positions, in_positions, samples_in)
    pcm_out = np.clip(np.round(samples_out), -32768, 32767).astype("<i2").tobytes()

    # Next output sample's position relative to the start of the next input chunk.
    next_in_pos = out_positions[-1] + step
    new_in_offset = next_in_pos - n_in

    return pcm_out, (new_leftover, new_in_offset)
