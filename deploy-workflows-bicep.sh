#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKFLOWS_DIR="${SCRIPT_DIR}/workflows"
CONNECTIONS_TEMPLATE="${SCRIPT_DIR}/connections.template.json"

if [ ! -d "$WORKFLOWS_DIR" ]; then
  echo "ERROR: Workflows directory not found at $WORKFLOWS_DIR"
  exit 1
fi

WORKFLOW_DIRS=$(find "$WORKFLOWS_DIR" -mindepth 1 -maxdepth 1 -type d)
if [ -z "$WORKFLOW_DIRS" ]; then
  echo "ERROR: No workflow directories found in $WORKFLOWS_DIR"
  exit 1
fi

if [ ! -f "$CONNECTIONS_TEMPLATE" ]; then
  echo "ERROR: connections.template.json not found at $CONNECTIONS_TEMPLATE"
  exit 1
fi

# Extract Logic App name and resource group from the latest Bicep deployment
echo "Reading deployment outputs from Bicep..."

DEPLOYMENT_NAME=$(az deployment sub list \
  --query "[?starts_with(name, 'logic-app-doc-processing-')] | sort_by(@, &properties.timestamp) | [-1].name" \
  --output tsv 2>/dev/null)

if [ -z "$DEPLOYMENT_NAME" ] || [ "$DEPLOYMENT_NAME" = "None" ]; then
  echo "ERROR: Could not find a Bicep deployment. Make sure you have run './deploy-bicep.sh' first."
  exit 1
fi

# Read all outputs in one call
OUTPUTS=$(az deployment sub show --name "$DEPLOYMENT_NAME" --query "properties.outputs" --output json)

LOGICAPP_NAME=$(echo "$OUTPUTS" | python3 -c "import sys,json; print(json.load(sys.stdin)['logicAppName']['value'])")
RESOURCE_GROUP=$(echo "$OUTPUTS" | python3 -c "import sys,json; print(json.load(sys.stdin)['resourceGroupName']['value'])")
SQL_SERVER_FQDN=$(echo "$OUTPUTS" | python3 -c "import sys,json; print(json.load(sys.stdin)['sqlServerFqdn']['value'])")
SQL_DATABASE_NAME=$(echo "$OUTPUTS" | python3 -c "import sys,json; print(json.load(sys.stdin)['sqlDatabaseName']['value'])")
DOC_INTEL_ENDPOINT=$(echo "$OUTPUTS" | python3 -c "import sys,json; print(json.load(sys.stdin)['formRecognizerEndpoint']['value'])")
UAI_CLIENT_ID=$(echo "$OUTPUTS" | python3 -c "import sys,json; print(json.load(sys.stdin)['userAssignedIdentityClientId']['value'])")
UAI_RESOURCE_ID=$(echo "$OUTPUTS" | python3 -c "import sys,json; print(json.load(sys.stdin)['userAssignedIdentityResourceId']['value'])")
OFFICE365_CONNECTION_ID=$(echo "$OUTPUTS" | python3 -c "import sys,json; print(json.load(sys.stdin)['office365ConnectionId']['value'])")
OFFICE365_RUNTIME_URL=$(echo "$OUTPUTS" | python3 -c "import sys,json; print(json.load(sys.stdin)['office365ConnectionRuntimeUrl']['value'])")
SUBSCRIPTION_ID=$(az account show --query id --output tsv)
LOCATION=$(echo "$OUTPUTS" | python3 -c "import sys,json; o=json.load(sys.stdin); print(o.get('location',{}).get('value',''))" 2>/dev/null || echo "")
# Fallback: get location from the resource group
if [ -z "$LOCATION" ]; then
  LOCATION=$(az group show --name "$RESOURCE_GROUP" --query location --output tsv)
fi

echo "Logic App Name:    $LOGICAPP_NAME"
echo "Resource Group:    $RESOURCE_GROUP"

