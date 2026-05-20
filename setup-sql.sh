#!/bin/bash
set -euo pipefail

# ─── SQL Setup Script (Terraform) ────────────────────────────────────────────
# Temporarily opens public access, adds a client IP firewall rule, runs the
# SQL schema setup, then re-locks the server.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="${SCRIPT_DIR}/terraform"

# ─── Validate prerequisites ──────────────────────────────────────────────────
if ! command -v az &>/dev/null; then
  echo "ERROR: Azure CLI (az) is not installed or not in PATH."
  exit 1
fi

if ! command -v sqlcmd &>/dev/null; then
  echo "ERROR: sqlcmd is not installed or not in PATH."
  echo "Install it: https://learn.microsoft.com/en-us/sql/tools/sqlcmd/sqlcmd-utility"
  exit 1
fi

# ─── Read Terraform outputs ──────────────────────────────────────────────────
echo "Reading deployment outputs from Terraform..."
TF_OUTPUT=$(cd "$TERRAFORM_DIR" && terraform output -json)

SQL_SERVER_NAME=$(echo "$TF_OUTPUT" | python3 -c "import sys,json; print(json.load(sys.stdin)['sql_server_fqdn']['value'].split('.')[0])")
SQL_SERVER_FQDN=$(echo "$TF_OUTPUT" | python3 -c "import sys,json; print(json.load(sys.stdin)['sql_server_fqdn']['value'])")
SQL_DATABASE_NAME=$(echo "$TF_OUTPUT" | python3 -c "import sys,json; print(json.load(sys.stdin)['sql_database_name']['value'])")
RESOURCE_GROUP=$(echo "$TF_OUTPUT" | python3 -c "import sys,json; print(json.load(sys.stdin)['resource_group_name']['value'])")
UAI_NAME=$(echo "$TF_OUTPUT" | python3 -c "
import sys, json
uid = json.load(sys.stdin)['user_assigned_identity_client_id']['value']
# We need the UAI resource name, not client ID — derive from terraform output
" 2>/dev/null || echo "")

# Get the UAI resource name from Terraform state
UAI_NAME=$(cd "$TERRAFORM_DIR" && terraform state show azurerm_user_assigned_identity.this 2>/dev/null | grep '^\s*name\s' | head -1 | awk -F'"' '{print $2}')

if [ -z "$UAI_NAME" ]; then
  echo "ERROR: Could not determine User Assigned Identity name."
  exit 1
fi

echo "SQL Server:        $SQL_SERVER_FQDN"
echo "SQL Database:      $SQL_DATABASE_NAME"
echo "Resource Group:    $RESOURCE_GROUP"
echo "UAI Name:          $UAI_NAME"

# ─── Get client IP ───────────────────────────────────────────────────────────
echo ""
echo "Detecting client IP..."
CLIENT_IP=$(curl -s https://api.ipify.org)
echo "Client IP:         $CLIENT_IP"

# ─── Temporarily enable public access ─────────────────────────────────────────
echo ""
echo "Temporarily enabling public network access on SQL server..."
az sql server update \
  --name "$SQL_SERVER_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --enable-public-network true \
  --output none

echo "Adding firewall rule for client IP..."
az sql server firewall-rule create \
  --server "$SQL_SERVER_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --name "setup-temp-rule" \
  --start-ip-address "$CLIENT_IP" \
  --end-ip-address "$CLIENT_IP" \
  --output none

# ─── Cleanup function ────────────────────────────────────────────────────────
cleanup() {
  echo ""
  echo "Cleaning up: removing firewall rule and disabling public access..."
  az sql server firewall-rule delete \
    --server "$SQL_SERVER_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --name "setup-temp-rule" \
    --output none 2>/dev/null || true
  az sql server update \
    --name "$SQL_SERVER_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --enable-public-network false \
    --output none 2>/dev/null || true
  echo "Public access disabled."
}
trap cleanup EXIT

# ─── Wait for firewall propagation ───────────────────────────────────────────
echo "Waiting for firewall rule to propagate..."
sleep 10

# ─── Run SQL setup ────────────────────────────────────────────────────────────
echo ""
echo "Running SQL setup..."

sqlcmd -S "$SQL_SERVER_FQDN" -d "$SQL_DATABASE_NAME" --authentication-method=ActiveDirectoryDefault -Q "
-- Create the managed identity as an external user
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = '$UAI_NAME')
BEGIN
    CREATE USER [$UAI_NAME] FROM EXTERNAL PROVIDER;
    PRINT 'Created user $UAI_NAME';
END
ELSE
    PRINT 'User $UAI_NAME already exists';

-- Create the Documents table
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'Documents' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    CREATE TABLE dbo.Documents (
        DocumentDate DATE NOT NULL,
        Name NVARCHAR(100) NOT NULL,
        Content NVARCHAR(MAX) NULL,
        Processor NVARCHAR(50) NOT NULL,
        DocumentID INT IDENTITY(1,1) PRIMARY KEY
    );
    PRINT 'Created table dbo.Documents';
END
ELSE
    PRINT 'Table dbo.Documents already exists';

-- Grant db_owner role
IF NOT EXISTS (SELECT 1 FROM sys.database_role_members drm
    JOIN sys.database_principals rp ON drm.role_principal_id = rp.principal_id
    JOIN sys.database_principals mp ON drm.member_principal_id = mp.principal_id
    WHERE rp.name = 'db_owner' AND mp.name = '$UAI_NAME')
BEGIN
    EXEC sp_addrolemember 'db_owner', '$UAI_NAME';
    PRINT 'Granted db_owner to $UAI_NAME';
END
ELSE
    PRINT '$UAI_NAME is already db_owner';
"

echo ""
echo "SQL setup complete!"
