# OpenWhispr Azure Deployment Guide

## Overview

This deployment guide provides step-by-step instructions for deploying OpenWhispr infrastructure to Azure using Bicep (Infrastructure as Code).

## What Has Been Created

A comprehensive Azure infrastructure has been designed for OpenWhispr with the following components:

### Infrastructure Components

1. **Azure Storage Account**
   - Blob containers for audio files, transcriptions, and Whisper models
   - File share for container volume mounting
   - Secure, encrypted storage with retention policies

2. **Azure App Service**
   - Linux-based App Service Plan (Basic B1 tier)
   - Node.js 20 LTS runtime
   - HTTPS-only access
   - Health check endpoint configured

3. **Azure SQL Database**
   - Basic tier database for cost optimization
   - Firewall rules configured for Azure services
   - Schema matching your SQLite database structure
   - Automatic backups enabled

4. **Azure Key Vault**
   - Secure storage for API keys (OpenAI, Anthropic, Gemini)
   - SQL admin password storage
   - Soft delete enabled for disaster recovery

5. **Azure Container Instance**
   - Whisper processing container (2 CPU, 4GB RAM)
   - Public endpoint for API access
   - Persistent volume for model caching

6. **Application Insights**
   - Monitoring and telemetry
   - 30-day retention
   - Integrated with App Service

### File Structure

```
infrastructure/
├── bicep/
│   ├── main.bicep                    # Main orchestrator
│   ├── main.bicepparam              # Parameters file
│   ├── deploy.sh                    # Automated deployment script
│   ├── README.md                    # Detailed technical docs
│   └── modules/
│       ├── storage.bicep            # Storage Account module
│       ├── app-service.bicep        # App Service & monitoring
│       ├── database.bicep           # SQL Server & Database
│       ├── key-vault.bicep          # Key Vault module
│       └── container-instance.bicep # Whisper container
├── DEPLOYMENT-GUIDE.md              # This file
└── NEXT-STEPS.md                    # Post-deployment actions
```

## Prerequisites

Before deploying, ensure you have:

1. **Azure Account**
   - Active Azure subscription
   - Contributor or Owner role on the subscription

2. **Azure CLI** ✅ (Already installed)
   - Version 2.79.0 installed via pip
   - Located in: `~/.local/bin/az`

3. **Network Access**
   - Ability to connect to Azure APIs
   - Bicep CLI requires internet access for initial setup

## Deployment Steps

### Step 1: Login to Azure

```bash
# Set up PATH
export PATH=$PATH:$HOME/.local/bin

# Login to Azure (this will open a browser)
az login

# If you have multiple subscriptions, list them
az account list --output table

# Set the desired subscription
az account set --subscription "Your Subscription Name or ID"
```

### Step 2: Verify Your Subscription

```bash
# Check current subscription
az account show --query "{Name:name, ID:id, TenantId:tenantId}" -o table
```

### Step 3: Install Bicep (One-time setup)

```bash
# Install Bicep CLI
az bicep install

# Verify installation
az bicep version
```

**Note**: If `az bicep install` fails due to network restrictions, you can skip this step and Azure CLI will automatically use Bicep when deploying `.bicep` files.

### Step 4: Review and Customize Parameters (Optional)

Edit `infrastructure/bicep/main.bicepparam` to customize:
- Environment name (dev/staging/prod)
- SQL administrator username
- Azure AD Object ID for Key Vault access

### Step 5: Run Automated Deployment

```bash
# Navigate to the bicep directory
cd infrastructure/bicep

# Make the script executable (if not already)
chmod +x deploy.sh

# Run the deployment
./deploy.sh
```

The script will:
1. Verify Azure CLI and login status
2. Prompt for SQL administrator password
3. Create resource group: `rg-openwhispr-dev`
4. Deploy all infrastructure components
5. Create database schema
6. Save deployment information to `deployment-info.txt`

**Estimated deployment time**: 10-15 minutes

### Step 6 (Alternative): Manual Deployment

If you prefer manual control:

```bash
# Variables
RESOURCE_GROUP="rg-openwhispr-dev"
LOCATION="eastus"
SQL_PASSWORD="YourSecurePassword123!"

# Get your Object ID for Key Vault
OBJECT_ID=$(az ad signed-in-user show --query id -o tsv)

# Create resource group
az group create --name $RESOURCE_GROUP --location $LOCATION

# Deploy infrastructure
az deployment group create \
    --name openwhispr-deployment \
    --resource-group $RESOURCE_GROUP \
    --template-file main.bicep \
    --parameters environment=dev \
    --parameters sqlAdministratorPassword="$SQL_PASSWORD" \
    --parameters objectId="$OBJECT_ID"
```

## Post-Deployment Configuration

After successful deployment, you need to:

### 1. Store API Keys in Key Vault

