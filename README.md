# logic-app-doc-processing

A Logic App (Standard) solution for document processing using Azure Document Intelligence (Form Recognizer), SQL Server, and Office 365.

## Prerequisites

The following tools must be installed on your machine:

| Tool | Required For | Install |
|------|-------------|---------|
| [Azure CLI (`az`)](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli) | All deployments | `brew install azure-cli` or [docs](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli) |
| [Terraform](https://developer.hashicorp.com/terraform/install) | Terraform deployment | `brew install terraform` or [docs](https://developer.hashicorp.com/terraform/install) |
| [Bicep CLI](https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/install) | Bicep deployment | `az bicep install` |
| [sqlcmd](https://learn.microsoft.com/en-us/sql/tools/sqlcmd/sqlcmd-utility) | SQL database setup | `brew install sqlcmd` or [docs](https://learn.microsoft.com/en-us/sql/tools/sqlcmd/go-sqlcmd-utility) |
| [Python 3](https://www.python.org/) | Deploy scripts (JSON parsing) | Usually pre-installed |
| [zip](https://infozip.sourceforge.net/) | Workflow packaging | Usually pre-installed |

You must also be logged into Azure CLI (`az login`) with a principal that has Owner or Contributor + User Access Administrator on the target subscription.

## Deployment

Choose either **Terraform** or **Bicep** — both provision identical infrastructure.

### Option A: Terraform

```bash
# 1. Configure environment
cp terraform/env.sample terraform/.env
# Edit terraform/.env with your values

# 2. Deploy infrastructure
cd terraform
source .env
terraform init
terraform apply

# 3. Set up SQL database
cd ..
./setup-sql.sh

# 4. Deploy workflows + connections
./deploy-workflows.sh
```

### Option B: Bicep

```bash
# 1. Configure parameters
cp bicep/main.parameters.sample.json bicep/main.parameters.json
# Edit bicep/main.parameters.json with your values

# 2. Deploy infrastructure
./deploy-bicep.sh

# 3. Set up SQL database
./setup-sql-bicep.sh

# 4. Deploy workflows + connections
./deploy-workflows-bicep.sh
```

### Post-deployment

The **Office 365 connection** requires a one-time OAuth consent:

1. Go to the [Azure Portal](https://portal.azure.com)
2. Navigate to your Resource Group
3. Open the API Connection resource (`office365-*`)
4. Click **Edit API connection** → **Authorize** → **Save**

## SQL (Manual Setup)

If you prefer to set up SQL manually instead of using the setup scripts, run the following against your database:

```
CREATE USER [uai-ladocproc........] FROM EXTERNAL PROVIDER;
```

```
CREATE TABLE dbo.Documents (
    DocumentDate DATE NOT NULL, 
    Name NVARCHAR(100) NOT NULL,  
    Content NVARCHAR(MAX) NULL,
    Processor NVARCHAR(50) NOT NULL,        
    DocumentID INT IDENTITY(1,1) PRIMARY KEY 
);
```

```
EXEC sp_addrolemember 'db_owner', 'uai-ladocproc........';
```

## Scripts Reference

| Script | Description |
|--------|-------------|
| `deploy-bicep.sh` | Deploys Bicep infrastructure (subscription-scoped) |
| `deploy-workflows.sh` | Packages and deploys workflows using Terraform outputs |
| `deploy-workflows-bicep.sh` | Packages and deploys workflows using Bicep deployment outputs |
| `setup-sql.sh` | Automates SQL schema setup (Terraform) — temporarily opens public access |
| `setup-sql-bicep.sh` | Automates SQL schema setup (Bicep) — temporarily opens public access |

## Project Structure

```
├── terraform/                  # Terraform IaC
│   ├── main.tf
│   ├── variables.tf
│   ├── locals.tf
│   └── env.sample
├── bicep/                      # Bicep IaC
│   ├── main.bicep
│   ├── resources.bicep
│   └── main.parameters.sample.json
├── workflows/                  # Logic App workflow definitions
│   ├── myworkflow.json
│   └── pipelineworkflow.json
├── connections.template.json   # Connection template (populated at deploy time)
├── deploy-bicep.sh
├── deploy-workflows.sh
├── deploy-workflows-bicep.sh
├── setup-sql.sh
└── setup-sql-bicep.sh
```