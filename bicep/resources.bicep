@description('Azure region for all resources')
param location string

@description('GitHub repository in owner/repo format')
param ghRepo string

@description('Azure subscription ID')
param subscriptionId string

var repoName = split(ghRepo, '/')[1]
var locForNaming = toLower(replace(location, ' ', ''))
var uniqueSuffix = substring(uniqueString(resourceGroup().id), 0, 8)
var funcName = 'ladocproc${uniqueSuffix}'
var tags = {
  managed_by: 'bicep'
  repo: repoName
}

// ─── Log Analytics (existing) ────────────────────────────────────────────────
var logAnalyticsWorkspaceName = 'DefaultWorkspace-${subscriptionId}-USW3'
var logAnalyticsResourceGroup = 'DefaultResourceGroup-USW3'

resource logAnalyticsWorkspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = {
  name: logAnalyticsWorkspaceName
  scope: resourceGroup(logAnalyticsResourceGroup)
}

// ─── Virtual Network ─────────────────────────────────────────────────────────
resource vnet 'Microsoft.Network/virtualNetworks@2024-01-01' = {
  name: 'vnet-${funcName}-${locForNaming}'
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: ['172.22.0.0/16']
    }
    subnets: [
      {
        name: 'default-subnet-${locForNaming}'
        properties: {
          addressPrefix: '172.22.0.0/24'
          defaultOutboundAccess: false
        }
      }
      {
        name: 'cluster-subnet-${locForNaming}'
        properties: {
          addressPrefix: '172.22.1.0/24'
          defaultOutboundAccess: false
          delegations: [
            {
              name: 'Microsoft.App/environments'
              properties: {
                serviceName: 'Microsoft.App/environments'
              }
            }
          ]
        }
      }
      {
        name: 'pe-subnet-${locForNaming}'
        properties: {
          addressPrefix: '172.22.2.0/24'
          defaultOutboundAccess: false
        }
      }
      {
        name: 'la-subnet-${locForNaming}'
        properties: {
          addressPrefix: '172.22.3.0/24'
          defaultOutboundAccess: false
          delegations: [
            {
              name: 'Microsoft.Web/serverFarms'
              properties: {
                serviceName: 'Microsoft.Web/serverFarms'
              }
            }
          ]
        }
      }
    ]
  }
}

var peSubnetId = vnet.properties.subnets[2].id
var laSubnetId = vnet.properties.subnets[3].id

// ─── Key Vault ───────────────────────────────────────────────────────────────
resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: 'kv-${funcName}'
  location: location
  tags: tags
  properties: {
    tenantId: subscription().tenantId
    sku: {
      family: 'A'
      name: 'standard'
    }
    softDeleteRetentionInDays: 7
    enableRbacAuthorization: true
    publicNetworkAccess: 'Disabled'
  }
}

// ─── Application Insights ────────────────────────────────────────────────────
resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: '${funcName}-insights'
  location: location
  tags: tags
  kind: 'other'
  properties: {
    Application_Type: 'other'
    WorkspaceResourceId: logAnalyticsWorkspace.id
  }
}

// ─── User Assigned Identity ──────────────────────────────────────────────────
resource userIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'uai-${funcName}'
  location: location
}

// ─── Role Assignments: Key Vault ─────────────────────────────────────────────
@description('Object ID of the deploying principal for Key Vault role assignments')
param deployerObjectId string = ''

// Key Vault Secrets Officer for deployer
resource kvSecretsOfficer 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(deployerObjectId)) {
  name: guid(keyVault.id, deployerObjectId, 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7')
  scope: keyVault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7')
    principalId: deployerObjectId
  }
}

// Key Vault Certificates Officer for deployer
resource kvCertsOfficer 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(deployerObjectId)) {
  name: guid(keyVault.id, deployerObjectId, 'a4417e6f-fecd-4de8-b567-7b0420556985')
  scope: keyVault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'a4417e6f-fecd-4de8-b567-7b0420556985')
    principalId: deployerObjectId
  }
}

