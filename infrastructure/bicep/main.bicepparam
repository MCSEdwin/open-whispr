// Parameters file for OpenWhispr Azure Infrastructure
using 'main.bicep'

// Environment configuration
param environment = 'dev'

// SQL Administrator credentials
param sqlAdministratorLogin = 'openwhispr-admin'
// Note: sqlAdministratorPassword should be provided at deployment time for security
// Use: az deployment group create --parameters sqlAdministratorPassword='YourSecurePassword123!'

// Optional: Provide your Azure AD Object ID for Key Vault access
// Get it with: az ad signed-in-user show --query id -o tsv
// param objectId = 'your-object-id-here'
