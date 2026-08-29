import azure.functions as func
import json
import logging
import os
import urllib.request
import urllib.error
from datetime import datetime, timezone

app = func.FunctionApp()


@app.route(
    route="test",
    methods=["POST"],
    auth_level=func.AuthLevel.ANONYMOUS
)
def test(req: func.HttpRequest) -> func.HttpResponse:
    logging.info("APIM test request received.")

    try:
        # Read incoming JSON body
        try:
            request_body = req.get_json()
        except ValueError:
            return func.HttpResponse(
                json.dumps({
                    "status": "error",
                    "message": "Request body must be valid JSON"
                }),
                status_code=400,
                mimetype="application/json"
            )

        # Read Logic App URL from Function App environment variables
        logic_app_url = os.environ.get("LOGIC_APP_URL")

        if not logic_app_url:
            return func.HttpResponse(
                json.dumps({
                    "status": "error",
                    "message": "LOGIC_APP_URL environment variable is not configured"
                }),
                status_code=500,
                mimetype="application/json"
            )

        # Build payload for Logic App
        payload = {
            "receivedAt": datetime.now(timezone.utc).isoformat(),
            "source": "Azure-Function",
            "data": request_body
        }

        data = json.dumps(payload).encode("utf-8")

        # Create HTTP POST request to Logic App
        logic_request = urllib.request.Request(
            logic_app_url,
            data=data,
            headers={
                "Content-Type": "application/json"
            },
            method="POST"
        )

        # Call Logic App
        with urllib.request.urlopen(
            logic_request,
            timeout=30
        ) as response:

            logic_status = response.status
            logic_body = response.read().decode("utf-8")

        # Try to parse Logic App response as JSON
        try:
            logic_response = json.loads(logic_body)
        except json.JSONDecodeError:
            logic_response = logic_body

        return func.HttpResponse(
            json.dumps({
                "status": "success",
                "message": "Request forwarded to Logic App",
                "logicAppStatus": logic_status,
                "logicAppResponse": logic_response,
                "data": request_body
            }),
            status_code=200,
            mimetype="application/json"
        )

    except urllib.error.HTTPError as e:
        logging.exception("Logic App returned an HTTP error.")

        error_body = e.read().decode("utf-8") if e.fp else ""

        return func.HttpResponse(
            json.dumps({
                "status": "error",
                "component": "Logic App",
                "httpStatus": e.code,
                "message": str(e.reason),
                "response": error_body
            }),
            status_code=502,
            mimetype="application/json"
        )

    except urllib.error.URLError as e:
        logging.exception("Unable to connect to Logic App.")

        return func.HttpResponse(
            json.dumps({
                "status": "error",
                "component": "Logic App",
                "message": str(e.reason)
            }),
            status_code=502,
            mimetype="application/json"
        )

    except Exception as e:
        logging.exception("Unexpected Function error.")

        return func.HttpResponse(
            json.dumps({
                "status": "error",
                "message": str(e)
            }),
            status_code=500,
            mimetype="application/json"
        )