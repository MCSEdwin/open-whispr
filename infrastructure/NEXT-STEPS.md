# Post-Deployment: Next Steps for OpenWhispr Azure Infrastructure

After successfully deploying your OpenWhispr infrastructure to Azure, here are the recommended next steps to optimize, secure, and scale your deployment.

## Immediate Actions

### 1. Update API Keys in Key Vault

**Why**: The deployment created placeholder secrets. You need to update them with your actual API keys.

```bash
export PATH=$PATH:$HOME/.local/bin

# Get Key Vault name from deployment
KEY_VAULT_NAME=$(az deployment group show \
    --name openwhispr-deployment \
    --resource-group rg-openwhispr-dev \
    --query properties.outputs.keyVaultName.value -o tsv)

# Update OpenAI API Key
az keyvault secret set \
    --vault-name $KEY_VAULT_NAME \
    --name openai-api-key \
    --value "sk-your-actual-openai-key"

# Update Anthropic API Key
az keyvault secret set \
    --vault-name $KEY_VAULT_NAME \
    --name anthropic-api-key \
    --value "sk-ant-your-actual-anthropic-key"

# Update Gemini API Key
az keyvault secret set \
    --vault-name $KEY_VAULT_NAME \
    --name gemini-api-key \
    --value "your-actual-gemini-key"
```

### 2. Configure Managed Identity for Key Vault Access

**Why**: More secure than using connection strings for Key Vault access.

```bash
WEB_APP_NAME=$(az deployment group show \
    --name openwhispr-deployment \
    --resource-group rg-openwhispr-dev \
    --query properties.outputs.webAppName.value -o tsv)

# Enable system-assigned managed identity
az webapp identity assign \
    --name $WEB_APP_NAME \
    --resource-group rg-openwhispr-dev

# Get the identity's principal ID
PRINCIPAL_ID=$(az webapp identity show \
    --name $WEB_APP_NAME \
    --resource-group rg-openwhispr-dev \
    --query principalId -o tsv)

# Grant Key Vault access to the managed identity
az keyvault set-policy \
    --name $KEY_VAULT_NAME \
    --object-id $PRINCIPAL_ID \
    --secret-permissions get list
```

### 3. Test the Whisper Container

**Why**: Ensure the Whisper processing service is running correctly.

```bash
WHISPER_ENDPOINT=$(az deployment group show \
    --name openwhispr-deployment \
    --resource-group rg-openwhispr-dev \
    --query properties.outputs.whisperEndpoint.value -o tsv)

# Check container status
az container show \
    --resource-group rg-openwhispr-dev \
    --name $(echo $WHISPER_ENDPOINT | cut -d'/' -f3 | cut -d':' -f1) \
    --query "{Name:name, State:instanceView.state, IP:ipAddress.fqdn}" -o table

# Test endpoint (once container is running)
curl -X GET $WHISPER_ENDPOINT/health || echo "Endpoint not ready yet"
```

## Development Workflow

### 4. Set Up Local Development with Azure Backend

**Why**: Develop locally but use Azure services for storage and processing.

Create a `.env.local` file in your project root:

```bash
# Get connection strings
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

# Create .env.local file
cat > .env.local << EOF
AZURE_STORAGE_CONNECTION_STRING=$STORAGE_CONNECTION
AZURE_SQL_CONNECTION_STRING=$SQL_CONNECTION
AZURE_KEY_VAULT_URI=$KEY_VAULT_URI
WHISPER_ENDPOINT=$WHISPER_ENDPOINT
NODE_ENV=development
EOF

echo ".env.local created - add to .gitignore if not already present"
```

### 5. Deploy Application Code

**Option A: Manual Deployment**

```bash
cd /home/user/open-whispr

# Build the application
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

**Option B: GitHub Actions CI/CD** (Recommended)

Create `.github/workflows/azure-deploy.yml`:

```yaml
name: Deploy to Azure

on:
  push:
    branches: [ main ]

jobs:
  build-and-deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3

      - name: Setup Node.js
        uses: actions/setup-node@v3
        with:
          node-version: '20'

      - name: Install and Build
        run: |
          npm install
          npm run build

      - name: Deploy to Azure Web App
        uses: azure/webapps-deploy@v2
        with:
          app-name: ${{ secrets.AZURE_WEBAPP_NAME }}
          publish-profile: ${{ secrets.AZURE_WEBAPP_PUBLISH_PROFILE }}
          package: ./dist