# Generate connections.json from template
echo "Generating connections.json..."
CONNECTIONS_JSON=$(cat "$CONNECTIONS_TEMPLATE" | \
  sed "s|{{SQL_SERVER_FQDN}}|${SQL_SERVER_FQDN}|g" | \
  sed "s|{{SQL_DATABASE_NAME}}|${SQL_DATABASE_NAME}|g" | \
  sed "s|{{UAI_CLIENT_ID}}|${UAI_CLIENT_ID}|g" | \
  sed "s|{{DOC_INTEL_ENDPOINT}}|${DOC_INTEL_ENDPOINT}|g" | \
  sed "s|{{SUBSCRIPTION_ID}}|${SUBSCRIPTION_ID}|g" | \
  sed "s|{{LOCATION}}|${LOCATION}|g" | \
  sed "s|{{OFFICE365_CONNECTION_ID}}|${OFFICE365_CONNECTION_ID}|g" | \
  sed "s|{{OFFICE365_RUNTIME_URL}}|${OFFICE365_RUNTIME_URL}|g")

# Build the deployment package
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

# Add connections.json at the root of the package
echo "$CONNECTIONS_JSON" > "$TEMP_DIR/connections.json"
cp "$TEMP_DIR/connections.json" "$TEMP_DIR/connections-draft.json"

for wf_dir in $WORKFLOW_DIRS; do
  wf_name=$(basename "$wf_dir")
  echo "Packaging workflow: $wf_name"
  mkdir -p "$TEMP_DIR/$wf_name"
  cp "$wf_dir/workflow.json" "$TEMP_DIR/$wf_name/workflow.json"
  if [ -f "$wf_dir/workflow-draft.json" ]; then
    cp "$wf_dir/workflow-draft.json" "$TEMP_DIR/$wf_name/workflow-draft.json"
  fi
done

# Generate .csproj file
CSPROJ_ITEMS=""
for wf_dir in $WORKFLOW_DIRS; do
  wf_name=$(basename "$wf_dir")
  CSPROJ_ITEMS="${CSPROJ_ITEMS}    <None Update=\"${wf_name}/workflow.json\">
      <CopyToOutputDirectory>Always</CopyToOutputDirectory>
    </None>
"
  if [ -f "$wf_dir/workflow-draft.json" ]; then
    CSPROJ_ITEMS="${CSPROJ_ITEMS}    <None Update=\"${wf_name}/workflow-draft.json\">
      <CopyToOutputDirectory>Always</CopyToOutputDirectory>
    </None>
"
  fi
done

cat > "$TEMP_DIR/${LOGICAPP_NAME}.csproj" <<EOF
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net461</TargetFramework>
  </PropertyGroup>
  <ItemGroup>
    <PackageReference Include="Microsoft.NET.Sdk.Functions" Version="1.0.8" />
  </ItemGroup>
  <ItemGroup>
    <Reference Include="Microsoft.CSharp" />
  </ItemGroup>
  <ItemGroup>
    <None Update="connections-draft.json">
      <CopyToOutputDirectory>Always</CopyToOutputDirectory>
    </None>
    <None Update="connections.json">
      <CopyToOutputDirectory>Always</CopyToOutputDirectory>
    </None>
${CSPROJ_ITEMS}  </ItemGroup>
</Project>
EOF

ZIP_FILE="${TEMP_DIR}.zip"
trap 'rm -rf "$TEMP_DIR" "$ZIP_FILE"' EXIT

(cd "$TEMP_DIR" && zip -r "$ZIP_FILE" ./*)

echo "Deploying workflows to Logic App '$LOGICAPP_NAME'..."
az logicapp deployment source config-zip \
  --name "$LOGICAPP_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --src "$ZIP_FILE"

echo ""
echo "Deployment complete!"
echo ""
echo "NOTE: The Office 365 connection requires a one-time OAuth consent."
echo "Go to: https://portal.azure.com → Resource Group '$RESOURCE_GROUP' → API Connection 'office365-*' → Edit API connection → Authorize"
