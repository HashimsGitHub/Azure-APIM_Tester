# Azure API Management Private Endpoint Test & Troubleshooting Runbook

<img width="732" height="406" alt="image" src="https://github.com/user-attachments/assets/b973b48c-37a7-425e-95e9-3a1a28c3a18b" />
<img width="1170" height="927" alt="image" src="https://github.com/user-attachments/assets/cdac7df4-c53a-44a8-ba6d-742d31cf657f" />

## Purpose

This runbook documents a complete, minimal Azure API Management test environment used to reproduce and troubleshoot private networking issues across:

```text
Azure VM
   ↓
API Management
   ↓
Azure Function App
   ↓
Logic App Standard
   ↓
Azure Storage Account
```

The environment is intentionally simple so that each hop can be tested independently.

The final production-like design uses:

```text
Azure VM
   ↓
APIM Private Endpoint
   ↓
APIM VNet Integration
   ↓
Function App Private Endpoint
   ↓
Function App VNet Integration
   ↓
Logic App Private Endpoint
   ↓
Logic App VNet Integration
   ↓
Storage Blob Private Endpoint
```

Public network access can be disabled after all private paths have been verified.

---

# 1. Known-Good Resource Design

## Resource Group

```text
rg-apim-tester
```

## Main Resources

| Resource | Example Name | Recommended Type |
|---|---|---|
| API Management | `apim-tester` | Standard v2 |
| Function App | `func-apim-tester-...` | Python 3.12 / Flex Consumption |
| Logic App | `logic-apim-tester-...` | Standard |
| Storage Account | `stapimtest12345` | StorageV2 / Standard / LRS |
| Blob Container | `apim-test` | Private |
| VNet | `vnet-apim-tester` | Dedicated test VNet |
| Test VM | Existing VM | Located in another VNet |

---

# 2. Final Network Layout

Example VNet:

```text
vnet-apim-tester
10.50.0.0/16
```

Recommended subnets:

```text
snet-apim-integration        10.50.1.0/24
snet-function-integration    10.50.2.0/24
snet-logic-integration       10.50.3.0/24
snet-private-endpoints       10.50.4.0/24
```

Do not place service VNet Integration and Private Endpoints in the same subnet.

Example final Private Endpoint IP allocation observed in the lab:

```text
Storage PE       10.50.4.4
Logic App PE     10.50.4.5
Function PE      10.50.4.6
APIM PE          10.50.4.7
```

Your actual addresses will differ.

---

# 3. Deployment Sequence

Build and validate the environment in this order:

```text
1. Resource Group
2. Storage Account
3. Blob Container
4. Logic App Standard
5. Logic App direct test
6. Function App
7. Function direct test
8. API Management
9. APIM Portal test
10. VM → APIM test
11. Create VNet and subnets
12. Peer VM VNet with backend VNet
13. Enable APIM VNet Integration
14. Enable Function VNet Integration
15. Enable Logic App VNet Integration
16. Create Storage Private Endpoint
17. Create Logic App Private Endpoint
18. Create Function Private Endpoint
19. Create APIM Private Endpoint
20. Validate Private DNS
21. Disable public access one service at a time
```

Do not disable public access until the private path has been confirmed.

---

# 4. Storage Account Deployment

Create a standard StorageV2 account.

Example:

```text
Storage Account:
stapimtest12345

Performance:
Standard

Redundancy:
LRS

Public network access during initial deployment:
Enabled from all networks
```

Create Blob container:

```text
apim-test
```

Anonymous access:

```text
Private
```

---

# 5. Logic App Standard Deployment

Create:

```text
Logic App Type:
Standard

Workflow:
Stateful

Workflow Name:
SaveAPIMTest
```

A stateful workflow is useful because run history is retained for troubleshooting.

---

# 6. Logic App HTTP Trigger

Use the built-in trigger:

```text
When an HTTP request is received
```

Method:

```text
POST
```

Request body schema:

```json
{
  "type": "object",
  "properties": {
    "receivedAt": {
      "type": "string"
    },
    "source": {
      "type": "string"
    },
    "data": {
      "type": "object"
    }
  }
}
```

Do not add required properties during initial troubleshooting.

---

# 7. Logic App Blob Action

## Important Private Endpoint Requirement