```

Get publish profile:
```bash
az webapp deployment list-publishing-profiles \
    --name $WEB_APP_NAME \
    --resource-group rg-openwhispr-dev \
    --xml > publish-profile.xml
```

Add as GitHub secret: `AZURE_WEBAPP_PUBLISH_PROFILE`

## Production Readiness

### 6. Restrict SQL Database Firewall Rules

**Why**: The current setup allows all IPs for development. Restrict in production.

```bash
SQL_SERVER_NAME=$(az deployment group show \
    --name openwhispr-deployment \
    --resource-group rg-openwhispr-dev \
    --query properties.outputs.sqlServerFqdn.value -o tsv | cut -d'.' -f1)

# Remove the allow-all rule
az sql server firewall-rule delete \
    --name AllowAllIps \
    --server $SQL_SERVER_NAME \
    --resource-group rg-openwhispr-dev

# Add specific IP or use Azure services only
# The Azure services rule is already configured
```

### 7. Enable Web App Autoscaling

**Why**: Scale automatically based on demand.

```bash
# Upgrade to Standard tier (required for autoscaling)
APP_SERVICE_PLAN=$(az appservice plan list \
    --resource-group rg-openwhispr-dev \
    --query "[0].name" -o tsv)

az appservice plan update \
    --name $APP_SERVICE_PLAN \
    --resource-group rg-openwhispr-dev \
    --sku S1

# Create autoscale rule
az monitor autoscale create \
    --resource-group rg-openwhispr-dev \
    --resource $APP_SERVICE_PLAN \
    --resource-type Microsoft.Web/serverfarms \
    --name autoscale-openwhispr \
    --min-count 1 \
    --max-count 3 \
    --count 1

# Add CPU-based scale-out rule
az monitor autoscale rule create \
    --resource-group rg-openwhispr-dev \
    --autoscale-name autoscale-openwhispr \
    --condition "Percentage CPU > 70 avg 5m" \
    --scale out 1

# Add CPU-based scale-in rule
az monitor autoscale rule create \
    --resource-group rg-openwhispr-dev \
    --autoscale-name autoscale-openwhispr \
    --condition "Percentage CPU < 30 avg 5m" \
    --scale in 1
```

### 8. Configure Custom Domain and SSL

**Why**: Professional domain name with SSL certificate.

```bash
# Add custom domain
az webapp config hostname add \
    --webapp-name $WEB_APP_NAME \
    --resource-group rg-openwhispr-dev \
    --hostname yourdomain.com

# Enable managed SSL certificate (free)
az webapp config ssl bind \
    --name $WEB_APP_NAME \
    --resource-group rg-openwhispr-dev \
    --certificate-thumbprint auto \
    --ssl-type SNI
```

**DNS Configuration Required**:
- Add CNAME record: `yourdomain.com` → `$WEB_APP_NAME.azurewebsites.net`
- Or A record pointing to Web App IP

### 9. Set Up Database Backups

**Why**: Protect against data loss.

```bash
# Azure SQL Basic tier includes 7-day automated backups
# Verify backup policy
az sql db show \
    --name sqldb-openwhispr-dev \
    --server $SQL_SERVER_NAME \
    --resource-group rg-openwhispr-dev \
    --query "{Name:name, BackupRetention:earliestRestoreDate}" -o table

# Optional: Create manual backup
az sql db export \
    --name sqldb-openwhispr-dev \
    --server $SQL_SERVER_NAME \
    --resource-group rg-openwhispr-dev \
    --admin-user openwhispr-admin \
    --admin-password "YourPassword" \
    --storage-key-type StorageAccessKey \
    --storage-key $(az storage account keys list \
        --resource-group rg-openwhispr-dev \
        --account-name $(az storage account list \
            --resource-group rg-openwhispr-dev \
            --query "[0].name" -o tsv) \
        --query "[0].value" -o tsv) \
    --storage-uri "https://$(az storage account list \
        --resource-group rg-openwhispr-dev \
        --query "[0].name" -o tsv).blob.core.windows.net/backups/backup-$(date +%Y%m%d).bacpac"