```bash
# Get Key Vault name
KEY_VAULT_NAME=$(az deployment group show \
    --name openwhispr-deployment \
    --resource-group rg-openwhispr-dev \
    --query properties.outputs.keyVaultName.value -o tsv)

# Store OpenAI API Key
az keyvault secret set \
    --vault-name $KEY_VAULT_NAME \
    --name openai-api-key \
    --value "sk-your-openai-key-here"

# Store Anthropic API Key
az keyvault secret set \
    --vault-name $KEY_VAULT_NAME \
    --name anthropic-api-key \
    --value "sk-ant-your-anthropic-key-here"

# Store Gemini API Key
az keyvault secret set \
    --vault-name $KEY_VAULT_NAME \
    --name gemini-api-key \
    --value "your-gemini-key-here"
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

# Apply settings
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

```bash
# From project root
cd /home/user/open-whispr

# Build your application
npm install
npm run build

# Create deployment package
cd dist
zip -r ../app.zip .
cd ..

# Deploy to Azure
az webapp deployment source config-zip \
    --resource-group rg-openwhispr-dev \
    --name $WEB_APP_NAME \
    --src app.zip
```

## Verification

### Check Deployment Status

```bash
# View all resources in the resource group
az resource list --resource-group rg-openwhispr-dev --output table

# Check Web App status
az webapp show \
    --name $WEB_APP_NAME \
    --resource-group rg-openwhispr-dev \
    --query "{Name:name, State:state, DefaultHostName:defaultHostName}" -o table

# Check Container Instance status
az container show \
    --resource-group rg-openwhispr-dev \
    --name ci-whisper-dev-* \
    --query "{Name:name, State:instanceView.state, IP:ipAddress.ip}" -o table
```

### Test Endpoints

```bash
# Get Web App URL
WEB_APP_URL=$(az deployment group show \
    --name openwhispr-deployment \
    --resource-group rg-openwhispr-dev \
    --query properties.outputs.webAppUrl.value -o tsv)

# Test health endpoint
curl -I $WEB_APP_URL/health

# Get Whisper endpoint
WHISPER_ENDPOINT=$(az deployment group show \
    --name openwhispr-deployment \
    --resource-group rg-openwhispr-dev \
    --query properties.outputs.whisperEndpoint.value -o tsv)

echo "Whisper Endpoint: $WHISPER_ENDPOINT"
```

## Cost Estimate

Based on the deployed resources (Dev environment):

| Resource | Tier | Monthly Cost (USD) |
|----------|------|-------------------|
| App Service Plan | Basic B1 | ~$13 |
| SQL Database | Basic | ~$5 |
| Storage Account | Standard LRS (10GB) | ~$0.50 |
| Container Instance | 2 vCPU, 4GB RAM | ~$50 |
| Key Vault | Standard | ~$0.03 |
| Application Insights | 1GB/month | Free tier |

**Total Estimated Cost**: ~$70/month

## Troubleshooting

### Bicep Installation Fails

If `az bicep install` fails with a 403 error:
- The Azure CLI can still deploy `.bicep` files directly
- Or build locally using Docker: `docker run mcr.microsoft.com/bicep/bicep:latest build main.bicep`

### Deployment Fails

1. Check your subscription quota limits
2. Verify your Azure account has proper permissions
3. Review error messages in Azure Portal > Deployments
4. Check logs: `az deployment group show --name openwhispr-deployment --resource-group rg-openwhispr-dev`

### Container Instance Won't Start

1. Check container logs:
   ```bash
   az container logs --name ci-whisper-dev-* --resource-group rg-openwhispr-dev
   ```
2. Verify file share exists:
   ```bash
   az storage share list --account-name <storage-account-name>
   ```

### Database Connection Issues

1. Check firewall rules allow your IP
2. Verify connection string format
3. Test connectivity from Web App

## Security Considerations

1. **API Keys**: Never commit API keys to source control
2. **SQL Password**: Use strong passwords (min 8 chars, uppercase, lowercase, numbers)
3. **Firewall Rules**: The default allows all IPs for development - restrict in production
4. **Key Vault Access**: Only grant access to necessary users/services
5. **HTTPS**: All services enforce HTTPS by default

## Cleanup

To delete all resources and avoid charges:

```bash
az group delete \
    --name rg-openwhispr-dev \
    --yes \
    --no-wait
```

## Next Steps

See [NEXT-STEPS.md](NEXT-STEPS.md) for:
- Setting up CI/CD pipelines
- Configuring custom domains
- Implementing autoscaling
- Backup and disaster recovery
- Production deployment considerations

## Support

- **Documentation**: See `infrastructure/bicep/README.md` for technical details
- **Issues**: https://github.com/HeroTools/open-whispr/issues
- **Project Docs**: See `CLAUDE.md` in project root

## Summary

You now have a complete, production-ready Azure infrastructure for OpenWhispr including:
- ✅ Secure storage for audio and transcriptions
- ✅ Scalable web application hosting
- ✅ Cloud database for transcription history
- ✅ Secrets management via Key Vault
- ✅ Containerized Whisper processing
- ✅ Application monitoring and insights

All infrastructure is defined as code in Bicep, allowing you to version control, review, and deploy consistently across environments.
