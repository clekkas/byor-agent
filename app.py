"""
Minimal Microsoft Foundry hosted agent - Responses protocol 2.0.0.

Container contract:
  - Listens on $PORT (default 8088) on 0.0.0.0
  - POST /responses            -> create a response (non-streaming and SSE streaming)
  - GET  /readiness, /liveness -> Foundry hosted-agent health probes
  - GET  /healthz              -> local/Docker health check

Two modes:
  - ECHO mode (default): no model call. Proves the image was pulled from the
    private registry and the container started. Use this for the first deploy.
  - MODEL mode: set AZURE_AI_MODEL_DEPLOYMENT_NAME and the agent relays to that
    deployment through the Foundry project endpoint (FOUNDRY_PROJECT_ENDPOINT,
    injected by the platform) using the agent's own Entra identity.

Knowledge: every knowledge/*.md file bundled in the image is added to the model
instructions, so the agent can answer questions about this project's assets.
Regenerate with scripts/generate-asset-inventory.ps1.
"""

import json
import os
import time
import uuid
from pathlib import Path
from typing import Any, Dict, List, Optional

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse, StreamingResponse

APP_NAME = os.getenv("AGENT_NAME", "private-registry-agent")
PORT = int(os.getenv("PORT", "8088"))
MODEL_DEPLOYMENT = os.getenv("AZURE_AI_MODEL_DEPLOYMENT_NAME")
# Injected by Foundry in hosted containers; set it yourself for local runs.
PROJECT_ENDPOINT = os.getenv("FOUNDRY_PROJECT_ENDPOINT")
KNOWLEDGE_DIR = Path(os.getenv("KNOWLEDGE_DIR", Path(__file__).parent / "knowledge"))
# Small, curated files are fine to send in full; switch to file_search if this grows.
MAX_KNOWLEDGE_CHARS = 60_000


def load_knowledge() -> List[Path]:
    return sorted(KNOWLEDGE_DIR.glob("*.md")) if KNOWLEDGE_DIR.is_dir() else []


def build_instructions(files: List[Path]) -> str:
    base = f"You are {APP_NAME}, a concise assistant."
    if not files:
        return base
    docs = "\n\n".join(
        f'<document name="{f.name}">\n{f.read_text(encoding="utf-8")}\n</document>' for f in files
    )[:MAX_KNOWLEDGE_CHARS]
    return (
        f"{base}\n\n"
        "You also answer questions about this project's assets (Azure, Foundry, Entra ID, "
        "JFrog, GitHub) using the knowledge base below. For project-specific facts, rely only "
        "on the knowledge base and say so when something isn't covered. IDs are redacted on "
        "purpose; never guess or invent them. Mention the generation date if asked how current "
        "the information is.\n\n"
        f"<knowledge_base>\n{docs}\n</knowledge_base>"
    )


KNOWLEDGE_FILES = load_knowledge()
INSTRUCTIONS = build_instructions(KNOWLEDGE_FILES)

app = FastAPI(title=APP_NAME)

_client = None


def get_model_client():
    """Lazily build an OpenAI client for the project endpoint using the agent's Entra identity.

    The hosted-agent identity can call models through the project endpoint by default, so no
    extra role assignment is needed (the identity is platform-managed and can change).
    """
    global _client
    if _client is not None:
        return _client
    if not (MODEL_DEPLOYMENT and PROJECT_ENDPOINT):
        return None
    from azure.identity import DefaultAzureCredential, get_bearer_token_provider
    from openai import OpenAI

    _client = OpenAI(
        base_url=f"{PROJECT_ENDPOINT.rstrip('/')}/openai/v1",
        api_key=get_bearer_token_provider(DefaultAzureCredential(), "https://ai.azure.com/.default"),
    )
    return _client


def flatten_input(payload: Dict[str, Any]) -> str:
    """Accept either input='text' or input=[{role, content:[{type,text}]}]."""
    raw = payload.get("input", "")
    if isinstance(raw, str):
        return raw
    parts: List[str] = []
    if isinstance(raw, list):
        for item in raw:
            if isinstance(item, str):
                parts.append(item)
                continue
            content = item.get("content") if isinstance(item, dict) else None
            if isinstance(content, str):
                parts.append(content)
            elif isinstance(content, list):
                for block in content:
                    if isinstance(block, dict) and block.get("text"):
                        parts.append(block["text"])
    return "\n".join(p for p in parts if p).strip()


def answer(prompt: str) -> str:
    client = get_model_client()
    if client is None:
        return (
            f"[{APP_NAME}] Hosted agent is running from a private registry image. "
            f"Echo mode (no model deployment configured). You said: {prompt!r}"
        )
    # Reasoning models (gpt-5 family) reject legacy sampling parameters, so none are sent.
    result = client.responses.create(model=MODEL_DEPLOYMENT, instructions=INSTRUCTIONS, input=prompt)
    return result.output_text or ""


def envelope(text: str, response_id: str, status: str = "completed") -> Dict[str, Any]:
    """Responses-shaped payload: output[] + the output_text convenience field."""
    return {
        "id": response_id,
        "object": "response",
        "created_at": int(time.time()),
        "status": status,
        "model": MODEL_DEPLOYMENT or "echo",
        "output": [
            {
                "id": f"msg_{uuid.uuid4().hex[:16]}",
                "type": "message",
                "role": "assistant",
                "status": "completed",
                "content": [{"type": "output_text", "text": text, "annotations": []}],
            }
        ],
        "output_text": text,
    }


@app.get("/healthz")
@app.get("/readiness")
@app.get("/liveness")
def healthz():
    return {
        "status": "ok",
        "agent": APP_NAME,
        "mode": "model" if MODEL_DEPLOYMENT else "echo",
        "knowledge": [f.name for f in KNOWLEDGE_FILES],
    }


@app.post("/responses")
async def create_response(request: Request):
    payload: Dict[str, Any] = await request.json()
    prompt = flatten_input(payload)
    response_id = f"resp_{uuid.uuid4().hex[:24]}"

    try:
        text = answer(prompt)
    except Exception as exc:  # surface failures as a protocol error, not a 500 wall
        return JSONResponse(
            status_code=200,
            content={
                "id": response_id,
                "object": "response",
                "status": "failed",
                "error": {"code": "agent_error", "message": str(exc)},
            },
        )

    if not payload.get("stream"):
        return JSONResponse(content=envelope(text, response_id))

    def sse():
        created = envelope(text, response_id, status="in_progress")
        yield f"event: response.created\ndata: {json.dumps(created)}\n\n"
        yield (
            "event: response.output_text.delta\n"
            f"data: {json.dumps({'type': 'response.output_text.delta', 'delta': text})}\n\n"
        )
        done = envelope(text, response_id)
        yield f"event: response.completed\ndata: {json.dumps({'type': 'response.completed', 'response': done})}\n\n"

    return StreamingResponse(sse(), media_type="text/event-stream")


# Some hosts probe the versioned path; keep an alias so either works.
@app.post("/v1/responses")
async def create_response_v1(request: Request):
    return await create_response(request)


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(app, host="0.0.0.0", port=PORT)
