#!/bin/bash

# Script to grant Microsoft Graph permissions to the deployment script's managed identity
# This allows the managed identity to create Entra ID app registrations

set -e

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Grant App Registration Permissions${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

# Check if Azure CLI is installed
if ! command -v az &> /dev/null; then
    echo -e "${RED}Error: Azure CLI is not installed.${NC}"
    exit 1
fi

# Check if logged in
if ! az account show &> /dev/null; then
    echo -e "${RED}Error: Not logged in to Azure.${NC}"
    echo "Please run: az login"
    exit 1
fi

# Get parameters
RESOURCE_GROUP="${1:-rg-openwhispr-dev}"
ENVIRONMENT="${2:-dev}"

echo -e "${YELLOW}Resource Group: ${RESOURCE_GROUP}${NC}"
echo -e "${YELLOW}Environment: ${ENVIRONMENT}${NC}"
echo ""

# Get the managed identity
MANAGED_IDENTITY_NAME="id-OpenWhispr-${ENVIRONMENT}-deployer"

echo -e "${YELLOW}Looking for managed identity: ${MANAGED_IDENTITY_NAME}${NC}"
MANAGED_IDENTITY_ID=$(az identity show \
    --name "${MANAGED_IDENTITY_NAME}" \
    --resource-group "${RESOURCE_GROUP}" \
    --query principalId -o tsv 2>/dev/null)

if [ -z "$MANAGED_IDENTITY_ID" ]; then
    echo -e "${RED}Error: Managed identity not found.${NC}"
    echo "Make sure you've run the initial deployment first."
    echo "The managed identity is created during the first deployment."
    exit 1
fi

echo -e "${GREEN}Found managed identity: ${MANAGED_IDENTITY_ID}${NC}"
echo ""

# Get Microsoft Graph App ID
GRAPH_APP_ID="00000003-0000-0000-c000-000000000000"

# Get the service principal for Microsoft Graph
echo -e "${YELLOW}Getting Microsoft Graph service principal...${NC}"
GRAPH_SP_ID=$(az ad sp show --id $GRAPH_APP_ID --query id -o tsv)

echo -e "${GREEN}Microsoft Graph SP ID: ${GRAPH_SP_ID}${NC}"
echo ""

# Required permissions
echo -e "${YELLOW}Granting permissions to create app registrations...${NC}"
echo "This requires Global Administrator or Privileged Role Administrator role."
echo ""

# Application.ReadWrite.All permission
APP_ROLE_ID="1bfefb4e-e0b5-418b-a88f-73c46d2cc8e9"

# Grant the permission using Azure CLI
# Note: This requires admin consent
az rest --method POST \
    --uri "https://graph.microsoft.com/v1.0/servicePrincipals/${GRAPH_SP_ID}/appRoleAssignedTo" \
    --headers "Content-Type=application/json" \
    --body "{
        \"principalId\": \"${MANAGED_IDENTITY_ID}\",
        \"resourceId\": \"${GRAPH_SP_ID}\",
        \"appRoleId\": \"${APP_ROLE_ID}\"
    }" || {
        echo -e "${RED}Failed to grant permissions via API.${NC}"
        echo ""
        echo -e "${YELLOW}Alternative: Grant permissions manually:${NC}"
        echo "1. Go to Azure Portal > Entra ID > Enterprise Applications"
        echo "2. Find the managed identity: ${MANAGED_IDENTITY_NAME}"
        echo "3. Go to 'Permissions' > 'Add a permission'"
        echo "4. Select 'Microsoft Graph' > 'Application permissions'"
        echo "5. Select 'Application.ReadWrite.All'"
        echo "6. Click 'Add permissions' then 'Grant admin consent'"
        exit 1
    }

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Permissions granted successfully!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo "The managed identity can now create app registrations."
echo "You can proceed with the deployment."
