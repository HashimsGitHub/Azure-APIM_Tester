#!/bin/bash

URI="https://func-apim-tester-egh3dkf8b9a7cqgu.australiaeast-01.azurewebsites.net/api/test"

BODY=$(cat <<EOF
{
  "message": "Function App Test",
  "source": "Azure-VM",
  "testId": "TEST-002"
}
EOF
)

echo "Sending Function App test..."
echo

curl -i -X POST "$URI" \
  -H "Content-Type: application/json" \
  -d "$BODY"

echo
