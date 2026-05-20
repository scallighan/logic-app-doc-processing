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

# ─── Determine resource group name ───────────────────────────────────────────
# Try to get it from the latest deployment outputs first
DEPLOYMENT_NAME=$(az deployment sub list \
  --query "[?starts_with(name, 'logic-app-doc-processing-')] | sort_by(@, &properties.timestamp) | [-1].name" \
  --output tsv 2>/dev/null)

RESOURCE_GROUP=""
OUTPUTS=""
if [ -n "$DEPLOYMENT_NAME" ] && [ "$DEPLOYMENT_NAME" != "None" ]; then
  OUTPUTS=$(az deployment sub show \
    --name "$DEPLOYMENT_NAME" \
    --query "properties.outputs" \
    --output json 2>/dev/null || echo "{}")
  RESOURCE_GROUP=$(echo "$OUTPUTS" | python3 -c "import sys,json; print(json.load(sys.stdin).get('resourceGroupName',{}).get('value',''))" 2>/dev/null || echo "")
fi

if [ -z "$RESOURCE_GROUP" ] || [ "$RESOURCE_GROUP" = "None" ]; then
  echo "ERROR: Could not determine resource group from deployment outputs."
  echo "No Bicep deployment found to tear down."
  exit 1
fi

# Try to get resource names for purging
KV_NAME=$(echo "$OUTPUTS" | python3 -c "
import sys,json
o = json.load(sys.stdin)
# Key vault name follows pattern kv-<funcName>
la_name = o.get('logicAppName',{}).get('value','')
if la_name.startswith('la'):
    print('kv-' + la_name[2:])
else:
    print('')
" 2>/dev/null || echo "")

COG_NAME=$(echo "$OUTPUTS" | python3 -c "
import sys,json
o = json.load(sys.stdin)
print(o.get('formRecognizerName',{}).get('value',''))
" 2>/dev/null || echo "")

LOCATION=$(az group show --name "$RESOURCE_GROUP" --query location --output tsv 2>/dev/null || echo "")

echo "=== Bicep Teardown ==="
echo "Resource Group:  $RESOURCE_GROUP"
echo "Location:        $LOCATION"
[ -n "$KV_NAME" ] && echo "Key Vault:       $KV_NAME"
[ -n "$COG_NAME" ] && echo "Cognitive Acct:  $COG_NAME"
echo ""

# ─── Confirm ─────────────────────────────────────────────────────────────────
read -p "Are you sure you want to delete resource group '$RESOURCE_GROUP' and all its resources? [y/N] " -n 1 -r
echo ""
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
  echo "Aborted."
  exit 0
fi

# ─── Delete resource group ────────────────────────────────────────────────────
echo ""
echo "Deleting resource group '$RESOURCE_GROUP'..."
az group delete \
  --name "$RESOURCE_GROUP" \
  --yes

echo "Resource group deleted."

# ─── Clean up subscription-scoped role assignments ────────────────────────────
echo ""
echo "Cleaning up subscription-scoped role assignments..."
UAI_PRINCIPAL_ID=$(echo "$OUTPUTS" | python3 -c "
import sys,json
o = json.load(sys.stdin)
print(o.get('userAssignedIdentityPrincipalId',{}).get('value',''))
" 2>/dev/null || echo "")

if [ -n "$UAI_PRINCIPAL_ID" ]; then
  STALE_ASSIGNMENTS=$(az role assignment list \
    --assignee "$UAI_PRINCIPAL_ID" \
    --scope "/subscriptions/$(az account show --query id -o tsv)" \
    --query "[].id" --output tsv 2>/dev/null || echo "")
  for assignment_id in $STALE_ASSIGNMENTS; do
    echo "  Deleting role assignment: $assignment_id"
    az role assignment delete --ids "$assignment_id" 2>/dev/null || true
  done
  [ -z "$STALE_ASSIGNMENTS" ] && echo "  No stale role assignments found."
else
  echo "  Could not determine UAI principal ID, skipping."
fi

# ─── Purge soft-deleted Key Vault ─────────────────────────────────────────────
if [ -n "$KV_NAME" ] && [ -n "$LOCATION" ]; then
  echo ""
  echo "Purging soft-deleted Key Vault '$KV_NAME'..."
  az keyvault purge --name "$KV_NAME" --location "$LOCATION" 2>/dev/null && echo "  Key Vault purged." || echo "  Key Vault not found in soft-deleted state (already purged or retention expired)."
fi

# ─── Purge soft-deleted Cognitive Services account ────────────────────────────
if [ -n "$COG_NAME" ] && [ -n "$LOCATION" ]; then
  echo ""
  echo "Purging soft-deleted Cognitive Services account '$COG_NAME'..."
  az cognitiveservices account purge \
    --name "$COG_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --location "$LOCATION" 2>/dev/null && echo "  Cognitive Services account purged." || echo "  Cognitive Services account not found in soft-deleted state (already purged or retention expired)."
fi

# ─── Clean up subscription-level deployments ──────────────────────────────────
echo ""
echo "Cleaning up subscription-level deployment records..."
DEPLOYMENTS=$(az deployment sub list \
  --query "[?starts_with(name, 'logic-app-doc-processing-')].name" \
  --output tsv 2>/dev/null)

for dep in $DEPLOYMENTS; do
  echo "  Deleting deployment: $dep"
  az deployment sub delete --name "$dep" --no-wait 2>/dev/null || true
done

echo ""
echo "Teardown complete!"