// Key Vault Secrets User for managed identity
resource kvSecretsUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(keyVault.id, userIdentity.id, '4633458b-17de-408a-b874-0445c86b69e6')
  scope: keyVault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4633458b-17de-408a-b874-0445c86b69e6')
    principalId: userIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// ─── Storage Account ─────────────────────────────────────────────────────────
resource storageAccount 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: 'sa${uniqueSuffix}'
  location: location
  tags: tags
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    accessTier: 'Hot'
    allowBlobPublicAccess: false
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
  }
}

// Storage role assignments for managed identity
resource storageBlobRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, userIdentity.id, 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')
  scope: storageAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')
    principalId: userIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource storageQueueRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, userIdentity.id, '974c5e8b-45b9-4653-ba55-5f855dd0fb88')
  scope: storageAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '974c5e8b-45b9-4653-ba55-5f855dd0fb88')
    principalId: userIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource storageTableRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, userIdentity.id, '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3')
  scope: storageAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3')
    principalId: userIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// ─── Private DNS Zones ───────────────────────────────────────────────────────
var storageSuffix = environment().suffixes.storage
var sqlServerSuffix = environment().suffixes.sqlServerHostname
var privateDnsZones = [
  'privatelink.blob.${storageSuffix}'
  'privatelink.queue.${storageSuffix}'
  'privatelink.table.${storageSuffix}'
  'privatelink.file.${storageSuffix}'
  'privatelink${sqlServerSuffix}'
  'privatelink.cognitiveservices.azure.com'
]

resource dnsZones 'Microsoft.Network/privateDnsZones@2024-06-01' = [for zone in privateDnsZones: {
  name: zone
  location: 'global'
  tags: tags
}]

resource dnsZoneLinks 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = [for (zone, i) in privateDnsZones: {
  parent: dnsZones[i]
  name: split(zone, '.')[1]
  location: 'global'
  properties: {
    virtualNetwork: {
      id: vnet.id
    }
    registrationEnabled: false
  }
}]

// ─── Private Endpoints: Storage Account ──────────────────────────────────────
var storageSubresources = ['blob', 'queue', 'table', 'file']

resource storagePrivateEndpoints 'Microsoft.Network/privateEndpoints@2024-01-01' = [for (subresource, i) in storageSubresources: {
  name: 'pe-sa-${subresource == 'blob' ? '' : '${subresource}-'}${funcName}'
  location: location
  tags: tags
  properties: {
    subnet: {
      id: peSubnetId
    }
    privateLinkServiceConnections: [
      {
        name: 'psc-sa-${subresource == 'blob' ? '' : '${subresource}-'}${funcName}'
        properties: {
          privateLinkServiceId: storageAccount.id
          groupIds: [subresource]
        }
      }
    ]
  }
}]

resource storagePeDnsGroups 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-01-01' = [for (subresource, i) in storageSubresources: {
  parent: storagePrivateEndpoints[i]
  name: subresource
  properties: {
    privateDnsZoneConfigs: [
      {
        name: subresource
        properties: {
          privateDnsZoneId: dnsZones[i].id
        }
      }
    ]
  }
}]

// ─── Service Plan ────────────────────────────────────────────────────────────
resource servicePlan 'Microsoft.Web/serverfarms@2024-04-01' = {
  name: 'asp-${uniqueSuffix}'
  location: location
  tags: tags
  sku: {
    name: 'WS1'
    tier: 'WorkflowStandard'
  }
  properties: {
    reserved: false
  }
  kind: 'windows'
}

