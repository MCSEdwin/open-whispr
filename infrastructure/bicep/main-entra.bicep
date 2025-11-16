// Main Bicep file for OpenWhispr Azure Infrastructure with Entra ID SSO
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

@description('Enable Entra ID SSO Authentication')
param enableEntraIdAuth bool = true

// Tags
var tags = {
  application: 'OpenWhispr'
  environment: environment
  managedBy: 'Bicep'
  deployedAt: utcNow()
  ssoEnabled: string(enableEntraIdAuth)
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
var appRegistrationName = 'OpenWhispr-${toUpper(environment)}'

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

// ========================================
// ENTRA ID SSO CONFIGURATION
// ========================================

// Deploy Entra ID App Registration
module entraIdApp 'modules/entra-id-app.bicep' = if (enableEntraIdAuth) {
  name: 'entraid-deployment'
  params: {
    location: location
    appName: appRegistrationName
    webAppUrl: 'https://${appService.outputs.webAppDefaultHostName}'
    tenantId: tenantId
    tags: tags
  }
  dependsOn: [
    appService
  ]
}

// Grant Managed Identity permissions to create app registrations
// This requires the deployment script's managed identity to have appropriate permissions
resource roleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (enableEntraIdAuth) {
  name: guid(resourceGroup().id, 'Application.ReadWrite.All')
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '18d7d88d-d35e-4fb5-a5c3-7773c20a72d9') // User Access Administrator
    principalId: enableEntraIdAuth ? entraIdApp.outputs.managedIdentityPrincipalId : ''
    principalType: 'ServicePrincipal'
  }
  dependsOn: [
    entraIdApp
  ]
}

// Configure App Service Authentication
module appServiceAuth 'modules/app-service-auth.bicep' = if (enableEntraIdAuth) {
  name: 'appservice-auth-deployment'
  params: {
    webAppName: appService.outputs.webAppName
    clientId: enableEntraIdAuth ? entraIdApp.outputs.appId : ''
    clientSecret: enableEntraIdAuth ? entraIdApp.outputs.clientSecret : ''
    tenantId: tenantId
  }
  dependsOn: [
    appService
    entraIdApp
  ]
}

// Store Entra ID configuration in Key Vault
resource entraIdClientIdSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = if (enableEntraIdAuth) {
  name: '${keyVaultName}/entra-client-id'
  properties: {
    value: enableEntraIdAuth ? entraIdApp.outputs.appId : 'not-configured'
  }
  dependsOn: [
    keyVault
    entraIdApp
  ]
}

resource entraIdClientSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = if (enableEntraIdAuth) {
  name: '${keyVaultName}/entra-client-secret'
  properties: {
    value: enableEntraIdAuth ? entraIdApp.outputs.clientSecret : 'not-configured'
  }
  dependsOn: [
    keyVault
    entraIdApp
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

// Entra ID Outputs
output entraIdEnabled bool = enableEntraIdAuth
output entraIdAppId string = enableEntraIdAuth ? entraIdApp.outputs.appId : 'Not configured'
output entraIdTenantId string = enableEntraIdAuth ? tenantId : 'Not configured'
output entraIdServicePrincipalId string = enableEntraIdAuth ? entraIdApp.outputs.servicePrincipalId : 'Not configured'
output authenticationLoginUrl string = enableEntraIdAuth ? 'https://${appService.outputs.webAppDefaultHostName}/.auth/login/aad' : 'Authentication not enabled'