For a Logic App Standard workflow that must access a Storage Account through a Private Endpoint, use the **Built-in Azure Blob Storage connector**.

Use:

```text
Azure Blob Storage
→ Built-in
→ Upload blob to storage container
```

Avoid relying on the managed/shared connector action:

```text
Create blob (V2)
```

when the Storage Account has public network access disabled.

The managed connector commonly appears in workflow code as:

```json
"type": "ApiConnection"
```

and:

```json
"referenceName": "azureblob-1"
```

The built-in connector runs with the Logic App Standard runtime and can use the Logic App VNet Integration path.

## Built-in Blob Settings

Container:

```text
apim-test
```

Blob name:

```text
atest-@{formatDateTime(utcNow(),'yyyyMMdd-HHmmss-fff')}.json
```

Content:

```text
string(triggerBody())
```

This is critical.

If `Content` is empty, the action can fail with:

```text
ServiceProviderActionFailed
ServiceOperationRequiredParameterMissing
The required value for parameter 'content' is missing
```

That error is a workflow configuration error, not a network failure.

---

# 8. Logic App Response Action

Add:

```text
Response
```

Status:

```text
200
```

Header:

```text
Content-Type: application/json
```

Body:

```json
{
  "status": "saved",
  "message": "Blob created successfully"
}
```

The final Logic App flow should be:

```text
When an HTTP request is received
        ↓
Upload blob to storage container
        ↓
Response
```

Successful response:

```json
{
  "status": "saved",
  "message": "Blob created successfully"
}
```

---

# 9. Logic App Direct Test Script

Create:

```text
logic-test.sh
```

Use:

```bash
#!/bin/bash

URI="PASTE-YOUR-LOGIC-APP-TRIGGER-URL-HERE"

RECEIVED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

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

curl -i -X POST "$URI" \
  -H "Content-Type: application/json" \
  -d "$BODY"

echo
```

Make executable:

```bash
chmod +x logic-test.sh
```

Run:

```bash
./logic-test.sh
```

Expected:

```text
HTTP/1.1 200 OK
```

and:

```json
{
  "status": "saved",
  "message": "Blob created successfully"
}
```

---

# 10. Function App Deployment

Create a Function App with:

```text
Runtime:
Python 3.12

Hosting:
Flex Consumption

Public access during initial deployment:
Enabled
```

Deploy via manual ZIP upload for a simple troubleshooting environment.

ZIP structure:

```text
function.zip
├── function_app.py
├── requirements.txt
└── host.json
```

Do not place the files inside an additional parent directory.

---

# 11. Function App Environment Variable

Add:

```text
LOGIC_APP_URL
```

Value:

```text
Full Logic App HTTP trigger URL
```

Do not include surrounding quotation marks.

Correct:

```text
https://logic-app-url...?api-version=...&sig=...
```

Incorrect:

```text
"https://logic-app-url..."
```

Treat the Logic App URL as a credential because it contains a signature.

---

# 12. function_app.py

```python
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

        payload = {
            "receivedAt": datetime.now(timezone.utc).isoformat(),
            "source": "Azure-Function",
            "data": request_body
        }

        data = json.dumps(payload).encode("utf-8")

        logic_request = urllib.request.Request(
            logic_app_url,
            data=data,
            headers={
                "Content-Type": "application/json"
            },
            method="POST"
        )

        with urllib.request.urlopen(
            logic_request,
            timeout=30
        ) as response:
            logic_status = response.status
            logic_body = response.read().decode("utf-8")

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
```

---

# 13. requirements.txt

```text
azure-functions
```

---

# 14. host.json

```json
{
  "version": "2.0",
  "logging": {
    "applicationInsights": {
      "samplingSettings": {
        "isEnabled": true,
        "excludedTypes": "Request"
      }
    }
  }
}
```

---

# 15. Function Direct Test Script

Create:

```text
function-test.sh
```

Use:

```bash
#!/bin/bash

URI="https://YOUR-FUNCTION.azurewebsites.net/api/test"

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
```

Expected:

```text
HTTP/1.1 200 OK
```

Example successful body:

```json
{
  "status": "success",
  "message": "Request forwarded to Logic App",
  "logicAppStatus": 200,
  "logicAppResponse": {
    "status": "saved",
    "message": "Blob created successfully"
  },
  "data": {
    "message": "Function App Test",
    "source": "Azure-VM",
    "testId": "TEST-002"
  }
}
```

