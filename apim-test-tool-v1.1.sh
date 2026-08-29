#!/usr/bin/env bash
#
# ================================================================
#                       APIM TEST TOOL
#        Azure API Management Private Connectivity Validator
# ================================================================
#
# Version: 1.1.0
#
# Tests:
#   - Logic App HTTP trigger
#   - Function App operation (/api/test by default)
#   - APIM operation (/debug/api/test by default)
#   - DNS / Private Endpoint resolution for APIM, Function,
#     Logic App and Storage Blob
#
# Notes:
#   - Enter BASE URLs for Function App and APIM.
#   - The tool appends the operation paths automatically.
#   - Logic App requires its complete trigger/callback URL.
#

set -u

VERSION="1.1.0"

# ---------------------------- Colours ----------------------------

if [[ -t 1 ]]; then
    RED="\033[0;31m"
    GREEN="\033[0;32m"
    YELLOW="\033[1;33m"
    BLUE="\033[0;34m"
    CYAN="\033[0;36m"
    BOLD="\033[1m"
    RESET="\033[0m"
else
    RED=""
    GREEN=""
    YELLOW=""
    BLUE=""
    CYAN=""
    BOLD=""
    RESET=""
fi

PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0

# ---------------------------- Helpers ----------------------------

banner() {
    clear 2>/dev/null || true
    echo -e "${CYAN}${BOLD}"
    echo "============================================================"
    echo "                     APIM TEST TOOL"
    echo "       Azure Private Endpoint Connectivity Validator"
    echo "============================================================"
    echo -e "${RESET}"
    echo "Version: ${VERSION}"
    echo
}

section() {
    echo
    echo -e "${BLUE}${BOLD}------------------------------------------------------------${RESET}"
    echo -e "${BLUE}${BOLD}$1${RESET}"
    echo -e "${BLUE}${BOLD}------------------------------------------------------------${RESET}"
}

pass() {
    PASS_COUNT=$((PASS_COUNT + 1))
    echo -e "${GREEN}[PASS]${RESET} $1"
}

warn() {
    WARN_COUNT=$((WARN_COUNT + 1))
    echo -e "${YELLOW}[WARN]${RESET} $1"
}

fail() {
    FAIL_COUNT=$((FAIL_COUNT + 1))
    echo -e "${RED}[FAIL]${RESET} $1"
}

info() {
    echo -e "${CYAN}[INFO]${RESET} $1"
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

strip_trailing_slash() {
    local value="$1"
    echo "${value%/}"
}

ensure_leading_slash() {
    local value="$1"
    [[ "$value" == /* ]] && echo "$value" || echo "/$value"
}

extract_hostname() {
    local url="$1"
    echo "$url" | sed -E 's#^[a-zA-Z]+://([^/:]+).*#\1#'
}

mask_url() {
    local url="$1"
    echo "$url" | sed -E \
        -e 's/([?&](sig|code|token|key|subscription-key)=)[^&]+/\1***REDACTED***/Ig'
}

is_private_ipv4() {
    local ip="$1"

    [[ "$ip" =~ ^10\. ]] && return 0
    [[ "$ip" =~ ^192\.168\. ]] && return 0

    if [[ "$ip" =~ ^172\.([0-9]+)\. ]]; then
        local second="${BASH_REMATCH[1]}"
        (( second >= 16 && second <= 31 )) && return 0
    fi

    return 1
}

get_ipv4_addresses() {
    local host="$1"

    if command_exists nslookup; then
        nslookup "$host" 2>/dev/null |
            awk '/^Address: / {print $2}' |
            grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' |
            grep -v '^127\.' |
            sort -u
    elif command_exists dig; then
        dig +short "$host" A 2>/dev/null |
            grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' |
            sort -u
    fi
}

get_cname() {
    local host="$1"

    if command_exists dig; then
        dig +short "$host" CNAME 2>/dev/null |
            head -n 1 |
            sed 's/\.$//'
    elif command_exists nslookup; then
        nslookup "$host" 2>/dev/null |
            awk -F'= ' '/canonical name/ {print $2}' |
            head -n 1 |
            sed 's/\.$//'
    fi
}

# ---------------------- Remediation guidance ---------------------

http_remediation() {
    local component="$1"
    local status="$2"

    echo
    echo -e "${YELLOW}${BOLD}Remediation:${RESET}"

    case "$component" in

        "Logic App")
            cat <<'EOF'
  1. Open Logic App Standard > Workflows > Run history.
  2. Inspect the first failed action.
  3. For private Blob Storage, verify the workflow uses:
       Azure Blob Storage > Built-in > Upload blob to storage container
  4. Confirm Content is populated, for example:
       string(triggerBody())
  5. Confirm Logic App VNet Integration is enabled.
  6. Confirm Storage resolves to its Private Endpoint IP.
  7. Check NSG, UDR, Azure Firewall/NVA and TCP 443.
  8. Verify Storage authentication / RBAC.
EOF
            ;;

        "Function App")
            cat <<'EOF'
  1. Run the Logic App test directly first.
  2. Verify the Function route is /api/test (or your configured route).
  3. Confirm Function App VNet Integration is enabled.
  4. Confirm the Logic App hostname resolves to its Private Endpoint.
  5. Verify LOGIC_APP_URL exists and has no surrounding quotation marks.
  6. Confirm the Logic App Private Endpoint connection is Approved.
  7. Review Function logs / Application Insights.
  8. Check NSG, UDR, Azure Firewall/NVA and TCP 443.
EOF
            ;;

        "API Management")
            cat <<'EOF'
  1. Run the Function App test directly first.
  2. Verify the APIM API suffix and operation path.
  3. Confirm APIM outbound VNet Integration is enabled.
  4. Confirm the Function hostname resolves to its Private Endpoint.
  5. Verify the APIM backend URL points to the Function App base URL.
  6. Check APIM policies, especially rewrite-uri and set-backend-service.
  7. Use APIM Test Console > Trace.
  8. Check NSG, UDR, Azure Firewall/NVA and TCP 443.
EOF
            ;;
    esac

    case "$status" in
        401|403)
            echo "  9. HTTP ${status}: check authentication, subscription key, access restrictions and authorization."
            ;;
        404)
            echo "  9. HTTP 404: verify the complete operation URL/path; this is usually a routing mismatch."
            ;;
        408|504)
            echo "  9. HTTP ${status}: investigate DNS, routing, firewall/NVA and backend timeout."
            ;;
        500|502|503)
            echo "  9. HTTP ${status}: test each downstream component independently to isolate the failing hop."
            ;;
    esac
}

