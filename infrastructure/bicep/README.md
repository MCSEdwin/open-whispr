# OpenWhispr Azure Infrastructure

This directory contains Bicep Infrastructure as Code (IaC) for deploying OpenWhispr to Azure.

## Architecture Overview

The infrastructure deploys the following Azure resources:

### Core Services
- **Azure App Service**: Hosts the web application backend API
- **Azure Storage Account**: Stores audio files, transcriptions, and Whisper models
- **Azure SQL Database**: Manages transcription history and metadata
- **Azure Key Vault**: Securely stores API keys and secrets
- **Azure Container Instance**: Runs Whisper model for speech-to-text processing
- **Application Insights**: Provides monitoring and telemetry

### Resource Organization
```
Resource Group: rg-openwhispr-dev
├── Storage Account (stowdev...)
│   ├── Blob Containers
│   │   ├── audio-files
│   │   ├── transcriptions
│   │   └── whisper-models
│   └── File Share
│       └── whisper-models (for container mounting)
├── App Service Plan (asp-openwhispr-dev)
├── Web App (app-openwhispr-dev-...)
├── Application Insights (appi-openwhispr-dev)
├── SQL Server (sql-openwhispr-dev-...)
│   └── Database (sqldb-openwhispr-dev)
├── Key Vault (kv-ow-dev-...)
└── Container Instance (ci-whisper-dev-...)
```

## Prerequisites

1. **Azure CLI**: Install from https://docs.microsoft.com/en-us/cli/azure/install-azure-cli
2. **Azure Subscription**: Active Azure subscription
3. **Permissions**: Contributor role on the subscription or resource group

## Installation

### Install Azure CLI

**Linux:**
```bash
curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash
```

**macOS:**
```bash
brew update && brew install azure-cli
```

**Windows:**
Download from: https://aka.ms/installazurecliwindows

### Login to Azure
```bash
az login
```

### Set Default Subscription (if you have multiple)
```bash
az account list --output table
az account set --subscription "Your Subscription Name"
```

## Deployment

### Quick Deploy

Run the automated deployment script:

```bash
cd infrastructure/bicep
./deploy.sh
```

The script will:
1. Check Azure CLI installation and login status
2. Prompt for SQL administrator password
3. Create resource group
4. Deploy all infrastructure
5. Create database schema
6. Save deployment information

### Manual Deployment

If you prefer manual control:

```bash
# Set variables
RESOURCE_GROUP="rg-openwhispr-dev"
LOCATION="eastus"
ENVIRONMENT="dev"

# Create resource group
az group create \
    --name $RESOURCE_GROUP \
    --location $LOCATION

# Get your Object ID for Key Vault access
OBJECT_ID=$(az ad signed-in-user show --query id -o tsv)

# Deploy infrastructure
az deployment group create \
    --name openwhispr-deployment \
    --resource-group $RESOURCE_GROUP \
    --template-file main.bicep \
    --parameters environment=$ENVIRONMENT \
    --parameters sqlAdministratorPassword='YourSecurePassword123!' \
    --parameters objectId=$OBJECT_ID
```

## Build Bicep to ARM Templates (Optional)

To generate ARM templates from Bicep:

```bash
# Install Bicep CLI (if not already installed)
az bicep install

# Build main template
az bicep build --file main.bicep --outfile main.json

# Build individual modules
az bicep build --file modules/storage.bicep --outfile modules/storage.json
az bicep build --file modules/app-service.bicep --outfile modules/app-service.json
az bicep build --file modules/database.bicep --outfile modules/database.json
az bicep build --file modules/key-vault.bicep --outfile modules/key-vault.json
az bicep build --file modules/container-instance.bicep --outfile modules/container-instance.json
```

## Post-Deployment Configuration

### 1. Store API Keys in Key Vault

```bash
KEY_VAULT_NAME=$(az deployment group show \
    --name openwhispr-deployment \
    --resource-group rg-openwhispr-dev \
    --query properties.outputs.keyVaultName.value -o tsv)

# Store OpenAI API Key
az keyvault secret set \
    --vault-name $KEY_VAULT_NAME \
    --name openai-api-key \
    --value "sk-your-openai-key"

# Store Anthropic API Key
az keyvault secret set \
    --vault-name $KEY_VAULT_NAME \
    --name anthropic-api-key \
    --value "sk-ant-your-anthropic-key"

# Store Gemini API Key
az keyvault secret set \
    --vault-name $KEY_VAULT_NAME \
    --name gemini-api-key \
    --value "your-gemini-key"
```

### 2. Configure Web App Environment Variables

