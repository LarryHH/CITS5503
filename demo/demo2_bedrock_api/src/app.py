import base64
import json
import logging
import os

import boto3


LOGGER = logging.getLogger()
LOGGER.setLevel(logging.INFO)

_bedrock = None


def _client():
    """Create the SDK client once, then reuse it on warm Lambda invocations."""
    global _bedrock
    if _bedrock is None:
        _bedrock = boto3.client("bedrock-runtime")
    return _bedrock


def _response(status_code, body):
    # API Gateway proxy responses require a string body, not a Python dictionary.
    return {
        "statusCode": status_code,
        "headers": {
            "content-type": "application/json",
            "access-control-allow-origin": os.environ.get("ALLOWED_ORIGIN", "*"),
        },
        "body": json.dumps(body),
    }


def _request_body(event):
    raw_body = event.get("body") or "{}"
    # API Gateway may base64-encode request bodies before passing them to Lambda.
    if event.get("isBase64Encoded"):
        raw_body = base64.b64decode(raw_body).decode("utf-8")
    body = json.loads(raw_body)
    if not isinstance(body, dict):
        raise ValueError("The JSON body must be an object")
    return body


def lambda_handler(event, context):
    """Handle an API Gateway request and invoke Bedrock Converse."""
    try:
        body = _request_body(event)
    except (ValueError, TypeError, json.JSONDecodeError, UnicodeDecodeError):
        return _response(400, {"error": "Request body must be a valid JSON object."})

    prompt = str(body.get("prompt", "")).strip()
    if not prompt:
        return _response(400, {"error": "The request requires a non-empty prompt."})

    # Bound input size before calling the paid, external model service.
    max_prompt_chars = int(os.environ.get("MAX_PROMPT_CHARS", "4000"))
    if len(prompt) > max_prompt_chars:
        return _response(
            400,
            {"error": f"The prompt exceeds the {max_prompt_chars} character limit."},
        )

    model_id = os.environ.get("MODEL_ID", "amazon.nova-micro-v1:0")
    try:
        # Converse provides one message format across supported Bedrock models.
        # A low temperature makes classroom demonstrations more repeatable.
        result = _client().converse(
            modelId=model_id,
            messages=[{"role": "user", "content": [{"text": prompt}]}],
            inferenceConfig={"maxTokens": 300, "temperature": 0.3, "topP": 0.9},
        )
        generated_text = result["output"]["message"]["content"][0]["text"]
    except Exception:
        LOGGER.exception("bedrock_invocation_failed model_id=%s", model_id)
        return _response(500, {"error": "The model invocation failed. Check Lambda logs."})

    payload = {"model": model_id, "response": generated_text}
    if "usage" in result:
        payload["usage"] = result["usage"]
    log_details = {
        "model_id": model_id,
        "prompt_chars": len(prompt),
        "usage": result.get("usage", {}),
    }
    # Record operational metadata, but deliberately do not log the prompt text.
    LOGGER.info("bedrock_invocation_complete %s", json.dumps(log_details))
    return _response(200, payload)
