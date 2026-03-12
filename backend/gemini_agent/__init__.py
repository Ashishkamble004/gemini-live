"""Motilal Oswal Contact Center Agent package.

Root agent: gemini-live-2.5-flash-native-audio (voice, Gemini Live API)
Sub-agent:  gemini-2.5-flash with Vertex AI RAG (customer verification)

The sub-agent is invoked as an AgentTool so the root Live-API agent can
delegate identity verification to a cheaper text model.
"""

from .agent import agent

__all__ = ["agent"]
