#!/bin/bash

URI="https://logic-apim-tester-atayafcuddbeb3dt.australiaeast-01.azurewebsites.net:443/api/SaveAPIMTest/triggers/When_an_HTTP_request_is_received/invoke?api-version=2022-05-01&sp=%2Ftriggers%2FWhen_an_HTTP_request_is_received%2Frun&sv=1.0&sig=yMR36BkvU3KBxV_yL8n6CJFewVKE6rKOqvvS8eK5BGI"

# Generate ISO 8601 UTC timestamp
RECEIVED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Construct JSON payload
BODY=$(cat <<EOF
{
  "receivedAt": "${RECEIVED_AT}",
  "source": "Azure-VM",
  "data": {
    "message": "Direct Logic App Test",
    "testId": "TEST-001"
  }
}
EOF
)

# Send POST request
curl -X POST "$URI" \
  -H "Content-Type: application/json" \
  -d "$BODY"