// ─── Logic App (Standard) ────────────────────────────────────────────────────
resource logicApp 'Microsoft.Web/sites@2024-04-01' = {
  name: 'la${funcName}'
  location: location
  tags: tags
  kind: 'functionapp,workflowapp'
  identity: {
    type: 'SystemAssigned, UserAssigned'
    userAssignedIdentities: {
      '${userIdentity.id}': {}
    }
  }
  properties: {
    serverFarmId: servicePlan.id
    virtualNetworkSubnetId: laSubnetId
    vnetRouteAllEnabled: true
    siteConfig: {
      appSettings: [
        { name: 'FUNCTIONS_EXTENSION_VERSION', value: '~4' }
        { name: 'FUNCTIONS_WORKER_RUNTIME', value: 'dotnet' }

        { name: 'AzureWebJobsStorage__credential', value: 'managedidentity' }
        { name: 'AzureWebJobsStorage__blobServiceUri', value: 'https://${storageAccount.name}.blob.${storageSuffix}' }
        { name: 'AzureWebJobsStorage__queueServiceUri', value: 'https://${storageAccount.name}.queue.${storageSuffix}' }
        { name: 'AzureWebJobsStorage__tableServiceUri', value: 'https://${storageAccount.name}.table.${storageSuffix}' }
        { name: 'AzureWebJobsStorage__managedIdentityResourceId', value: userIdentity.id }
        { name: 'AzureFunctionsJobHost__extensionBundle__id', value: 'Microsoft.Azure.Functions.ExtensionBundle.Workflows' }
        { name: 'AzureFunctionsJobHost__extensionBundle__version', value: '[1.*, 2.0.0)' }
        { name: 'APP_KIND', value: 'workflowApp' }
        { name: 'FUNCTIONS_INPROC_NET8_ENABLED', value: '1' }
        { name: 'LOGIC_APPS_POWERSHELL_VERSION', value: '7.4' }
        { name: 'documentIntelligence_documentIntelligenceEndpoint', value: formRecognizer.properties.endpoint }
      ]
    }
  }
  dependsOn: [
    storageBlobRole
    storageQueueRole
    storageTableRole
    storagePrivateEndpoints
  ]
}

// ─── SQL Server ──────────────────────────────────────────────────────────────
@description('Object ID of the deploying principal for SQL AAD admin')
param sqlAdminObjectId string = ''

@description('Client ID (app ID) of the deploying principal for SQL AAD admin login')
param sqlAdminClientId string = ''

resource sqlServer 'Microsoft.Sql/servers@2023-08-01-preview' = {
  name: 'sql-${funcName}'
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    version: '12.0'
    publicNetworkAccess: 'Disabled'
    administrators: {
      administratorType: 'ActiveDirectory'
      login: !empty(sqlAdminClientId) ? sqlAdminClientId : 'sqladmin'
      sid: !empty(sqlAdminObjectId) ? sqlAdminObjectId : '00000000-0000-0000-0000-000000000000'
      tenantId: subscription().tenantId
      azureADOnlyAuthentication: true
    }
  }
}

resource sqlDatabase 'Microsoft.Sql/servers/databases@2023-08-01-preview' = {
  parent: sqlServer
  name: 'db-${funcName}'
  location: location
  tags: tags
  sku: {
    name: 'Basic'
  }
  properties: {
    collation: 'SQL_Latin1_General_CP1_CI_AS'
    maxSizeBytes: 2147483648 // 2 GB
  }
}

// Private endpoint for SQL
resource sqlPrivateEndpoint 'Microsoft.Network/privateEndpoints@2024-01-01' = {
  name: 'pe-sql-${funcName}'
  location: location
  tags: tags
  properties: {
    subnet: {
      id: peSubnetId
    }
    privateLinkServiceConnections: [
      {
        name: 'psc-sql-${funcName}'
        properties: {
          privateLinkServiceId: sqlServer.id
          groupIds: ['sqlServer']
        }
      }
    ]
  }
}

resource sqlPeDnsGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-01-01' = {
  parent: sqlPrivateEndpoint
  name: 'sql-dns-group'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'sql'
        properties: {
          privateDnsZoneId: dnsZones[4].id
        }
      }
    ]
  }
}

// ─── Cognitive Services (Form Recognizer / Document Intelligence) ────────────
resource formRecognizer 'Microsoft.CognitiveServices/accounts@2024-10-01' = {
  name: 'cogfr${funcName}'
  location: location
  tags: tags
  kind: 'FormRecognizer'
  sku: {
    name: 'S0'
  }
  identity: {
    type: 'None'
  }
  properties: {
    customSubDomainName: 'cogfr${funcName}'
    disableLocalAuth: true
    publicNetworkAccess: 'Disabled'
  }
}

