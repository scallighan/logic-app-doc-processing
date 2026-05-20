targetScope = 'subscription'

@description('Azure subscription ID')
param subscriptionId string = subscription().subscriptionId

@description('Azure region for all resources')
param location string = 'EastUS2'

@description('GitHub repository in owner/repo format')
param ghRepo string

@description('Object ID of the deploying principal (for Key Vault and SQL admin)')
param deployerObjectId string = ''

@description('Object ID for SQL AAD admin (defaults to deployerObjectId)')
param sqlAdminObjectId string = deployerObjectId

@description('Client ID / app ID for SQL AAD admin login')
param sqlAdminClientId string = ''

var repoName = split(ghRepo, '/')[1]
var locForNaming = toLower(replace(location, ' ', ''))
var uniqueSuffix = substring(uniqueString(subscription().subscriptionId, ghRepo, location), 0, 8)

resource rg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: 'rg-${repoName}-${uniqueSuffix}-${locForNaming}'
  location: location
  tags: {
    managed_by: 'bicep'
    repo: repoName
  }
}

module resources 'resources.bicep' = {
  scope: rg
  name: 'resources-deployment'
  params: {
    location: location
    ghRepo: ghRepo
    subscriptionId: subscriptionId
    deployerObjectId: deployerObjectId
    sqlAdminObjectId: sqlAdminObjectId
    sqlAdminClientId: sqlAdminClientId
  }
}

output resourceGroupName string = rg.name
output logicAppName string = resources.outputs.logicAppName
output logicAppResourceId string = resources.outputs.logicAppResourceId
output sqlServerFqdn string = resources.outputs.sqlServerFqdn
output sqlDatabaseName string = resources.outputs.sqlDatabaseName
output formRecognizerEndpoint string = resources.outputs.formRecognizerEndpoint
output userAssignedIdentityClientId string = resources.outputs.userAssignedIdentityClientId
output userAssignedIdentityResourceId string = resources.outputs.userAssignedIdentityResourceId
output office365ConnectionId string = resources.outputs.office365ConnectionId
output office365ConnectionRuntimeUrl string = resources.outputs.office365ConnectionRuntimeUrl