dns_remediation() {
    local label="$1"
    local expected_zone="$2"

    echo
    echo -e "${YELLOW}${BOLD}DNS remediation:${RESET}"
    echo "  1. Confirm the ${label} Private Endpoint exists and is Approved."
    echo "  2. Confirm an A record exists in ${expected_zone}."
    echo "  3. Confirm the client/workload DNS path can resolve that private zone."
    echo "  4. In hub-and-spoke, check Azure DNS Private Resolver/custom DNS forwarding."
    echo "  5. Verify VNet peering and DNS reachability."
    echo "  6. Check NSGs/UDRs/firewall rules if the resolved IP is correct but connection fails."
}

# ------------------------- HTTP testing --------------------------

http_test() {
    local component="$1"
    local url="$2"
    local body="$3"
    local expected_text="$4"

    section "HTTP Test - ${component}"

    info "Endpoint: $(mask_url "$url")"

    local tmp_body
    tmp_body=$(mktemp)

    local http_code
    local curl_rc

    http_code=$(
        curl -sS \
            --connect-timeout 10 \
            --max-time 45 \
            -o "$tmp_body" \
            -w "%{http_code}" \
            -X POST "$url" \
            -H "Content-Type: application/json" \
            -d "$body"
    )
    curl_rc=$?

    if [[ $curl_rc -ne 0 ]]; then
        fail "${component}: curl failed (exit code ${curl_rc})."
        http_remediation "$component" "000"
        rm -f "$tmp_body"
        return 1
    fi

    echo "  HTTP Status: ${http_code}"
    echo "  Response:"
    if [[ -s "$tmp_body" ]]; then
        sed 's/^/    /' "$tmp_body"
    else
        echo "    <empty>"
    fi
    echo

    if [[ ! "$http_code" =~ ^2 ]]; then
        fail "${component} returned HTTP ${http_code}."
        http_remediation "$component" "$http_code"
        rm -f "$tmp_body"
        return 1
    fi

    # Avoid false-positive HTTP 200s such as the Function App landing page.
    if [[ -n "$expected_text" ]] && ! grep -Fqi "$expected_text" "$tmp_body"; then
        fail "${component} returned HTTP ${http_code}, but the expected application response was not found."
        echo
        echo "  Expected response to contain:"
        echo "    ${expected_text}"
        echo
        echo "  This commonly means the BASE URL was called instead of the API operation route."
        http_remediation "$component" "404"
        rm -f "$tmp_body"
        return 1
    fi

    pass "${component} returned the expected HTTP ${http_code} application response."
    rm -f "$tmp_body"
    return 0
}

