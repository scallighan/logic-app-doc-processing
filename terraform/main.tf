terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "=4.52.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "=3.1.0"
    }
    azapi = {
      source  = "azure/azapi"
      version = "=2.8.0"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.13"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 2.53.1"
    }
  }
}

provider "azurerm" {
  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
    storage {
      data_plane_available = false
    }
  }

  storage_use_azuread = true

  subscription_id = var.subscription_id
}

resource "random_string" "unique" {
  length  = 8
  special = false
  upper   = false
}

data "azurerm_client_config" "current" {}

data "azurerm_log_analytics_workspace" "default" {
  name                = "DefaultWorkspace-${data.azurerm_client_config.current.subscription_id}-USW3" # hardcoding for now
  resource_group_name = "DefaultResourceGroup-USW3"
}

resource "azurerm_resource_group" "rg" {
  name     = "rg-${local.gh_repo}-${random_string.unique.result}-${local.loc_for_naming}"
  location = var.location
  tags     = local.tags
}

resource "azurerm_virtual_network" "default" {
  name                = "vnet-${local.func_name}-${local.loc_for_naming}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  address_space       = ["172.22.0.0/16"]

  tags = local.tags
}

resource "azurerm_subnet" "default" {
  name                            = "default-subnet-${local.loc_for_naming}"
  resource_group_name             = azurerm_resource_group.rg.name
  virtual_network_name            = azurerm_virtual_network.default.name
  address_prefixes                = ["172.22.0.0/24"]
  default_outbound_access_enabled = false
}

resource "azurerm_subnet" "cluster" {
  name                            = "cluster-subnet-${local.loc_for_naming}"
  resource_group_name             = azurerm_resource_group.rg.name
  virtual_network_name            = azurerm_virtual_network.default.name
  address_prefixes                = ["172.22.1.0/24"]
  default_outbound_access_enabled = false

  delegation {
    name = "Microsoft.App/environments"
    service_delegation {
      name    = "Microsoft.App/environments"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }

  }
}


resource "azurerm_subnet" "pe" {
  name                            = "pe-subnet-${local.loc_for_naming}"
  resource_group_name             = azurerm_resource_group.rg.name
  virtual_network_name            = azurerm_virtual_network.default.name
  address_prefixes                = ["172.22.2.0/24"]
  default_outbound_access_enabled = false
}

resource "azurerm_subnet" "la" {
  name                            = "la-subnet-${local.loc_for_naming}"
  resource_group_name             = azurerm_resource_group.rg.name
  virtual_network_name            = azurerm_virtual_network.default.name
  address_prefixes                = ["172.22.3.0/24"]
  default_outbound_access_enabled = false

  delegation {
    name = "Microsoft.Web/serverFarms"
    service_delegation {
      name    = "Microsoft.Web/serverFarms"
      actions = ["Microsoft.Network/virtualNetworks/subnets/action"]
    }

  }
}

resource "azurerm_key_vault" "kv" {
  name                          = "kv-${local.func_name}"
  location                      = azurerm_resource_group.rg.location
  resource_group_name           = azurerm_resource_group.rg.name
  tenant_id                     = data.azurerm_client_config.current.tenant_id
  sku_name                      = "standard"
  soft_delete_retention_days    = 7
  purge_protection_enabled      = false
  rbac_authorization_enabled    = true
  public_network_access_enabled = false
}