---

# 16. API Management Deployment

Create:

```text
API Management Tier:
Standard v2
```

Keep public access enabled during initial deployment.

Create a manually defined HTTP API.

Example:

```text
Display Name:
APIM Test API

API URL suffix:
debug
```

Backend Web Service URL:

```text
https://YOUR-FUNCTION.azurewebsites.net
```

Do not add `/api/test` to the backend base URL.

---

# 17. APIM Operation

Create:

```text
Display Name:
Test API

Method:
POST

URL:
/api/test
```

The external APIM endpoint becomes:

```text
https://apim-tester.azure-api.net/debug/api/test
```

Backend becomes:

```text
https://YOUR-FUNCTION.azurewebsites.net/api/test
```

---

# 18. APIM Subscription Setting

For the initial troubleshooting environment:

```text
Subscription required:
OFF
```

This avoids introducing subscription keys while validating network connectivity.

---

# 19. APIM Policy

Keep policy minimal:

```xml
<policies>
    <inbound>
        <base />
    </inbound>
    <backend>
        <base />
    </backend>
    <outbound>
        <base />
    </outbound>
    <on-error>
        <base />
    </on-error>
</policies>
```

Do not initially add:

```text
JWT validation
IP filtering
Managed Identity
Rate limiting
Header transformations
Rewrite policies
Custom error policies
```

---

# 20. APIM Test Script

Create:

```text
apim-test.sh
```

Use:

```bash
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
```

Make executable:

```bash
chmod +x apim-test.sh
```

Run:

```bash
./apim-test.sh
```

Expected:

```text
HTTP/1.1 200 OK
```

Example body:

```json
{
  "status": "success",
  "message": "Request forwarded to Logic App",
  "logicAppStatus": 200,
  "logicAppResponse": {
    "status": "saved",
    "message": "Blob created successfully"
  },
  "data": {
    "message": "End-to-End APIM Test",
    "source": "Azure-VM",
    "testId": "TEST-004"
  }
}
```

---

# 21. VNet Peering

The VM is in a separate Resource Group and VNet.

Peer:

```text
VM VNet
⇄
vnet-apim-tester
```

Verify:

```text
Allow virtual network access:
Enabled
```

Ensure address ranges do not overlap.

---

# 22. APIM VNet Integration

APIM Private Endpoint and APIM VNet Integration serve different purposes.

## APIM Private Endpoint

Used for:

```text
VM → APIM
```

## APIM VNet Integration

Used for:

```text
APIM → Function Private Endpoint
```

Configure APIM outbound VNet Integration:

```text
VNet:
vnet-apim-tester

Subnet:
snet-apim-integration
```

---

# 23. Function VNet Integration

Required for:

```text
Function App → Logic App Private Endpoint
```

Configure:

```text
VNet:
vnet-apim-tester

Subnet:
snet-function-integration
```

---

# 24. Logic App VNet Integration

Required for:

```text
Logic App → Storage Private Endpoint
```

Configure:

```text
VNet:
vnet-apim-tester

Subnet:
snet-logic-integration
```

In the tested working lab configuration:

```text
Application routing
Outbound internet traffic:
Disabled
```

Private Storage access still worked successfully.

Do not assume that enabling outbound internet routing is required for Private Endpoint connectivity.

---

# 25. Storage Private Endpoint

Create:

```text
Private Endpoint:
Storage Account

Subresource:
blob

Subnet:
snet-private-endpoints
```

Expected Private DNS zone:

```text
privatelink.blob.core.windows.net
```

Example validation:

```bash
nslookup stapimtest12345.blob.core.windows.net
```

Expected:

```text
stapimtest12345.blob.core.windows.net
canonical name =
stapimtest12345.privatelink.blob.core.windows.net

Address:
10.50.4.4
```

Also test:

```bash
nslookup stapimtest12345.privatelink.blob.core.windows.net
```

---

# 26. Logic App Private Endpoint

Create the Private Endpoint in:

```text
snet-private-endpoints
```

Expected DNS namespace:

```text
privatelink.azurewebsites.net
```

Validate:

```bash
nslookup logic-apim-tester-....azurewebsites.net
```

Expected:

```text
logic-app.azurewebsites.net
→ logic-app.privatelink.azurewebsites.net
→ 10.50.4.x
```

Then run:

```bash
./logic-test.sh
```

---

# 27. Function App Private Endpoint

Create in:

```text
snet-private-endpoints
```

Expected DNS zone:

```text
privatelink.azurewebsites.net
```

Validate:

```bash
nslookup func-apim-tester-....azurewebsites.net
```

Expected:

```text
function.azurewebsites.net
→ function.privatelink.azurewebsites.net
→ 10.50.4.x
```

Then run:

```bash
./function-test.sh
```

---

# 28. APIM Private Endpoint

Create:

```text
Private Endpoint Subresource:
Gateway
```

Subnet:

```text
snet-private-endpoints
```

Expected Private DNS zone:

```text
privatelink.azure-api.net
```

The Private DNS zone should contain an A record similar to:

```text
apim-tester    A    10.50.4.7
```

First validate the explicit Private Link hostname:

```bash
nslookup apim-tester.privatelink.azure-api.net
```

Expected:

```text
Name:    apim-tester.privatelink.azure-api.net
Address: 10.50.4.7
```

Then validate the normal APIM gateway hostname:

```bash
nslookup apim-tester.azure-api.net
```

The required end state is:

```text
Name:    apim-tester.azure-api.net
Address: 10.50.4.7
```

## Important APIM DNS Diagnostic

A valid `privatelink.azure-api.net` A record does **not** by itself prove that the normal APIM gateway hostname is resolving privately from the workload VM.

In the lab, this condition was observed:

```text
apim-tester.privatelink.azure-api.net
→ 10.50.4.7
```

while:

```text
apim-tester.azure-api.net
→ public Azure CNAME chain
→ 20.211.64.25
```

This meant the Private Endpoint itself was healthy, but the normal APIM gateway hostname was still resolving to the public endpoint.

To prove the Private Endpoint path independently of DNS, run:

```bash
curl -i   --resolve apim-tester.azure-api.net:443:10.50.4.7   -X POST   "https://apim-tester.azure-api.net/debug/api/test"   -H "Content-Type: application/json"   -d '{
    "message": "Private APIM Test",
    "source": "Azure-VM",
    "testId": "TEST-PE"
  }'
```

Successful result:

```text
HTTP/1.1 200 OK
```

with a body similar to:

```json
{
  "status": "success",
  "message": "Request forwarded to Logic App",
  "logicAppStatus": 200,
  "logicAppResponse": {
    "status": "saved",
    "message": "Blob created successfully"
  },
  "data": {
    "message": "Private APIM Test",
    "source": "Azure-VM",
    "testId": "TEST-PE"
  }
}
```

If this test succeeds, then:

```text
VM
→ APIM Private Endpoint
→ Function
→ Logic App
→ Storage
```

is healthy and the remaining issue is DNS for the normal APIM hostname.

After correcting DNS, flush the Ubuntu resolver cache:

```bash
sudo resolvectl flush-caches
```

Then verify again:

```bash
nslookup apim-tester.azure-api.net
```

Known-good lab result:

```text
Name:    apim-tester.azure-api.net
Address: 10.50.4.7
```

Finally run:

```bash
./apim-test.sh
```

The test must succeed without `--resolve`.

---

# 29. Disable Public Access

Only after all Private Endpoint and VNet Integration tests succeed.

Recommended sequence:

```text
1. Storage
2. Logic App
3. Function App
4. API Management
```

After every change:

```bash
./apim-test.sh
```

must still return:

```text
HTTP/1.1 200 OK
```

Do not disable public access for all services at once.

---

# 30. Critical Production Issue Reproduced in Lab

The lab successfully reproduced this failure condition:

```text
Storage Account Public Access:
Disabled
```

Result:

```text
HTTP/1.1 502 Bad Gateway
```

Function response:

```json
{
  "status": "error",
  "component": "Logic App",
  "httpStatus": 502,
  "message": "Bad Gateway",
  "response": "{\"error\":{\"code\":\"NoResponse\",\"message\":\"The server did not receive a response from an upstream server...\"}}"
}
```

Root cause in the test environment:

```text
Logic App was using managed/shared Blob ApiConnection
instead of the built-in Blob connector.
```

The managed connector action looked like:

```json
{
  "type": "ApiConnection",
  "inputs": {
    "host": {
      "connection": {
        "referenceName": "azureblob-1"
      }
    }
  }
}
```

The private-storage-compatible test was implemented using:

```text
Azure Blob Storage
→ Built-in
→ Upload blob to storage container
```

The required `Content` field was:

```text
string(triggerBody())
```

After that change, Storage public network access remained disabled and both:

```bash
./logic-test.sh
```

and:

```bash
./apim-test.sh
```

returned success.

This should be one of the first things checked in Production when a Logic App fails only after Storage public access is disabled.

---

# 31. Fault Isolation Strategy

Use the three scripts independently.

## Test 1 — Logic App

```bash
./logic-test.sh
```

If this fails:

```text
Likely issue:
Logic App → Storage
```

Investigate:

```text
Logic App built-in connector
Storage Private Endpoint
Storage DNS
Logic App VNet Integration
NSG/UDR
Storage RBAC/authentication
Blob action configuration
```

---

## Test 2 — Function App

```bash
./function-test.sh
```

If Logic App succeeds but Function fails:

```text
Likely issue:
Function → Logic App
```

Investigate:

```text
Function VNet Integration
Logic App Private Endpoint
privatelink.azurewebsites.net
Function DNS resolution
NSG/UDR
LOGIC_APP_URL
```

---

## Test 3 — APIM

```bash
./apim-test.sh
```

If Function succeeds but APIM fails:

```text
Likely issue:
APIM → Function
```

Investigate:

```text
APIM VNet Integration
Function Private Endpoint
APIM DNS resolution
APIM backend configuration
NSG/UDR
APIM policy
```

---

# 32. Error Interpretation

## HTTP 502 from APIM

Do not immediately assume APIM is broken.

Example chain:

```text
APIM
  ↓
Function
  ↓
Logic App
  X
Storage
```

APIM can legitimately return 502 because a downstream component returned a failure.

Use direct tests to identify the failing hop.

---

## Logic App `NoResponse`

Example:

```json
{
  "error": {
    "code": "NoResponse",
    "message": "The server did not receive a response from an upstream server."
  }
}
```

Possible causes:

```text
Managed connector unable to reach private Storage
Private DNS failure
VNet Integration failure
NSG/UDR block
Connector backend inaccessible
```

Check Logic App run history.

---

## Built-in Blob `ServiceProviderActionFailed`

Example:

```text
ServiceProviderActionFailed
ServiceOperationRequiredParameterMissing
```

If message says:

```text
required value for parameter 'content' is missing
```

fix:

```text
Content:
string(triggerBody())
```

This is not a networking error.

---

# 33. DNS Troubleshooting

Always test the normal service hostname.

Do not validate only the `privatelink` hostname.

## Storage

```bash
nslookup stapimtest12345.blob.core.windows.net
```

Expected pattern:

```text
normal hostname
→ privatelink CNAME
→ private IP
```

## Logic App

```bash
nslookup <logic-app>.azurewebsites.net
```

## Function

```bash
nslookup <function-app>.azurewebsites.net
```

## APIM

Always test both names:

```bash
nslookup apim-tester.privatelink.azure-api.net
nslookup apim-tester.azure-api.net
```

The explicit Private Link hostname should resolve to the APIM Private Endpoint IP:

```text
apim-tester.privatelink.azure-api.net
→ 10.50.4.7
```

The normal APIM gateway hostname must also ultimately resolve to the private endpoint IP from the workload VM:

```text
apim-tester.azure-api.net
→ 10.50.4.7
```

A failure pattern reproduced in the lab was:

```text
apim-tester.privatelink.azure-api.net
→ 10.50.4.7

apim-tester.azure-api.net
→ public Azure CNAME chain
→ 20.211.64.25
```

In this condition, Private Endpoint DNS exists, but the normal APIM gateway hostname is still using public resolution.

Use the following diagnostic to bypass DNS while preserving the APIM TLS hostname:

```bash
curl -i   --resolve apim-tester.azure-api.net:443:10.50.4.7   -X POST   "https://apim-tester.azure-api.net/debug/api/test"   -H "Content-Type: application/json"   -d '{"message":"Private APIM Test","source":"Azure-VM","testId":"TEST-PE"}'
```

If this succeeds, troubleshoot DNS rather than APIM networking.

---