# -------------------------- DNS testing --------------------------

dns_test() {
    local label="$1"
    local host="$2"
    local expected_zone="$3"

    section "DNS Test - ${label}"

    info "Hostname: ${host}"

    local cname
    local ips

    cname=$(get_cname "$host")
    ips=$(get_ipv4_addresses "$host")

    if [[ -n "$cname" ]]; then
        echo "  CNAME: ${cname}"
    else
        echo "  CNAME: none detected"
    fi

    if [[ -z "$ips" ]]; then
        fail "${label}: no IPv4 address resolved."
        dns_remediation "$label" "$expected_zone"
        return 1
    fi

    echo "  Resolved IPv4 address(es):"
    while IFS= read -r ip; do
        [[ -n "$ip" ]] && echo "    - ${ip}"
    done <<< "$ips"

    local private_found=0

    while IFS= read -r ip; do
        if is_private_ipv4 "$ip"; then
            private_found=1
            break
        fi
    done <<< "$ips"

    if [[ $private_found -eq 1 ]]; then
        pass "${label}: resolves to a private IPv4 address."
    else
        fail "${label}: no RFC1918 private IPv4 address detected."
        dns_remediation "$label" "$expected_zone"
        return 1
    fi

    if [[ -n "$cname" && "$cname" == *"$expected_zone"* ]]; then
        pass "${label}: CNAME uses expected private-link zone '${expected_zone}'."
    else
        warn "${label}: expected private-link CNAME '${expected_zone}' was not detected."
        echo "  This may be valid with custom enterprise DNS, but verify the intended DNS design."
    fi
}

# ============================= Main ==============================

banner

section "Prerequisite Check"

if command_exists curl; then
    pass "curl is installed."
else
    fail "curl is not installed."
    echo "Install: sudo apt-get install curl"
    exit 1
fi

if command_exists nslookup || command_exists dig; then
    pass "DNS lookup utility detected."
else
    fail "Neither nslookup nor dig is installed."
    echo "Install on Ubuntu/Debian:"
    echo "  sudo apt-get install dnsutils"
    exit 1
fi

section "Configuration"

echo "Enter the Logic App FULL trigger URL."
echo
read -r -p "Logic App HTTP trigger URL: " LOGIC_APP_URL

echo
echo "Enter the Function App BASE URL only."
echo "Example:"
echo "  https://func-name.azurewebsites.net"
echo
read -r -p "Function App base URL: " FUNCTION_BASE_URL

read -r -p "Function operation path [/api/test]: " FUNCTION_PATH
FUNCTION_PATH=${FUNCTION_PATH:-/api/test}

echo
echo "Enter the APIM gateway BASE URL only."
echo "Example:"
echo "  https://apim-name.azure-api.net"
echo
read -r -p "APIM gateway base URL: " APIM_BASE_URL

read -r -p "APIM API operation path [/debug/api/test]: " APIM_PATH
APIM_PATH=${APIM_PATH:-/debug/api/test}

echo
read -r -p "Storage account name: " STORAGE_ACCOUNT

read -r -p "Test ID [APIM-TEST-001]: " TEST_ID
TEST_ID=${TEST_ID:-APIM-TEST-001}

FUNCTION_BASE_URL=$(strip_trailing_slash "$FUNCTION_BASE_URL")
APIM_BASE_URL=$(strip_trailing_slash "$APIM_BASE_URL")

FUNCTION_PATH=$(ensure_leading_slash "$FUNCTION_PATH")
APIM_PATH=$(ensure_leading_slash "$APIM_PATH")

FUNCTION_URL="${FUNCTION_BASE_URL}${FUNCTION_PATH}"
APIM_URL="${APIM_BASE_URL}${APIM_PATH}"

LOGIC_HOST=$(extract_hostname "$LOGIC_APP_URL")
FUNCTION_HOST=$(extract_hostname "$FUNCTION_BASE_URL")
APIM_HOST=$(extract_hostname "$APIM_BASE_URL")
STORAGE_HOST="${STORAGE_ACCOUNT}.blob.core.windows.net"

TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

LOGIC_BODY=$(cat <<EOF
{
  "receivedAt": "${TIMESTAMP}",
  "source": "APIM-Test-Tool",
  "data": {
    "message": "Direct Logic App Test",
    "testId": "${TEST_ID}-LOGIC"
  }
}
EOF
)

