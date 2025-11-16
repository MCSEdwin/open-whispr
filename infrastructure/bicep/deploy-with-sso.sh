#!/bin/bash

# OpenWhispr Azure Infrastructure Deployment Script with Entra ID SSO
# This script deploys the complete Azure infrastructure with Entra ID authentication

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
RESOURCE_GROUP_NAME="rg-openwhispr-dev"
LOCATION="eastus"
ENVIRONMENT="dev"

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}OpenWhispr Azure Deployment with SSO${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

# Check if Azure CLI is installed
if ! command -v az &> /dev/null; then
    echo -e "${RED}Error: Azure CLI is not installed.${NC}"
    echo "Please install it from: https://docs.microsoft.com/en-us/cli/azure/install-azure-cli"
    exit 1
fi

# Check if logged in to Azure
echo -e "${YELLOW}Checking Azure login status...${NC}"
if ! az account show &> /dev/null; then
    echo -e "${RED}Error: Not logged in to Azure.${NC}"
    echo "Please run: az login"
    exit 1
fi

# Display current subscription
SUBSCRIPTION_NAME=$(az account show --query name -o tsv)
SUBSCRIPTION_ID=$(az account show --query id -o tsv)
echo -e "${GREEN}Current subscription: ${SUBSCRIPTION_NAME} (${SUBSCRIPTION_ID})${NC}"
echo ""

# Check if user has required permissions
echo -e "${YELLOW}Checking permissions...${NC}"
USER_ROLES=$(az role assignment list --assignee $(az ad signed-in-user show --query id -o tsv) --query "[?scope=='/subscriptions/${SUBSCRIPTION_ID}'].roleDefinitionName" -o tsv)

if [[ ! "$USER_ROLES" =~ "Owner" ]] && [[ ! "$USER_ROLES" =~ "User Access Administrator" ]]; then
    echo -e "${YELLOW}Warning: You may need 'Owner' or 'User Access Administrator' role to create app registrations.${NC}"
    echo -e "${YELLOW}The deployment will continue, but Entra ID setup may require additional permissions.${NC}"
    read -p "Continue anyway? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

# Prompt for SQL password
echo -e "${BLUE}=== SQL Database Configuration ===${NC}"
read -sp "Enter SQL Administrator Password (min 8 chars, must include uppercase, lowercase, number): " SQL_PASSWORD
echo ""
read -sp "Confirm SQL Administrator Password: " SQL_PASSWORD_CONFIRM
echo ""

if [ "$SQL_PASSWORD" != "$SQL_PASSWORD_CONFIRM" ]; then
    echo -e "${RED}Error: Passwords do not match.${NC}"
    exit 1
fi

# Get current user's Object ID for Key Vault access
echo -e "${YELLOW}Getting your Azure AD Object ID...${NC}"
OBJECT_ID=$(az ad signed-in-user show --query id -o tsv)
echo -e "${GREEN}Object ID: ${OBJECT_ID}${NC}"
echo ""

# Create resource group
echo -e "${YELLOW}Creating resource group: ${RESOURCE_GROUP_NAME} in ${LOCATION}...${NC}"
az group create \
    --name "${RESOURCE_GROUP_NAME}" \
    --location "${LOCATION}" \
    --tags "application=OpenWhispr" "environment=${ENVIRONMENT}" "sso=enabled"
echo -e "${GREEN}Resource group created.${NC}"
echo ""

# Important: Grant permissions to create app registrations
echo -e "${BLUE}=== Entra ID Permissions Setup ===${NC}"
echo -e "${YELLOW}For Entra ID app registration, the deployment script needs permissions.${NC}"
echo -e "${YELLOW}We'll grant these permissions after the deployment script identity is created.${NC}"
echo ""

# Deploy Bicep template
echo -e "${YELLOW}Deploying infrastructure with Entra ID SSO...${NC}"
echo "This may take 15-20 minutes..."
echo ""

DEPLOYMENT_NAME="openwhispr-sso-deployment-$(date +%Y%m%d-%H%M%S)"

az deployment group create \
    --name "${DEPLOYMENT_NAME}" \
    --resource-group "${RESOURCE_GROUP_NAME}" \
    --template-file main-entra.bicep \
    --parameters environment="${ENVIRONMENT}" \
    --parameters sqlAdministratorPassword="${SQL_PASSWORD}" \
    --parameters objectId="${OBJECT_ID}" \
    --parameters enableEntraIdAuth=true \
    --output table

# Check if deployment succeeded
if [ $? -ne 0 ]; then
    echo -e "${RED}Deployment failed. Checking for permission issues...${NC}"
    echo ""
    echo -e "${YELLOW}If the error is related to app registration permissions:${NC}"
    echo "1. The managed identity needs 'Application.ReadWrite.All' permission in Microsoft Graph"
    echo "2. Run the post-deployment script: ./grant-app-registration-permissions.sh"
    echo "3. Then retry the deployment"
    exit 1
fi

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Deployment Complete!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

# Get outputs
echo -e "${YELLOW}Retrieving deployment outputs...${NC}"
WEB_APP_URL=$(az deployment group show \
    --name "${DEPLOYMENT_NAME}" \
    --resource-group "${RESOURCE_GROUP_NAME}" \
    --query properties.outputs.webAppUrl.value -o tsv)

WHISPER_ENDPOINT=$(az deployment group show \
    --name "${DEPLOYMENT_NAME}" \
    --resource-group "${RESOURCE_GROUP_NAME}" \
    --query properties.outputs.whisperEndpoint.value -o tsv)

KEY_VAULT_NAME=$(az deployment group show \
    --name "${DEPLOYMENT_NAME}" \
    --resource-group "${RESOURCE_GROUP_NAME}" \
    --query properties.outputs.keyVaultName.value -o tsv)

SQL_SERVER=$(az deployment group show \
    --name "${DEPLOYMENT_NAME}" \
    --resource-group "${RESOURCE_GROUP_NAME}" \
    --query properties.outputs.sqlServerFqdn.value -o tsv)

STORAGE_ACCOUNT=$(az deployment group show \
    --name "${DEPLOYMENT_NAME}" \
    --resource-group "${RESOURCE_GROUP_NAME}" \
    --query properties.outputs.storageAccountName.value -o tsv)

# Entra ID outputs
ENTRA_APP_ID=$(az deployment group show \
    --name "${DEPLOYMENT_NAME}" \
    --resource-group "${RESOURCE_GROUP_NAME}" \
    --query properties.outputs.entraIdAppId.value -o tsv 2>/dev/null || echo "Check deployment logs")

ENTRA_TENANT_ID=$(az deployment group show \
    --name "${DEPLOYMENT_NAME}" \
    --resource-group "${RESOURCE_GROUP_NAME}" \
    --query properties.outputs.entraIdTenantId.value -o tsv 2>/dev/null || echo "Check deployment logs")

AUTH_LOGIN_URL=$(az deployment group show \
    --name "${DEPLOYMENT_NAME}" \
    --resource-group "${RESOURCE_GROUP_NAME}" \
    --query properties.outputs.authenticationLoginUrl.value -o tsv 2>/dev/null || echo "Check deployment logs")

# Display outputs
echo ""
echo -e "${GREEN}Deployment Information:${NC}"
echo "========================"
echo -e "Resource Group:    ${GREEN}${RESOURCE_GROUP_NAME}${NC}"
echo -e "Web App URL:       ${GREEN}${WEB_APP_URL}${NC}"
echo -e "Auth Login URL:    ${GREEN}${AUTH_LOGIN_URL}${NC}"
echo -e "Whisper Endpoint:  ${GREEN}${WHISPER_ENDPOINT}${NC}"
echo -e "Key Vault:         ${GREEN}${KEY_VAULT_NAME}${NC}"
echo -e "SQL Server:        ${GREEN}${SQL_SERVER}${NC}"
echo -e "Storage Account:   ${GREEN}${STORAGE_ACCOUNT}${NC}"
echo ""
echo -e "${BLUE}=== Entra ID SSO Configuration ===${NC}"
echo -e "Application ID:    ${GREEN}${ENTRA_APP_ID}${NC}"
echo -e "Tenant ID:         ${GREEN}${ENTRA_TENANT_ID}${NC}"
echo ""

# Create database schema
echo -e "${YELLOW}Creating database schema...${NC}"
cat > /tmp/create_schema.sql << 'EOF'
CREATE TABLE transcriptions (
  id INT IDENTITY(1,1) PRIMARY KEY,
  timestamp DATETIME2 DEFAULT GETDATE(),
  original_text NVARCHAR(MAX) NOT NULL,
  processed_text NVARCHAR(MAX),
  is_processed BIT DEFAULT 0,
  processing_method NVARCHAR(50) DEFAULT 'none',
  agent_name NVARCHAR(100),
  error NVARCHAR(MAX),
  user_id NVARCHAR(450),
  user_email NVARCHAR(255)
);

CREATE INDEX idx_timestamp ON transcriptions(timestamp);
CREATE INDEX idx_is_processed ON transcriptions(is_processed);
CREATE INDEX idx_user_id ON transcriptions(user_id);
EOF

SQL_DATABASE=$(az deployment group show \
    --name "${DEPLOYMENT_NAME}" \
    --resource-group "${RESOURCE_GROUP_NAME}" \
    --query properties.outputs.sqlDatabaseName.value -o tsv)

echo "Executing SQL schema on ${SQL_DATABASE}..."
az sql db query \
    --server "${SQL_SERVER%.database.windows.net}" \
    --database "${SQL_DATABASE}" \
    --resource-group "${RESOURCE_GROUP_NAME}" \
    --admin-user "openwhispr-admin" \
    --admin-password "${SQL_PASSWORD}" \
    --query-string @/tmp/create_schema.sql || echo -e "${YELLOW}Note: You may need to run the schema manually. SQL file saved to /tmp/create_schema.sql${NC}"

rm -f /tmp/create_schema.sql
echo -e "${GREEN}Database schema created.${NC}"
echo ""

# Save deployment info
cat > deployment-info-sso.txt << EOF
OpenWhispr Azure Deployment with Entra ID SSO
==============================================
Deployment Name: ${DEPLOYMENT_NAME}
Resource Group: ${RESOURCE_GROUP_NAME}
Location: ${LOCATION}
Deployed: $(date)
SSO Enabled: Yes

Resources:
----------
Web App URL: ${WEB_APP_URL}
Authentication URL: ${AUTH_LOGIN_URL}
Whisper Endpoint: ${WHISPER_ENDPOINT}
Key Vault: ${KEY_VAULT_NAME}
SQL Server: ${SQL_SERVER}
SQL Database: ${SQL_DATABASE}
Storage Account: ${STORAGE_ACCOUNT}

Entra ID Configuration:
-----------------------
Application (Client) ID: ${ENTRA_APP_ID}
Directory (Tenant) ID: ${ENTRA_TENANT_ID}
App Registration Name: OpenWhispr-${ENVIRONMENT^^}

How to Access:
--------------
1. Navigate to: ${WEB_APP_URL}
2. You will be redirected to Microsoft login
3. Sign in with your organizational account
4. Grant consent if prompted

User Management:
----------------
To grant users access to the application:

1. Go to Azure Portal > Entra ID > Enterprise Applications
2. Find "OpenWhispr-${ENVIRONMENT^^}"
3. Go to "Users and groups"
4. Click "Add user/group"
5. Select users and assign roles:
   - Admin: Full access to all features
   - User: Basic transcription features

App Roles:
----------
- Administrator: Full access to all features
- User: Access to basic transcription features

Next Steps:
-----------
1. Assign users to the application in Entra ID:
   Portal > Entra ID > Enterprise Applications > OpenWhispr-${ENVIRONMENT^^} > Users and groups

2. Store your API keys in Key Vault:
   az keyvault secret set --vault-name ${KEY_VAULT_NAME} --name openai-api-key --value "your-key"
   az keyvault secret set --vault-name ${KEY_VAULT_NAME} --name anthropic-api-key --value "your-key"
   az keyvault secret set --vault-name ${KEY_VAULT_NAME} --name gemini-api-key --value "your-key"

3. Test the authentication:
   Open ${WEB_APP_URL} in a browser
   You should be redirected to Microsoft login

4. Deploy your application code:
   npm run build
   az webapp deployment source config-zip --resource-group ${RESOURCE_GROUP_NAME} --name $(basename ${WEB_APP_URL} .azurewebsites.net) --src app.zip

For troubleshooting, see: infrastructure/bicep/SSO-GUIDE.md
EOF

echo -e "${GREEN}Deployment information saved to deployment-info-sso.txt${NC}"
echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Deployment successful with SSO!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "${BLUE}Next Steps:${NC}"
echo "1. Assign users in Entra ID (see deployment-info-sso.txt)"
echo "2. Update API keys in Key Vault"
echo "3. Test authentication at: ${WEB_APP_URL}"
echo ""
echo -e "${YELLOW}Important: Users must be assigned to the app in Entra ID before they can sign in.${NC}"
echo "See deployment-info-sso.txt for detailed instructions."