// Private endpoint for Cognitive Services
resource cognitivePrivateEndpoint 'Microsoft.Network/privateEndpoints@2024-01-01' = {
  name: 'pe-cognitive-${funcName}'
  location: location
  tags: tags
  properties: {
    subnet: {
      id: peSubnetId
    }
    privateLinkServiceConnections: [
      {
        name: 'psc-cognitive-${funcName}'
        properties: {
          privateLinkServiceId: formRecognizer.id
          groupIds: ['account']
        }
      }
    ]
  }
}

resource cognitivePeDnsGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-01-01' = {
  parent: cognitivePrivateEndpoint
  name: 'cognitive-dns-group'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'cognitive'
        properties: {
          privateDnsZoneId: dnsZones[5].id
        }
      }
    ]
  }
}

// Cognitive Services Contributor for managed identity
resource cognitiveContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(formRecognizer.id, userIdentity.id, '25fbc0a9-bd7c-42a3-aa1a-3b75d497ee68')
  scope: formRecognizer
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '25fbc0a9-bd7c-42a3-aa1a-3b75d497ee68')
    principalId: userIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// Reader role on resource group for managed identity
resource readerRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, userIdentity.id, 'acdd72a7-3385-48ef-bd42-f606fba81ae7')
  scope: resourceGroup()
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'acdd72a7-3385-48ef-bd42-f606fba81ae7')
    principalId: userIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// Azure AI User on resource group for managed identity
resource aiUserRg 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, userIdentity.id, '53ca6127-db72-4b80-b1b0-d745d6d5456d')
  scope: resourceGroup()
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '53ca6127-db72-4b80-b1b0-d745d6d5456d')
    principalId: userIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// Azure AI User on doc intel for logic app system-assigned identity
resource laAiUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(formRecognizer.id, logicApp.id, '53ca6127-db72-4b80-b1b0-d745d6d5456d')
  scope: formRecognizer
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '53ca6127-db72-4b80-b1b0-d745d6d5456d')
    principalId: logicApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// ─── Office 365 Managed API Connection ───────────────────────────────────────
resource office365Api 'Microsoft.Web/connections@2016-06-01' = {
  name: 'office365-${funcName}'
  location: location
  tags: tags
  kind: 'V2'
  properties: {
    displayName: 'Office 365 Outlook'
    api: {
      id: subscriptionResourceId('Microsoft.Web/locations/managedApis', location, 'office365')
    }
  }
}

// Grant Logic App access to the Office 365 connection
#disable-next-line BCP081
resource office365AccessPolicy 'Microsoft.Web/connections/accessPolicies@2016-06-01' = {
  parent: office365Api
  name: '${logicApp.name}-policy'
  location: location
  properties: {
    principal: {
      type: 'ActiveDirectory'
      identity: {
        tenantId: subscription().tenantId
        objectId: logicApp.identity.principalId
      }
    }
  }
}

// Alias for output clarity
resource office365Connection 'Microsoft.Web/connections@2016-06-01' existing = {
  name: office365Api.name
}

// ─── Outputs ─────────────────────────────────────────────────────────────────
output logicAppName string = logicApp.name
output logicAppResourceId string = logicApp.id
output storageAccountName string = storageAccount.name
output sqlServerName string = sqlServer.name
output sqlServerFqdn string = sqlServer.properties.fullyQualifiedDomainName
output sqlDatabaseName string = sqlDatabase.name
output formRecognizerName string = formRecognizer.name
output formRecognizerEndpoint string = formRecognizer.properties.endpoint
output userAssignedIdentityPrincipalId string = userIdentity.properties.principalId
output userAssignedIdentityClientId string = userIdentity.properties.clientId
output userAssignedIdentityResourceId string = userIdentity.id
output office365ConnectionId string = office365Connection.id
#disable-next-line BCP053
output office365ConnectionRuntimeUrl string = office365Connection.properties.connectionRuntimeUrl
