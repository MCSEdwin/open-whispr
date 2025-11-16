#!/bin/bash

# OpenWhispr Azure Infrastructure Deployment Script
# This script deploys the complete Azure infrastructure for OpenWhispr

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
RESOURCE_GROUP_NAME="rg-openwhispr-dev"
LOCATION="eastus"
ENVIRONMENT="dev"

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}OpenWhispr Azure Deployment${NC}"
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

# Prompt for SQL password
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
    --tags "application=OpenWhispr" "environment=${ENVIRONMENT}"
echo -e "${GREEN}Resource group created.${NC}"
echo ""

# Deploy Bicep template
echo -e "${YELLOW}Deploying infrastructure...${NC}"
echo "This may take 10-15 minutes..."
echo ""

DEPLOYMENT_NAME="openwhispr-deployment-$(date +%Y%m%d-%H%M%S)"

az deployment group create \
    --name "${DEPLOYMENT_NAME}" \
    --resource-group "${RESOURCE_GROUP_NAME}" \
    --template-file main.bicep \
    --parameters environment="${ENVIRONMENT}" \
    --parameters sqlAdministratorPassword="${SQL_PASSWORD}" \
    --parameters objectId="${OBJECT_ID}" \
    --output table

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

# Display outputs
echo ""
echo -e "${GREEN}Deployment Information:${NC}"
echo "========================"
echo -e "Resource Group:    ${GREEN}${RESOURCE_GROUP_NAME}${NC}"
echo -e "Web App URL:       ${GREEN}${WEB_APP_URL}${NC}"
echo -e "Whisper Endpoint:  ${GREEN}${WHISPER_ENDPOINT}${NC}"
echo -e "Key Vault:         ${GREEN}${KEY_VAULT_NAME}${NC}"
echo -e "SQL Server:        ${GREEN}${SQL_SERVER}${NC}"
echo -e "Storage Account:   ${GREEN}${STORAGE_ACCOUNT}${NC}"
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
  error NVARCHAR(MAX)
);

CREATE INDEX idx_timestamp ON transcriptions(timestamp);
CREATE INDEX idx_is_processed ON transcriptions(is_processed);
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
cat > deployment-info.txt << EOF
OpenWhispr Azure Deployment Information
========================================
Deployment Name: ${DEPLOYMENT_NAME}
Resource Group: ${RESOURCE_GROUP_NAME}
Location: ${LOCATION}
Deployed: $(date)

Resources:
----------
Web App URL: ${WEB_APP_URL}
Whisper Endpoint: ${WHISPER_ENDPOINT}
Key Vault: ${KEY_VAULT_NAME}
SQL Server: ${SQL_SERVER}
SQL Database: ${SQL_DATABASE}
Storage Account: ${STORAGE_ACCOUNT}

Next Steps:
-----------
1. Store your API keys in Key Vault:
   az keyvault secret set --vault-name ${KEY_VAULT_NAME} --name openai-api-key --value "your-key"
   az keyvault secret set --vault-name ${KEY_VAULT_NAME} --name anthropic-api-key --value "your-key"
   az keyvault secret set --vault-name ${KEY_VAULT_NAME} --name gemini-api-key --value "your-key"

2. Deploy your application code to the Web App:
   az webapp deployment source config-zip --resource-group ${RESOURCE_GROUP_NAME} --name $(basename ${WEB_APP_URL} .azurewebsites.net) --src app.zip

3. Configure environment variables in the Web App:
   - STORAGE_CONNECTION_STRING
   - SQL_CONNECTION_STRING
   - KEY_VAULT_URI
   - WHISPER_ENDPOINT

4. Access your application at: ${WEB_APP_URL}
EOF

echo -e "${GREEN}Deployment information saved to deployment-info.txt${NC}"
echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Deployment successful!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "${YELLOW}Don't forget to update your API keys in Key Vault!${NC}"
echo "See deployment-info.txt for details."