```

### 10. Configure Application Insights Alerts

**Why**: Get notified of issues before users report them.

```bash
APP_INSIGHTS_ID=$(az deployment group show \
    --name openwhispr-deployment \
    --resource-group rg-openwhispr-dev \
    --query properties.outputs.applicationInsightsInstrumentationKey.value -o tsv)

# Create action group for notifications
az monitor action-group create \
    --name openwhispr-alerts \
    --resource-group rg-openwhispr-dev \
    --short-name ow-alert \
    --email-receiver name=admin email=your-email@example.com

# Create alert for high error rate
az monitor metrics alert create \
    --name high-error-rate \
    --resource-group rg-openwhispr-dev \
    --scopes $(az webapp show \
        --name $WEB_APP_NAME \
        --resource-group rg-openwhispr-dev \
        --query id -o tsv) \
    --condition "avg requests/failed > 10" \
    --window-size 5m \
    --evaluation-frequency 1m \
    --action openwhispr-alerts

# Create alert for high response time
az monitor metrics alert create \
    --name high-response-time \
    --resource-group rg-openwhispr-dev \
    --scopes $(az webapp show \
        --name $WEB_APP_NAME \
        --resource-group rg-openwhispr-dev \
        --query id -o tsv) \
    --condition "avg requests/duration > 3000" \
    --window-size 5m \
    --evaluation-frequency 1m \
    --action openwhispr-alerts
```

## Multi-Environment Setup

### 11. Create Staging Environment

**Why**: Test changes before production deployment.

```bash
# Deploy to a new resource group with environment=staging
az group create --name rg-openwhispr-staging --location eastus

az deployment group create \
    --name openwhispr-staging-deployment \
    --resource-group rg-openwhispr-staging \
    --template-file infrastructure/bicep/main.bicep \
    --parameters environment=staging \
    --parameters sqlAdministratorPassword="YourStagingPassword123!" \
    --parameters objectId=$(az ad signed-in-user show --query id -o tsv)
```

### 12. Create Production Environment

**Why**: Separate production from development/staging.

```bash
# Deploy to production with higher-tier resources
az group create --name rg-openwhispr-prod --location eastus

az deployment group create \
    --name openwhispr-prod-deployment \
    --resource-group rg-openwhispr-prod \
    --template-file infrastructure/bicep/main.bicep \
    --parameters environment=prod \
    --parameters sqlAdministratorPassword="YourProdPassword123!" \
    --parameters objectId=$(az ad signed-in-user show --query id -o tsv)

# After deployment, upgrade tiers for production
APP_SERVICE_PLAN_PROD=$(az appservice plan list \
    --resource-group rg-openwhispr-prod \
    --query "[0].name" -o tsv)

az appservice plan update \
    --name $APP_SERVICE_PLAN_PROD \
    --resource-group rg-openwhispr-prod \
    --sku P1v2  # Premium tier for production

# Upgrade SQL to Standard tier
SQL_SERVER_PROD=$(az sql server list \
    --resource-group rg-openwhispr-prod \
    --query "[0].name" -o tsv)

az sql db update \
    --name sqldb-openwhispr-prod \
    --server $SQL_SERVER_PROD \
    --resource-group rg-openwhispr-prod \
    --service-objective S0  # Standard tier
```

## Advanced Features

### 13. Enable Application Insights Live Metrics

**Why**: Real-time monitoring of your application.

Access via Azure Portal:
1. Navigate to Application Insights resource
2. Click "Live Metrics" in the left menu
3. View real-time requests, dependencies, and performance

Or via CLI:
```bash
# Enable detailed telemetry
az webapp config appsettings set \
    --name $WEB_APP_NAME \
    --resource-group rg-openwhispr-dev \
    --settings \
        APPINSIGHTS_INSTRUMENTATIONKEY=$APP_INSIGHTS_ID \
        APPINSIGHTS_PROFILERFEATURE_VERSION=1.0.0 \
        APPINSIGHTS_SNAPSHOTFEATURE_VERSION=1.0.0
```

### 14. Set Up Azure CDN for Global Distribution

**Why**: Improve performance for global users.

```bash
# Create CDN profile
az cdn profile create \
    --name cdn-openwhispr \
    --resource-group rg-openwhispr-dev \
    --sku Standard_Microsoft

# Create CDN endpoint
az cdn endpoint create \
    --name openwhispr-cdn \
    --profile-name cdn-openwhispr \
    --resource-group rg-openwhispr-dev \
    --origin $WEB_APP_NAME.azurewebsites.net \
    --origin-host-header $WEB_APP_NAME.azurewebsites.net
