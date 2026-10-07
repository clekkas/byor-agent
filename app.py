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
  - MODEL mode: set AZURE_AI_MODEL_DEPLOYMENT_NAME and AZURE_OPENAI_ENDPOINT and
    the agent relays to that deployment using the runtime managed identity.
"""

import json
import os
import time
import uuid
from typing import Any, Dict, List, Optional

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse, StreamingResponse

APP_NAME = os.getenv("AGENT_NAME", "private-registry-agent")
PORT = int(os.getenv("PORT", "8088"))
MODEL_DEPLOYMENT = os.getenv("AZURE_AI_MODEL_DEPLOYMENT_NAME")
AOAI_ENDPOINT = os.getenv("AZURE_OPENAI_ENDPOINT")
# Override if your deployment needs a different API version.
AOAI_API_VERSION = os.getenv("AZURE_OPENAI_API_VERSION", "2025-04-01-preview")

app = FastAPI(title=APP_NAME)

_client = None


def get_model_client():
    """Lazily build an Azure OpenAI client using the container's managed identity."""
    global _client
    if _client is not None:
        return _client
    if not (MODEL_DEPLOYMENT and AOAI_ENDPOINT):
        return None
    from azure.identity import DefaultAzureCredential, get_bearer_token_provider
    from openai import AzureOpenAI

    token_provider = get_bearer_token_provider(
        DefaultAzureCredential(),
        "https://cognitiveservices.azure.com/.default",
    )
    _client = AzureOpenAI(
        azure_endpoint=AOAI_ENDPOINT,
        azure_ad_token_provider=token_provider,
        api_version=AOAI_API_VERSION,
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
    messages = [
        {"role": "system", "content": f"You are {APP_NAME}, a concise assistant."},
        {"role": "user", "content": prompt},
    ]
    # Reasoning models (gpt-5 family) reject some legacy sampling parameters, so we
    # send none of them. Only the deployment name and the messages are required.
    result = client.chat.completions.create(model=MODEL_DEPLOYMENT, messages=messages)
    return result.choices[0].message.content or ""


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
    return {"status": "ok", "agent": APP_NAME, "mode": "model" if MODEL_DEPLOYMENT else "echo"}


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
