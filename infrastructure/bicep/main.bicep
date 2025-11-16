// Main Bicep file for OpenWhispr Azure Infrastructure
targetScope = 'resourceGroup'

// Parameters
@description('The Azure region where resources will be deployed')
param location string = resourceGroup().location

@description('Environment name (dev, staging, prod)')
@allowed(['dev', 'staging', 'prod'])
param environment string = 'dev'

@description('Unique suffix for resource names')
param uniqueSuffix string = uniqueString(resourceGroup().id)

@description('SQL Administrator login username')
param sqlAdministratorLogin string = 'openwhispr-admin'

@description('SQL Administrator password')
@secure()
param sqlAdministratorPassword string

@description('Azure AD Tenant ID')
param tenantId string = subscription().tenantId

@description('Azure AD Object ID for Key Vault access (optional)')
param objectId string = ''

// Tags
var tags = {
  application: 'OpenWhispr'
  environment: environment
  managedBy: 'Bicep'
  deployedAt: utcNow()
}

// Resource names
var storageAccountName = 'stow${environment}${uniqueSuffix}'
var appServicePlanName = 'asp-openwhispr-${environment}'
var webAppName = 'app-openwhispr-${environment}-${uniqueSuffix}'
var applicationInsightsName = 'appi-openwhispr-${environment}'
var sqlServerName = 'sql-openwhispr-${environment}-${uniqueSuffix}'
var sqlDatabaseName = 'sqldb-openwhispr-${environment}'
var keyVaultName = 'kv-ow-${environment}-${uniqueSuffix}'
var containerGroupName = 'ci-whisper-${environment}-${uniqueSuffix}'

// Deploy Storage Account
module storage 'modules/storage.bicep' = {
  name: 'storage-deployment'
  params: {
    location: location
    storageAccountName: storageAccountName
    tags: tags
  }
}

// Deploy App Service
module appService 'modules/app-service.bicep' = {
  name: 'appservice-deployment'
  params: {
    location: location
    appServicePlanName: appServicePlanName
    webAppName: webAppName
    applicationInsightsName: applicationInsightsName
    tags: tags
  }
}

// Deploy Database
module database 'modules/database.bicep' = {
  name: 'database-deployment'
  params: {
    location: location
    sqlServerName: sqlServerName
    sqlDatabaseName: sqlDatabaseName
    sqlAdministratorLogin: sqlAdministratorLogin
    sqlAdministratorPassword: sqlAdministratorPassword
    tags: tags
  }
}

// Deploy Key Vault
module keyVault 'modules/key-vault.bicep' = {
  name: 'keyvault-deployment'
  params: {
    location: location
    keyVaultName: keyVaultName
    tenantId: tenantId
    objectId: objectId
    tags: tags
  }
}

// Deploy Container Instance for Whisper
module containerInstance 'modules/container-instance.bicep' = {
  name: 'containerinstance-deployment'
  params: {
    location: location
    containerGroupName: containerGroupName
    storageAccountName: storage.outputs.storageAccountName
    storageAccountKey: storage.outputs.primaryKey
    tags: tags
  }
  dependsOn: [
    storage
  ]
}

// Create File Share for Whisper models
resource storageAccount 'Microsoft.Storage/storageAccounts@2023-01-01' existing = {
  name: storageAccountName
}

resource fileService 'Microsoft.Storage/storageAccounts/fileServices@2023-01-01' = {
  parent: storageAccount
  name: 'default'
}

resource fileShare 'Microsoft.Storage/storageAccounts/fileServices/shares@2023-01-01' = {
  parent: fileService
  name: 'whisper-models'
  properties: {
    shareQuota: 5120
  }
  dependsOn: [
    storage
  ]
}

// Outputs
output storageAccountName string = storage.outputs.storageAccountName
output storageConnectionString string = storage.outputs.connectionString
output webAppUrl string = 'https://${appService.outputs.webAppDefaultHostName}'
output webAppName string = appService.outputs.webAppName
output applicationInsightsInstrumentationKey string = appService.outputs.applicationInsightsInstrumentationKey
output sqlServerFqdn string = database.outputs.sqlServerFqdn
output sqlDatabaseName string = database.outputs.sqlDatabaseName
output sqlConnectionString string = database.outputs.connectionString
output keyVaultName string = keyVault.outputs.keyVaultName
output keyVaultUri string = keyVault.outputs.keyVaultUri
output whisperEndpoint string = containerInstance.outputs.whisperEndpoint
output resourceGroupName string = resourceGroup().name
