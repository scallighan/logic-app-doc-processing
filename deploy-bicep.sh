#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BICEP_DIR="${SCRIPT_DIR}/bicep"
PARAMS_FILE="${BICEP_DIR}/main.parameters.json"

# ─── Validate prerequisites ──────────────────────────────────────────────────
if ! command -v az &>/dev/null; then
  echo "ERROR: Azure CLI (az) is not installed or not in PATH."
  exit 1
fi

if [ ! -f "$PARAMS_FILE" ]; then
  echo "ERROR: Parameters file not found at ${PARAMS_FILE}"
  echo "Copy bicep/main.parameters.sample.json to bicep/main.parameters.json and fill in the values."
  exit 1
fi

# ─── Read location from parameters file for the deployment location ──────────
LOCATION=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['parameters']['location']['value'])" "$PARAMS_FILE" 2>/dev/null || echo "EastUS2")

# ─── Set subscription ────────────────────────────────────────────────────────
SUBSCRIPTION_ID=$(az account show --query id -o tsv)
echo "Using subscription: ${SUBSCRIPTION_ID}"

# ─── Deploy ───────────────────────────────────────────────────────────────────
DEPLOYMENT_NAME="logic-app-doc-processing-$(date +%Y%m%d%H%M%S)"

echo ""
echo "Deploying Bicep template..."
echo "  Location:      ${LOCATION}"
echo "  Parameters:    ${PARAMS_FILE}"
echo "  Deployment:    ${DEPLOYMENT_NAME}"
echo ""

az deployment sub create \
  --name "$DEPLOYMENT_NAME" \
  --location "$LOCATION" \
  --template-file "${BICEP_DIR}/main.bicep" \
  --parameters "@${PARAMS_FILE}" \
  --output table

echo ""
echo "Deployment complete!"

# ─── Print outputs ────────────────────────────────────────────────────────────
echo ""
echo "=== Deployment Outputs ==="
az deployment sub show \
  --name "$DEPLOYMENT_NAME" \
  --query "properties.outputs.{resourceGroupName:resourceGroupName.value, logicAppName:logicAppName.value, logicAppResourceId:logicAppResourceId.value}" \
  --output table 2>/dev/null || \
az deployment sub show \
  --name "$DEPLOYMENT_NAME" \
  --query "properties.outputs" \
  --output json 2>/dev/null || true