resource "azurerm_role_assignment" "kv_officer" {
  scope                = azurerm_key_vault.kv.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

resource "azurerm_role_assignment" "kv_cert_officer" {
  scope                = azurerm_key_vault.kv.id
  role_definition_name = "Key Vault Certificates Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

resource "azurerm_application_insights" "app" {
  name                = "${local.func_name}-insights"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  application_type    = "other"
  workspace_id        = data.azurerm_log_analytics_workspace.default.id
}

resource "azurerm_user_assigned_identity" "this" {
  location            = azurerm_resource_group.rg.location
  name                = "uai-${local.func_name}"
  resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_role_assignment" "containerapptokv" {
  scope                = azurerm_key_vault.kv.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.this.principal_id
}

resource "azurerm_role_assignment" "reader" {
  scope                = "/subscriptions/${data.azurerm_client_config.current.subscription_id}"
  role_definition_name = "Reader"
  principal_id         = azurerm_user_assigned_identity.this.principal_id
}

resource "azapi_resource" "storage_account" {
  type      = "Microsoft.Storage/storageAccounts@2023-01-01"
  name      = "sa${random_string.unique.result}"
  location  = azurerm_resource_group.rg.location
  parent_id = azurerm_resource_group.rg.id

  body = {
    sku = {
      name = "Standard_LRS"
    }
    kind = "StorageV2"
    properties = {
      accessTier               = "Hot"
      allowBlobPublicAccess    = false
      minimumTlsVersion        = "TLS1_2"
      supportsHttpsTrafficOnly = true
    }
  }

  tags = local.tags
}


#privatelink.blob.core.windows.net
resource "azurerm_private_dns_zone" "blob" {
  name                = "privatelink.blob.core.windows.net"
  resource_group_name = azurerm_resource_group.rg.name
  tags                = local.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "blob" {
  name                  = "blob"
  resource_group_name   = azurerm_resource_group.rg.name
  private_dns_zone_name = azurerm_private_dns_zone.blob.name
  virtual_network_id    = azurerm_virtual_network.default.id
}

#privatelink.queue.core.windows.net
resource "azurerm_private_dns_zone" "queue" {
  name                = "privatelink.queue.core.windows.net"
  resource_group_name = azurerm_resource_group.rg.name
  tags                = local.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "queue" {
  name                  = "queue"
  resource_group_name   = azurerm_resource_group.rg.name
  private_dns_zone_name = azurerm_private_dns_zone.queue.name
  virtual_network_id    = azurerm_virtual_network.default.id
}

#privatelink.table.core.windows.net
resource "azurerm_private_dns_zone" "table" {
  name                = "privatelink.table.core.windows.net"
  resource_group_name = azurerm_resource_group.rg.name
  tags                = local.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "table" {
  name                  = "table"
  resource_group_name   = azurerm_resource_group.rg.name
  private_dns_zone_name = azurerm_private_dns_zone.table.name
  virtual_network_id    = azurerm_virtual_network.default.id
}

#privatelink.file.core.windows.net
resource "azurerm_private_dns_zone" "file" {
  name                = "privatelink.file.core.windows.net"
  resource_group_name = azurerm_resource_group.rg.name
  tags                = local.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "file" {
  name                  = "file"
  resource_group_name   = azurerm_resource_group.rg.name
  private_dns_zone_name = azurerm_private_dns_zone.file.name
  virtual_network_id    = azurerm_virtual_network.default.id
}

resource "azurerm_private_endpoint" "sa_pe" {
  name                = "pe-sa-${local.func_name}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  subnet_id           = azurerm_subnet.pe.id

  private_service_connection {
    name                           = "psc-sa-${local.func_name}"
    private_connection_resource_id = azapi_resource.storage_account.id
    is_manual_connection           = false
    subresource_names              = ["blob"]
  }

  private_dns_zone_group {
    name                 = "blob"
    private_dns_zone_ids = [azurerm_private_dns_zone.blob.id]
  }

  tags = local.tags
}

resource "azurerm_private_endpoint" "sa_queue_pe" {
  name                = "pe-sa-queue-${local.func_name}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  subnet_id           = azurerm_subnet.pe.id

  private_service_connection {
    name                           = "psc-sa-queue-${local.func_name}"
    private_connection_resource_id = azapi_resource.storage_account.id
    is_manual_connection           = false
    subresource_names              = ["queue"]
  }

  private_dns_zone_group {
    name                 = "queue"
    private_dns_zone_ids = [azurerm_private_dns_zone.queue.id]
  }

  tags = local.tags
}

resource "azurerm_private_endpoint" "sa_table_pe" {
  name                = "pe-sa-table-${local.func_name}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  subnet_id           = azurerm_subnet.pe.id

  private_service_connection {
    name                           = "psc-sa-table-${local.func_name}"
    private_connection_resource_id = azapi_resource.storage_account.id
    is_manual_connection           = false
    subresource_names              = ["table"]
  }

  private_dns_zone_group {
    name                 = "table"
    private_dns_zone_ids = [azurerm_private_dns_zone.table.id]
  }

  tags = local.tags
}

resource "azurerm_private_endpoint" "sa_file_pe" {
  name                = "pe-sa-file-${local.func_name}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  subnet_id           = azurerm_subnet.pe.id

  private_service_connection {
    name                           = "psc-sa-file-${local.func_name}"
    private_connection_resource_id = azapi_resource.storage_account.id
    is_manual_connection           = false
    subresource_names              = ["file"]
  }

  private_dns_zone_group {
    name                 = "file"
    private_dns_zone_ids = [azurerm_private_dns_zone.file.id]
  }

  tags = local.tags
}


resource "azurerm_role_assignment" "blob" {
  scope                = azapi_resource.storage_account.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.this.principal_id
}


resource "azurerm_role_assignment" "queue" {
  scope                = azapi_resource.storage_account.id
  role_definition_name = "Storage Queue Data Contributor"
  principal_id         = azurerm_user_assigned_identity.this.principal_id
}

resource "azurerm_role_assignment" "table" {
  scope                = azapi_resource.storage_account.id
  role_definition_name = "Storage Table Data Contributor"
  principal_id         = azurerm_user_assigned_identity.this.principal_id
}

resource "azurerm_service_plan" "asp" {
  name                = "asp-${random_string.unique.result}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  os_type             = "Windows"
  sku_name            = "WS1"
  tags                = local.tags
}

## deployment of a standard logic app using the azapi resource

resource "azapi_resource" "logicapp" {
  depends_on = [
    azurerm_role_assignment.blob,
    azurerm_role_assignment.queue,
    azurerm_role_assignment.table,
    azurerm_service_plan.asp,
    azurerm_private_endpoint.sa_file_pe,
    azurerm_private_endpoint.sa_table_pe,
    azurerm_private_endpoint.sa_queue_pe,
    azurerm_private_endpoint.sa_pe,
  ]
  type      = "Microsoft.Web/sites@2025-03-01"
  name      = "la${local.func_name}"
  parent_id = azurerm_resource_group.rg.id
  identity {
    type = "SystemAssigned, UserAssigned"
    identity_ids = [
      azurerm_user_assigned_identity.this.id
    ]
  }
  location = azurerm_resource_group.rg.location
  tags     = local.tags
  body = {
    kind = "functionapp,workflowapp"
    properties = {
      outboundVnetRouting = {
        allTraffic = true
      }
      serverFarmId = replace(azurerm_service_plan.asp.id, "serverFarms", "serverfarms")
      siteConfig = {
        appSettings = [
          {
            name  = "FUNCTIONS_EXTENSION_VERSION",
            value = "~4"
          },
          {
            name  = "FUNCTIONS_WORKER_RUNTIME",
            value = "dotnet"
          },
          {
            name  = "AzureWebJobsStorage__credential",
            value = "managedidentity"
          },
          {
            name  = "AzureWebJobsStorage__blobServiceUri",
            value = "https://sa${random_string.unique.result}.blob.core.windows.net"
          },
          {
            name  = "AzureWebJobsStorage__queueServiceUri",
            value = "https://sa${random_string.unique.result}.queue.core.windows.net"
          },
          {
            name  = "AzureWebJobsStorage__tableServiceUri",
            value = "https://sa${random_string.unique.result}.table.core.windows.net"
          },
          {
            name  = "AzureWebJobsStorage__managedIdentityResourceId",
            value = azurerm_user_assigned_identity.this.id
          },
          {
            name  = "AzureFunctionsJobHost__extensionBundle__id",
            value = "Microsoft.Azure.Functions.ExtensionBundle.Workflows"
          },
          {
            name  = "AzureFunctionsJobHost__extensionBundle__version",
            value = "[1.*, 2.0.0)"
          },
          {
            name  = "APP_KIND",
            value = "workflowApp"
          },
          {
            name  = "FUNCTIONS_INPROC_NET8_ENABLED",
            value = "1"
          },
          {
            name  = "LOGIC_APPS_POWERSHELL_VERSION",
            value = "7.4"
          },
          {
            name  = "documentIntelligence_documentIntelligenceEndpoint",
            value = azurerm_cognitive_account.form_recognizer.endpoint
          }
        ]
      }
      virtualNetworkSubnetId = azurerm_subnet.la.id
    }
  }
}

# add a SQL Server

resource "azurerm_mssql_server" "this" {
  name                = "sql-${local.func_name}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  version             = "12.0"

  public_network_access_enabled = false
  azuread_administrator {
    login_username              = data.azurerm_client_config.current.client_id
    object_id                   = data.azurerm_client_config.current.object_id
    azuread_authentication_only = true
  }

  identity {
    type = "SystemAssigned"
  }

  tags = local.tags
}

resource "azurerm_mssql_database" "this" {
  name        = "db-${local.func_name}"
  server_id   = azurerm_mssql_server.this.id
  sku_name    = "Basic"
  collation   = "SQL_Latin1_General_CP1_CI_AS"
  max_size_gb = 2

  tags = local.tags
}

#privatelink.database.windows.net
resource "azurerm_private_dns_zone" "sql" {
  name                = "privatelink.database.windows.net"
  resource_group_name = azurerm_resource_group.rg.name
  tags                = local.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "sql" {
  name                  = "sql"
  resource_group_name   = azurerm_resource_group.rg.name
  private_dns_zone_name = azurerm_private_dns_zone.sql.name
  virtual_network_id    = azurerm_virtual_network.default.id
}


# create a private endpoint for the Azure SQL Database
resource "azurerm_private_endpoint" "sql" {
  name                = "pe-sql-${local.func_name}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  subnet_id           = azurerm_subnet.pe.id
  private_service_connection {
    name                           = "psc-sql-${local.func_name}"
    is_manual_connection           = false
    private_connection_resource_id = azurerm_mssql_server.this.id
    subresource_names              = ["sqlServer"]
  }

  private_dns_zone_group {
    name                 = "pdzg-sql-${local.func_name}"
    private_dns_zone_ids = [azurerm_private_dns_zone.sql.id]
  }
  tags = local.tags
}

# Create cognitive services formRecognizer
resource "azurerm_cognitive_account" "form_recognizer" {
  name                          = "cogfr${local.func_name}"
  resource_group_name           = azurerm_resource_group.rg.name
  location                      = azurerm_resource_group.rg.location
  kind                          = "FormRecognizer"
  sku_name                      = "S0"
  local_auth_enabled            = false
  custom_subdomain_name         = "cogfr${local.func_name}"
  public_network_access_enabled = false
  tags                          = local.tags
}

# create a private dns zone for the cognitive services account
resource "azurerm_private_dns_zone" "cognitive" {
  name                = "privatelink.cognitiveservices.azure.com"
  resource_group_name = azurerm_resource_group.rg.name
  tags                = local.tags
}

# assign private dns zone to the vnet
resource "azurerm_private_dns_zone_virtual_network_link" "cognitive" {
  name                  = "cognitive"
  resource_group_name   = azurerm_resource_group.rg.name
  private_dns_zone_name = azurerm_private_dns_zone.cognitive.name
  virtual_network_id    = azurerm_virtual_network.default.id
}

# create the private link for the cognitive services account
resource "azurerm_private_endpoint" "cognitive" {
  name                = "pe-cognitive-${local.func_name}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  subnet_id           = azurerm_subnet.pe.id
  private_service_connection {
    name                           = "psc-cognitive-${local.func_name}"
    private_connection_resource_id = azurerm_cognitive_account.form_recognizer.id
    is_manual_connection           = false
    subresource_names              = ["account"]
  }
  private_dns_zone_group {
    name                 = "cognitive"
    private_dns_zone_ids = [azurerm_private_dns_zone.cognitive.id]
  }
  tags = local.tags
}

# Assign Cognitive Services Contributor role to the user assigned identity for the cognitive account
resource "azurerm_role_assignment" "cognitive_contributor" {
  scope                = azurerm_cognitive_account.form_recognizer.id
  role_definition_name = "Cognitive Services Contributor"
  principal_id         = azurerm_user_assigned_identity.this.principal_id
}

# Assign Azure AI User to resource group for the user assigned identity to access cognitive services
resource "azurerm_role_assignment" "ai_user" {
  scope                = azurerm_resource_group.rg.id
  role_definition_name = "Foundry User"
  principal_id         = azurerm_user_assigned_identity.this.principal_id
}

# Give the logic app system assigned identity Azure AI User on the doc intel instance
resource "azurerm_role_assignment" "la_ai_user" {
  scope                = azurerm_cognitive_account.form_recognizer.id
  role_definition_name = "Foundry User"
  principal_id         = azapi_resource.logicapp.identity.0.principal_id
}

# ─── Office 365 Managed API Connection ───────────────────────────────────────

resource "azapi_resource" "office365_connection" {
  type      = "Microsoft.Web/connections@2016-06-01"
  name      = "office365-${local.func_name}"
  parent_id = azurerm_resource_group.rg.id
  location  = azurerm_resource_group.rg.location
  tags      = local.tags

  body = {
    properties = {
      displayName = "Office 365 Outlook"
      api = {
        id = "/subscriptions/${data.azurerm_client_config.current.subscription_id}/providers/Microsoft.Web/locations/${azurerm_resource_group.rg.location}/managedApis/office365"
      }
    }
    kind = "V2"
  }
  schema_validation_enabled = false
  response_export_values = ["properties.connectionRuntimeUrl"]
}

resource "azapi_resource" "office365_access_policy" {
  type      = "Microsoft.Web/connections/accessPolicies@2016-06-01"
  name      = "${azapi_resource.logicapp.name}-policy"
  parent_id = azapi_resource.office365_connection.id

  body = {
    location = azurerm_resource_group.rg.location
    properties = {
      principal = {
        type = "ActiveDirectory"
        identity = {
          tenantId = data.azurerm_client_config.current.tenant_id
          objectId = azapi_resource.logicapp.identity.0.principal_id
        }
      }
    }
  }

  schema_validation_enabled = false
}

output "sql_server_fqdn" {
  value = azurerm_mssql_server.this.fully_qualified_domain_name
}

output "sql_database_name" {
  value = azurerm_mssql_database.this.name
}

output "form_recognizer_endpoint" {
  value = azurerm_cognitive_account.form_recognizer.endpoint
}

output "user_assigned_identity_client_id" {
  value = azurerm_user_assigned_identity.this.client_id
}

output "office365_connection_id" {
  value = azapi_resource.office365_connection.id
}

output "office365_connection_runtime_url" {
  value = azapi_resource.office365_connection.output.properties.connectionRuntimeUrl
}

output "logic_app_name" {
  value = azapi_resource.logicapp.name
}

output "resource_group_name" {
  value = azurerm_resource_group.rg.name
}

output "location" {
  value = azurerm_resource_group.rg.location
}