```bash
WEB_APP_NAME=$(az deployment group show \
    --name openwhispr-deployment \
    --resource-group rg-openwhispr-dev \
    --query properties.outputs.webAppName.value -o tsv)

STORAGE_CONNECTION=$(az deployment group show \
    --name openwhispr-deployment \
    --resource-group rg-openwhispr-dev \
    --query properties.outputs.storageConnectionString.value -o tsv)

SQL_CONNECTION=$(az deployment group show \
    --name openwhispr-deployment \
    --resource-group rg-openwhispr-dev \
    --query properties.outputs.sqlConnectionString.value -o tsv)

KEY_VAULT_URI=$(az deployment group show \
    --name openwhispr-deployment \
    --resource-group rg-openwhispr-dev \
    --query properties.outputs.keyVaultUri.value -o tsv)

WHISPER_ENDPOINT=$(az deployment group show \
    --name openwhispr-deployment \
    --resource-group rg-openwhispr-dev \
    --query properties.outputs.whisperEndpoint.value -o tsv)

az webapp config appsettings set \
    --name $WEB_APP_NAME \
    --resource-group rg-openwhispr-dev \
    --settings \
        STORAGE_CONNECTION_STRING="$STORAGE_CONNECTION" \
        SQL_CONNECTION_STRING="$SQL_CONNECTION" \
        KEY_VAULT_URI="$KEY_VAULT_URI" \
        WHISPER_ENDPOINT="$WHISPER_ENDPOINT"
```

### 3. Deploy Application Code

Build and deploy your application:

```bash
# Navigate to project root
cd ../..

# Install dependencies and build
npm install
npm run build

# Create deployment package
zip -r app.zip dist/ package.json

# Deploy to Azure
az webapp deployment source config-zip \
    --resource-group rg-openwhispr-dev \
    --name $WEB_APP_NAME \
    --src app.zip
```

## Database Schema

The deployment script automatically creates the following schema:

```sql
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
```

## Monitoring and Management

### View Application Logs
```bash
az webapp log tail \
    --name $WEB_APP_NAME \
    --resource-group rg-openwhispr-dev
```

### View Application Insights
```bash
az monitor app-insights component show \
    --app appi-openwhispr-dev \
    --resource-group rg-openwhispr-dev
```

### Check Container Instance Status
```bash
az container show \
    --name $(az deployment group show \
        --name openwhispr-deployment \
        --resource-group rg-openwhispr-dev \
        --query properties.outputs.whisperEndpoint.value -o tsv | cut -d'/' -f3 | cut -d':' -f1) \
    --resource-group rg-openwhispr-dev
```

## Cost Optimization

The default deployment uses cost-effective tiers suitable for development:

- **App Service**: Basic B1 (~$13/month)
- **SQL Database**: Basic tier (~$5/month)
- **Storage Account**: Standard LRS (~$0.50/month for 10GB)
- **Container Instance**: 2 CPU, 4GB RAM (~$50/month)
- **Key Vault**: Standard (~$0.03/month)

**Total estimated cost**: ~$70/month

For production, consider:
- Upgrading App Service to Standard or Premium tier
- Upgrading SQL Database to Standard tier
- Enabling geo-redundancy for Storage Account
- Scaling Container Instance based on usage

## Cleanup

To delete all resources:

```bash
az group delete \
    --name rg-openwhispr-dev \
    --yes \
    --no-wait
```

## Troubleshooting

### Deployment Fails

1. **Check Azure CLI version**: `az version`
2. **Verify login**: `az account show`
3. **Check quota limits**: Ensure subscription has available quota
4. **Review error messages**: Check deployment logs in Azure Portal

### Container Instance Not Starting

1. Check container logs:
   ```bash
   az container logs \
       --name ci-whisper-dev-... \
       --resource-group rg-openwhispr-dev
   ```

2. Verify file share is created:
   ```bash
   az storage share list \
       --account-name stowdev... \
       --output table
   ```

### Database Connection Issues

1. Verify firewall rules allow your IP
2. Check connection string format
3. Test connectivity:
   ```bash
   az sql db show-connection-string \
       --server sql-openwhispr-dev-... \
       --name sqldb-openwhispr-dev \
       --client ado.net
   ```

## File Structure

```
infrastructure/bicep/
├── main.bicep                 # Main orchestrator
├── main.bicepparam           # Parameters file
├── deploy.sh                 # Automated deployment script
├── README.md                 # This file
└── modules/
    ├── storage.bicep         # Storage Account
    ├── app-service.bicep     # App Service & App Insights
    ├── database.bicep        # SQL Server & Database
    ├── key-vault.bicep       # Key Vault
    └── container-instance.bicep  # Whisper Container
```

## Security Considerations

1. **API Keys**: Stored in Key Vault, never in code
2. **SQL Credentials**: Passed securely at deployment time
3. **HTTPS Only**: All services enforce HTTPS
4. **Firewall Rules**: SQL Server allows Azure services only by default
5. **Soft Delete**: Key Vault has soft delete enabled (7 days)
6. **Managed Identities**: Consider enabling for App Service to access Key Vault

## Next Steps

1. Set up CI/CD pipeline (GitHub Actions, Azure DevOps)
2. Configure custom domain and SSL certificate
3. Enable autoscaling for App Service
4. Set up backup policies for SQL Database
5. Configure alerts and monitoring in Application Insights
6. Implement Azure CDN for global distribution

## Support

For issues or questions:
- GitHub Issues: https://github.com/HeroTools/open-whispr/issues
- Documentation: See CLAUDE.md in project root
