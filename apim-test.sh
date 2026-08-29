#!/bin/bash

URI="https://apim-tester.azure-api.net/debug/api/test"

BODY=$(cat <<EOF
{
  "message": "End-to-End APIM Test",
  "source": "Azure-VM",
  "testId": "TEST-004"
}
EOF
)

echo "Sending APIM test..."
echo

curl -i -X POST "$URI" \
  -H "Content-Type: application/json" \
  -d "$BODY"

echo