FUNCTION_BODY=$(cat <<EOF
{
  "message": "Function App Test",
  "source": "APIM-Test-Tool",
  "testId": "${TEST_ID}-FUNCTION"
}
EOF
)

APIM_BODY=$(cat <<EOF
{
  "message": "End-to-End APIM Test",
  "source": "APIM-Test-Tool",
  "testId": "${TEST_ID}-APIM"
}
EOF
)

section "Configuration Summary"

echo "Logic App:"
echo "  $(mask_url "$LOGIC_APP_URL")"
echo
echo "Function App:"
echo "  Base URL : ${FUNCTION_BASE_URL}"
echo "  Path     : ${FUNCTION_PATH}"
echo "  Test URL : ${FUNCTION_URL}"
echo
echo "API Management:"
echo "  Base URL : ${APIM_BASE_URL}"
echo "  Path     : ${APIM_PATH}"
echo "  Test URL : ${APIM_URL}"
echo
echo "Storage:"
echo "  ${STORAGE_ACCOUNT}"
echo
echo "Test ID:"
echo "  ${TEST_ID}"

echo
read -r -p "Start tests? [Y/n]: " CONFIRM
CONFIRM=${CONFIRM:-Y}

if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "Test cancelled."
    exit 0
fi

LOGIC_OK=0
FUNCTION_OK=0
APIM_OK=0

# Expected application content prevents base-page HTTP 200 false positives.
http_test \
    "Logic App" \
    "$LOGIC_APP_URL" \
    "$LOGIC_BODY" \
    '"status":"saved"' && LOGIC_OK=1

http_test \
    "Function App" \
    "$FUNCTION_URL" \
    "$FUNCTION_BODY" \
    '"status": "success"' && FUNCTION_OK=1

http_test \
    "API Management" \
    "$APIM_URL" \
    "$APIM_BODY" \
    '"status": "success"' && APIM_OK=1

dns_test \
    "API Management" \
    "$APIM_HOST" \
    "privatelink.azure-api.net"

dns_test \
    "Function App" \
    "$FUNCTION_HOST" \
    "privatelink.azurewebsites.net"

dns_test \
    "Logic App" \
    "$LOGIC_HOST" \
    "privatelink.azurewebsites.net"

dns_test \
    "Storage Blob" \
    "$STORAGE_HOST" \
    "privatelink.blob.core.windows.net"

section "Fault Isolation"

if [[ $LOGIC_OK -eq 0 ]]; then
    echo -e "${RED}${BOLD}Likely failing hop: Logic App → Storage${RESET}"
    echo
    echo "Prioritize:"
    echo "  - Logic App Run History"
    echo "  - Built-in Blob connector"
    echo "  - Blob Content field"
    echo "  - Logic App VNet Integration"
    echo "  - Storage Private Endpoint / DNS"
    echo "  - NSG / UDR / Firewall / NVA"
elif [[ $FUNCTION_OK -eq 0 ]]; then
    echo -e "${RED}${BOLD}Likely failing hop: Function App → Logic App${RESET}"
    echo
    echo "Prioritize:"
    echo "  - Function VNet Integration"
    echo "  - LOGIC_APP_URL"
    echo "  - Logic App Private Endpoint / DNS"
    echo "  - NSG / UDR / Firewall / NVA"
elif [[ $APIM_OK -eq 0 ]]; then
    echo -e "${RED}${BOLD}Likely failing hop: APIM → Function App${RESET}"
    echo
    echo "Prioritize:"
    echo "  - APIM operation path"
    echo "  - APIM backend URL"
    echo "  - APIM VNet Integration"
    echo "  - Function Private Endpoint / DNS"
    echo "  - APIM policies"
    echo "  - NSG / UDR / Firewall / NVA"
else
    echo -e "${GREEN}${BOLD}HTTP application chain is healthy.${RESET}"
fi

section "Test Summary"

echo -e "${GREEN}Passed   : ${PASS_COUNT}${RESET}"
echo -e "${YELLOW}Warnings : ${WARN_COUNT}${RESET}"
echo -e "${RED}Failed   : ${FAIL_COUNT}${RESET}"
echo

if [[ $FAIL_COUNT -eq 0 ]]; then
    echo -e "${GREEN}${BOLD}RESULT: ALL TESTS PASSED${RESET}"
    exit 0
else
    echo -e "${RED}${BOLD}RESULT: TROUBLESHOOTING REQUIRED${RESET}"
    echo "Start with the first failing hop shown above."
    exit 2
fi