```

### 15. Implement Rate Limiting

**Why**: Protect against abuse and control costs.

Add to your application code or use Azure API Management:

```bash
# Create API Management instance
az apim create \
    --name apim-openwhispr \
    --resource-group rg-openwhispr-dev \
    --publisher-name "Your Company" \
    --publisher-email your-email@example.com \
    --sku-name Consumption  # Pay per use
```

### 16. Set Up Cost Alerts

**Why**: Avoid unexpected Azure bills.

```bash
# Create budget alert
az consumption budget create \
    --budget-name openwhispr-monthly-budget \
    --amount 100 \
    --category Cost \
    --time-grain Monthly \
    --time-period start-date=$(date +%Y-%m-01) \
    --resource-group rg-openwhispr-dev

# Create alert at 80% of budget
# This requires additional configuration via Azure Portal
```

## Monitoring and Observability

### 17. View Logs and Metrics

```bash
# Stream application logs
az webapp log tail \
    --name $WEB_APP_NAME \
    --resource-group rg-openwhispr-dev

# View container logs
az container logs \
    --name ci-whisper-dev-* \
    --resource-group rg-openwhispr-dev

# Query Application Insights
az monitor app-insights query \
    --app appi-openwhispr-dev \
    --resource-group rg-openwhispr-dev \
    --analytics-query "requests | summarize count() by bin(timestamp, 1h)" \
    --offset 24h
```

### 18. Set Up Log Analytics Workspace

**Why**: Centralized logging and advanced querying.

```bash
# Create Log Analytics workspace
az monitor log-analytics workspace create \
    --workspace-name law-openwhispr \
    --resource-group rg-openwhispr-dev \
    --location eastus

# Link App Service to workspace
WORKSPACE_ID=$(az monitor log-analytics workspace show \
    --workspace-name law-openwhispr \
    --resource-group rg-openwhispr-dev \
    --query customerId -o tsv)

az webapp config appsettings set \
    --name $WEB_APP_NAME \
    --resource-group rg-openwhispr-dev \
    --settings LOG_ANALYTICS_WORKSPACE_ID=$WORKSPACE_ID
```

## Disaster Recovery

### 19. Document Recovery Procedures

Create a runbook for disaster recovery:

1. **Database Restore**:
   ```bash
   az sql db restore \
       --dest-database sqldb-openwhispr-dev-restored \
       --name sqldb-openwhispr-dev \
       --resource-group rg-openwhispr-dev \
       --server $SQL_SERVER_NAME \
       --time "2025-11-15T10:00:00Z"
   ```

2. **Redeploy Infrastructure**:
   ```bash
   cd infrastructure/bicep
   ./deploy.sh
   ```

3. **Restore from Backup**:
   - Storage Account: Enable geo-redundancy
   - Key Vault: Soft delete is enabled (7-day recovery window)

### 20. Create Infrastructure Snapshots

```bash
# Export current configuration
az group export \
    --name rg-openwhispr-dev \
    --output json > infrastructure-snapshot-$(date +%Y%m%d).json
```

## Next Reviews

**Weekly**:
- Review Application Insights for errors and performance
- Check cost management dashboard
- Review security recommendations

**Monthly**:
- Update dependencies and runtime versions
- Review and rotate API keys
- Check backup integrity
- Review and optimize resource sizing

**Quarterly**:
- Disaster recovery drill
- Security audit
- Performance optimization review
- Cost optimization analysis

## Additional Resources

- **Azure Documentation**: https://docs.microsoft.com/azure
- **Bicep Documentation**: https://docs.microsoft.com/azure/azure-resource-manager/bicep
- **Application Insights**: https://docs.microsoft.com/azure/azure-monitor/app/app-insights-overview
- **Azure Security**: https://docs.microsoft.com/azure/security
- **Cost Management**: https://docs.microsoft.com/azure/cost-management-billing

## Summary

You're now ready to:
- ✅ Develop locally with Azure backend
- ✅ Deploy code via CI/CD
- ✅ Scale automatically based on demand
- ✅ Monitor application health
- ✅ Secure your application
- ✅ Manage costs effectively
- ✅ Recover from disasters

Continue building and improving your OpenWhispr deployment!