# 34. Private DNS Zones

Typical zones for this architecture:

```text
privatelink.azure-api.net
privatelink.azurewebsites.net
privatelink.blob.core.windows.net
```

In a small lab environment, Private DNS zones can be linked directly to:

```text
Backend VNet
VM VNet
```

---

# 35. Production Hub-and-Spoke DNS Design

In Production with hundreds of Private DNS Zones, manually linking every zone to every spoke is not recommended.

A centralized model can use:

```text
Spoke VNets
   ↓
Hub DNS
   ↓
Azure DNS Private Resolver
   ↓
Central Private DNS Zones
```

Typical design:

```text
                      Hub VNet
             ┌────────────────────┐
             │ Azure DNS Private  │
             │ Resolver           │
             │                    │
             │ Inbound Endpoint   │
             │ Outbound Endpoint  │
             └─────────┬──────────┘
                       │
       ┌───────────────┼──────────────────┐
       ▼               ▼                  ▼
privatelink.      privatelink.        privatelink.
azure-api.net     azurewebsites.net   blob.core.windows.net
```

Spokes can resolve centrally through the hub instead of creating hundreds of direct VNet links.

---

# 36. Production DNS Questions to Check

If Production differs from the lab, determine:

```text
Is the spoke using Azure-provided DNS?
Is the spoke using custom DNS servers?
Is Azure Firewall DNS Proxy enabled?
Is Azure DNS Private Resolver deployed?
Are conditional forwarders configured?
Are Private DNS Zones linked to the hub?
Can the workload subnet reach the DNS resolver?
Are UDRs forcing traffic through an NVA?
Does the NVA allow DNS and Private Endpoint traffic?
```

---

# 37. NSG Troubleshooting

Check all relevant subnets:

```text
snet-apim-integration
snet-function-integration
snet-logic-integration
snet-private-endpoints
VM subnet
```

Confirm there are no rules blocking required traffic.

For debugging, compare:

```text
Source subnet
Destination private endpoint IP
Destination port 443
```

Example:

```text
Logic App integration subnet
→ 10.50.4.4
→ TCP 443
```

---

# 38. UDR / Route Table Troubleshooting

Check whether any integration subnet has a route table.

Important questions:

```text
Is 0.0.0.0/0 forced through Azure Firewall/NVA?
Is Private Endpoint traffic routed unexpectedly?
Does the NVA have a return path?
Does the firewall allow destination 10.50.4.x:443?
Is asymmetric routing occurring?
```

Use:

```text
Network Watcher
→ Effective routes
```

where appropriate.

---

# 39. Production Storage Checklist

When Storage public network access is disabled:

```text
Private Endpoint exists
Private Endpoint connection approved
Blob subresource selected
Private DNS record exists
DNS resolves to private IP
Logic App VNet Integration is enabled
Logic App uses built-in Blob connector
Authentication is valid
NSG allows path
UDR allows path
```

---

# 40. Logic App Run History Checklist

When a workflow fails:

```text
Logic App
→ Workflows
→ SaveAPIMTest
→ Run history
```

Inspect:

```text
Trigger status
Blob action status
Response status
Inputs
Outputs
Error code
Tracking ID
```

If Blob is red and Response is skipped:

```text
the failure is upstream of the Response action.
```

---

# 41. Function App Troubleshooting Checklist

Check:

```text
LOGIC_APP_URL configured
No quotation marks around value
Function route is /api/test
Authorization is Anonymous for test lab
VNet Integration enabled
Logic App hostname resolves privately
Private Endpoint approved
Application Insights logs
```

Function test:

```bash
./function-test.sh
```

---

# 42. APIM Troubleshooting Checklist

Check:

```text
Backend URL:
https://<function>.azurewebsites.net

Operation:
POST /api/test

External API:
POST /debug/api/test

Subscription required:
Off for test lab

Policy:
Minimal/default

VNet Integration:
Enabled

Private Endpoint:
Gateway subresource

DNS:
apim-tester.privatelink.azure-api.net → APIM Private Endpoint IP
apim-tester.azure-api.net → APIM Private Endpoint IP

If the Private Link hostname resolves privately but the normal APIM hostname resolves publicly, use `curl --resolve` to prove the Private Endpoint path and then fix DNS.

Known-good lab DNS:
apim-tester.azure-api.net → 10.50.4.7
```

APIM Portal test should be used before VM testing.

---

# 43. Public Access Shutdown Checklist

## Storage

```text
Public network access:
Disabled
```

Test:

```bash
./logic-test.sh
./function-test.sh
./apim-test.sh
```

## Logic App

Disable public access.

Test again.

## Function

Disable public access.

Test again.

## APIM

Disable public access.

Test again.

Final result should remain:

```text
HTTP/1.1 200 OK
```

---

# 44. Final Known-Good Test Outputs

## Logic App

```bash
./logic-test.sh
```

Expected:

```json
{
  "status": "saved",
  "message": "Blob created successfully"
}
```

## Function

```bash
./function-test.sh
```

Expected:

```text
HTTP/1.1 200 OK
```

## APIM

```bash
./apim-test.sh
```

Expected:

```text
HTTP/1.1 200 OK
```

Body:

```json
{
  "status": "success",
  "message": "Request forwarded to Logic App",
  "logicAppStatus": 200,
  "logicAppResponse": {
    "status": "saved",
    "message": "Blob created successfully"
  },
  "data": {
    "message": "End-to-End APIM Test",
    "source": "Azure-VM",
    "testId": "TEST-004"
  }
}
```

---

# 45. Fast Production Triage

When Production returns `502 Bad Gateway`, run through this sequence.

```text
1. Can workload resolve `apim-tester.azure-api.net` to the APIM Private Endpoint IP?
2. Can `apim-tester.privatelink.azure-api.net` resolve to the APIM Private Endpoint IP?
3. If only the Private Link hostname resolves privately, does `curl --resolve` succeed?
4. Can APIM reach Function?
5. Can Function reach Logic App?
6. Can Logic App reach Storage?
7. Does Storage resolve to Private Endpoint?
8. Is Logic App using built-in Blob connector?
9. Is Blob action Content populated?
10. Is Logic App VNet Integration enabled?
11. Are NSGs blocking TCP 443?
12. Are UDRs forcing traffic through an NVA?
13. Is custom DNS forwarding correct?
14. Is public Storage access disabled?
15. Does re-enabling Storage public access immediately make it work?
```

If:

```text
Storage public enabled → works
Storage public disabled → fails
```

focus immediately on:

```text
Logic App connector type
Logic App VNet Integration
Storage Private Endpoint
Private DNS
NSG/UDR
Authentication
```

---

# 46. Troubleshooting Decision Tree

```text
APIM Test Fails
    |
    +--> Function direct test succeeds?
          |
          +--> YES
          |     APIM → Function issue
          |
          +--> NO
                |
                +--> Logic App direct test succeeds?
                      |
                      +--> YES
                      |     Function → Logic App issue
                      |
                      +--> NO
                            Logic App → Storage issue
```

For Storage-specific failure:

```text
Logic App → Storage fails
       |
       +--> Storage public access ON works?
              |
              +--> YES
              |     Private path issue
              |
              +--> NO
                    Connector/auth/workflow issue
```

Then check:

```text
Built-in connector?
Private DNS?
VNet Integration?
Private Endpoint?
NSG?
UDR?
RBAC?
Content parameter?
```

---

# 47. Lab Result

The lab successfully demonstrated a fully private end-to-end path:

```text
Azure VM
   ↓
APIM Private Endpoint
   ↓
APIM VNet Integration
   ↓
Function Private Endpoint
   ↓
Function VNet Integration
   ↓
Logic App Private Endpoint
   ↓
Logic App VNet Integration
   ↓
Storage Blob Private Endpoint
```

with public access disabled and successful responses:

```text
Logic App: HTTP 200
Function:  HTTP 200
APIM:      HTTP 200
```

The APIM DNS issue was also isolated and corrected.

Before the DNS fix:

```text
apim-tester.privatelink.azure-api.net → 10.50.4.7
apim-tester.azure-api.net             → 20.211.64.25
```

A forced-resolution test proved the private APIM path:

```bash
curl --resolve apim-tester.azure-api.net:443:10.50.4.7 ...
```

After the DNS fix and cache flush:

```text
apim-tester.azure-api.net → 10.50.4.7
```

The standard `./apim-test.sh` then used the Private Endpoint without any DNS override.

This provides a known-good reference architecture for comparison against Production.
