# OpenWhispr Azure Security Checklist

This document provides a comprehensive security review of all Azure resources deployed for OpenWhispr.

## Security Overview

### Current Security Status

| Resource | Security Feature | Status | Notes |
|----------|------------------|--------|-------|
| **App Service** | HTTPS Only | ✅ Enabled | Enforced in Bicep |
| | TLS Version | ✅ 1.2+ | Minimum TLS 1.2 configured |
| | Managed Identity | ✅ Available | System-assigned identity supported |
| | Authentication | ✅ Enabled | Entra ID SSO (when deployed with SSO) |
| | Network Isolation | ⚠️ Public | Recommended: Add VNet integration for production |
| **Storage Account** | HTTPS Only | ✅ Enabled | Enforced in Bicep |
| | Encryption at Rest | ✅ Enabled | Microsoft-managed keys |
| | Encryption in Transit | ✅ TLS 1.2 | Enforced |
| | Public Blob Access | ✅ Disabled | No anonymous access |
| | Network Firewall | ⚠️ Open | Allows all Azure services (dev setting) |
| | Soft Delete | ✅ Enabled | 7-day retention for blobs |
| **SQL Database** | TLS Encryption | ✅ 1.2+ | Enforced |
| | Firewall | ⚠️ Open | Allows Azure services + all IPs (DEV ONLY) |
| | Encryption at Rest | ✅ Enabled | Transparent Data Encryption (TDE) |
| | Auditing | ⚠️ Not configured | Recommended for production |
| | Threat Detection | ⚠️ Not configured | Recommended for production |
| | Admin Credentials | ✅ Secure | User-provided strong password required |
| **Key Vault** | RBAC | ✅ Available | Access policies configured |
| | Soft Delete | ✅ Enabled | 7-day recovery window |
| | Purge Protection | ⚠️ Disabled | Recommended for production |
| | Network Firewall | ⚠️ Open | Allows all networks (dev setting) |
| | Access Policies | ✅ Configured | Limited to specific principals |
| **Container Instance** | Image Source | ⚠️ Public | Uses public Docker Hub image |
| | Network | ✅ Public IP | Required for external access |
| | Environment Variables | ✅ No secrets | Model config only |
| | Volume Encryption | ✅ Encrypted | Azure File Share encrypted |
| **Application Insights** | Data Retention | ✅ 30 days | Configurable |
| | RBAC | ✅ Enabled | Azure RBAC controls access |
| | Network Access | ✅ Controlled | Public ingestion endpoint |

### Security Score

**Development Environment**: 7/10 ⚠️
- Secure defaults enabled
- Some settings intentionally open for development convenience
- **Action Required**: Tighten for production (see recommendations below)

**Production Environment** (with recommendations applied): 9.5/10 ✅

## Detailed Security Analysis

### 1. App Service Security

**Current Configuration**:
```bicep
properties: {
  httpsOnly: true                    // ✅ HTTPS enforced
  siteConfig: {
    minTlsVersion: '1.2'            // ✅ TLS 1.2 minimum
    ftpsState: 'Disabled'           // ✅ FTP disabled
    http20Enabled: true             // ✅ HTTP/2 enabled
  }
}
```

**Production Hardening**:

1. **Enable VNet Integration**:
   ```bash
   # Create VNet
   az network vnet create \
       --name vnet-openwhispr \
       --resource-group $RESOURCE_GROUP \
       --address-prefix 10.0.0.0/16 \
       --subnet-name subnet-app \
       --subnet-prefix 10.0.1.0/24

   # Integrate App Service
   az webapp vnet-integration add \
       --name $WEB_APP_NAME \
       --resource-group $RESOURCE_GROUP \
       --vnet vnet-openwhispr \
       --subnet subnet-app
   ```

2. **Add Private Endpoint** (Premium tier):
   ```bash
   az webapp update \
       --name $WEB_APP_NAME \
       --resource-group $RESOURCE_GROUP \
       --set publicNetworkAccess=Disabled

   # Create private endpoint
   az network private-endpoint create \
       --name pe-openwhispr \
       --resource-group $RESOURCE_GROUP \
       --vnet-name vnet-openwhispr \
       --subnet subnet-pe \
       --private-connection-resource-id $(az webapp show --name $WEB_APP_NAME --resource-group $RESOURCE_GROUP --query id -o tsv) \
       --group-id sites \
       --connection-name pe-connection
   ```

3. **Enable Web Application Firewall (WAF)**:
   - Requires Azure Front Door or Application Gateway
   - Protects against OWASP Top 10 vulnerabilities

### 2. Storage Account Security

**Current Configuration**:
```bicep
properties: {
  minimumTlsVersion: 'TLS1_2'           // ✅ TLS 1.2
  allowBlobPublicAccess: false          // ✅ No anonymous access
  supportsHttpsTrafficOnly: true        // ✅ HTTPS only
  networkAcls: {
    defaultAction: 'Allow'              // ⚠️ Open for dev
    bypass: 'AzureServices'
  }
}
```

**Production Hardening**:

1. **Restrict Network Access**:
   ```bash
   # Allow only specific IP ranges
   az storage account network-rule add \
       --account-name $STORAGE_ACCOUNT \
       --resource-group $RESOURCE_GROUP \
       --ip-address "YOUR_OFFICE_IP/32"

   # Or allow only VNet
   az storage account update \
       --name $STORAGE_ACCOUNT \
       --resource-group $RESOURCE_GROUP \
       --default-action Deny

   az storage account network-rule add \
       --account-name $STORAGE_ACCOUNT \
       --resource-group $RESOURCE_GROUP \
       --vnet-name vnet-openwhispr \
       --subnet subnet-app
   ```

2. **Enable Advanced Threat Protection**:
   ```bash
   az security atp storage update \
       --resource-group $RESOURCE_GROUP \
       --storage-account $STORAGE_ACCOUNT \
       --is-enabled true
   ```

3. **Use Customer-Managed Keys** (for enhanced encryption control):
   ```bash
   # Create Key Vault key
   az keyvault key create \
       --vault-name $KEY_VAULT_NAME \
       --name storage-encryption-key \
       --protection software

   # Enable CMK encryption
   az storage account update \
       --name $STORAGE_ACCOUNT \
       --resource-group $RESOURCE_GROUP \
       --encryption-key-source Microsoft.Keyvault \
       --encryption-key-vault $(az keyvault show --name $KEY_VAULT_NAME --query properties.vaultUri -o tsv) \
       --encryption-key-name storage-encryption-key
   ```

### 3. SQL Database Security

**Current Configuration**:
```bicep
properties: {
  minimalTlsVersion: '1.2'              // ✅ TLS 1.2
  publicNetworkAccess: 'Enabled'        // ⚠️ Public for dev
}

// Firewall rules
firewallRules: [
  {
    name: 'AllowAllAzureIps'            // ✅ Azure services
    startIpAddress: '0.0.0.0'
    endIpAddress: '0.0.0.0'
  },
  {
    name: 'AllowAllIps'                 // ⚠️ DEV ONLY - REMOVE FOR PROD
    startIpAddress: '0.0.0.0'
    endIpAddress: '255.255.255.255'
  }
]
```

**⚠️ CRITICAL: The "AllowAllIps" rule is for DEVELOPMENT ONLY**

**Production Hardening**:

1. **Remove Open Firewall Rule**:
   ```bash
   # Delete the allow-all rule
   az sql server firewall-rule delete \
       --name AllowAllIps \
       --server $SQL_SERVER \
       --resource-group $RESOURCE_GROUP

   # Add specific IP ranges
   az sql server firewall-rule create \
       --name AllowOffice \
       --server $SQL_SERVER \
       --resource-group $RESOURCE_GROUP \
       --start-ip-address "YOUR_IP" \
       --end-ip-address "YOUR_IP"
   ```

2. **Enable Private Endpoint**:
   ```bash
   az sql server update \
       --name $SQL_SERVER \
       --resource-group $RESOURCE_GROUP \
       --public-network-access Disabled

   az network private-endpoint create \
       --name pe-sql \
       --resource-group $RESOURCE_GROUP \
       --vnet-name vnet-openwhispr \
       --subnet subnet-data \
       --private-connection-resource-id $(az sql server show --name $SQL_SERVER --resource-group $RESOURCE_GROUP --query id -o tsv) \
       --group-id sqlServer \
       --connection-name pe-sql-connection
   ```

3. **Enable Auditing**:
   ```bash
   az sql server audit-policy update \
       --name $SQL_SERVER \
       --resource-group $RESOURCE_GROUP \
       --state Enabled \
       --storage-account $STORAGE_ACCOUNT \
       --retention-days 90
   ```

4. **Enable Threat Detection**:
   ```bash
   az sql db threat-policy update \
       --name $SQL_DATABASE \
       --server $SQL_SERVER \
       --resource-group $RESOURCE_GROUP \
       --state Enabled \
       --storage-account $STORAGE_ACCOUNT \
       --retention-days 90 \
       --email-account-admins Enabled
   ```

5. **Enable Transparent Data Encryption** (already enabled by default):
   ```bash
   # Verify TDE is enabled
   az sql db tde show \
       --database $SQL_DATABASE \
       --server $SQL_SERVER \
       --resource-group $RESOURCE_GROUP
   ```

### 4. Key Vault Security

**Current Configuration**:
```bicep
properties: {
  enableSoftDelete: true                // ✅ Soft delete
  softDeleteRetentionInDays: 7         // ✅ 7-day recovery
  enablePurgeProtection: false         // ⚠️ Not enabled
  publicNetworkAccess: 'Enabled'       // ⚠️ Open for dev
  networkAcls: {
    defaultAction: 'Allow'             // ⚠️ Open for dev
    bypass: 'AzureServices'
  }
}
```

**Production Hardening**:

1. **Enable Purge Protection**:
   ```bash
   az keyvault update \
       --name $KEY_VAULT_NAME \
       --resource-group $RESOURCE_GROUP \
       --enable-purge-protection true
   ```

2. **Restrict Network Access**:
   ```bash
   az keyvault update \
       --name $KEY_VAULT_NAME \
       --resource-group $RESOURCE_GROUP \
       --default-action Deny

   az keyvault network-rule add \
       --name $KEY_VAULT_NAME \
       --resource-group $RESOURCE_GROUP \
       --vnet-name vnet-openwhispr \
       --subnet subnet-app
   ```

3. **Enable Private Endpoint**:
   ```bash
   az network private-endpoint create \
       --name pe-kv \
       --resource-group $RESOURCE_GROUP \
       --vnet-name vnet-openwhispr \
       --subnet subnet-data \
       --private-connection-resource-id $(az keyvault show --name $KEY_VAULT_NAME --resource-group $RESOURCE_GROUP --query id -o tsv) \
       --group-id vault \
       --connection-name pe-kv-connection
   ```

4. **Enable Diagnostic Logging**:
   ```bash
   az monitor diagnostic-settings create \
       --name kv-diagnostics \
       --resource $(az keyvault show --name $KEY_VAULT_NAME --resource-group $RESOURCE_GROUP --query id -o tsv) \
       --logs '[{"category": "AuditEvent", "enabled": true}]' \
       --workspace $(az monitor log-analytics workspace show --workspace-name law-openwhispr --resource-group $RESOURCE_GROUP --query id -o tsv)
   ```

### 5. Container Instance Security

**Current Configuration**:
- ✅ Uses encrypted Azure File Share for persistent storage
- ⚠️ Uses public Docker image (not scanned)
- ✅ No secrets in environment variables
- ⚠️ Public IP address (required for external access)

**Production Hardening**:

1. **Use Private Container Registry**:
   ```bash
   # Create Azure Container Registry
   az acr create \
       --name acropenwhispr \
       --resource-group $RESOURCE_GROUP \
       --sku Standard

   # Import Whisper image
   az acr import \
       --name acropenwhispr \
       --source docker.io/onerahmet/openai-whisper-asr-webservice:latest \
       --image whisper:latest

   # Scan for vulnerabilities
   az acr task run \
       --registry acropenwhispr \
       --name quick-scan

   # Update container instance to use ACR
   # (requires updating the Bicep template)
   ```

2. **Add Network Security Group**:
   ```bash
   # Restrict access to container
   # (when using VNet integration)
   ```

## Data Protection

### Data at Rest

| Data Type | Location | Encryption | Status |
|-----------|----------|------------|--------|
| Audio files | Blob Storage | AES-256 | ✅ Encrypted |
| Transcriptions | Blob Storage | AES-256 | ✅ Encrypted |
| Database | SQL Database | TDE (AES-256) | ✅ Encrypted |
| API Keys | Key Vault | Hardware-backed | ✅ Encrypted |
| Whisper Models | File Share | AES-256 | ✅ Encrypted |

### Data in Transit

| Connection | Protocol | Status |
|------------|----------|--------|
| Client → App Service | HTTPS (TLS 1.2+) | ✅ Encrypted |
| App Service → SQL | TLS 1.2+ | ✅ Encrypted |
| App Service → Storage | HTTPS | ✅ Encrypted |
| App Service → Key Vault | HTTPS | ✅ Encrypted |
| App Service → Container | HTTP | ⚠️ Not encrypted (internal) |

### Data Retention

| Data Type | Retention | Compliance |
|-----------|-----------|------------|
| SQL Backups | 7 days (Basic tier) | Automatic |
| Blob Soft Delete | 7 days | Enabled |
| Key Vault Soft Delete | 7 days | Enabled |
| Application Insights | 30 days | Configurable |

## Compliance and Governance

### Azure Policy

Recommended policies for production:

```bash
# Require HTTPS for storage accounts
az policy assignment create \
    --name require-https-storage \
    --policy "/providers/Microsoft.Authorization/policyDefinitions/404c3081-a854-4457-ae30-26a93ef643f9" \
    --scope /subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP

# Require TLS 1.2 for App Service
az policy assignment create \
    --name require-tls-12 \
    --policy "/providers/Microsoft.Authorization/policyDefinitions/f0e6e85b-9b9f-4a4b-b67b-f730d42ac38e" \
    --scope /subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP

# Require encryption for SQL
az policy assignment create \
    --name require-sql-encryption \
    --policy "/providers/Microsoft.Authorization/policyDefinitions/17k78e20-9358-41c9-923c-fb736d382a12" \
    --scope /subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP
```

### Azure Security Center

Enable Microsoft Defender for Cloud:

```bash
# Enable for subscription
az security pricing create \
    --name VirtualMachines \
    --tier Standard

az security pricing create \
    --name SqlServers \
    --tier Standard

az security pricing create \
    --name AppServices \
    --tier Standard

az security pricing create \
    --name StorageAccounts \
    --tier Standard

az security pricing create \
    --name KeyVaults \
    --tier Standard
```

### Cost: ~$15-30/month for enhanced security

## Incident Response

### Security Monitoring

**Enable Alerts**:

```bash
# SQL injection attempts
az monitor metrics alert create \
    --name sql-injection-alert \
    --resource-group $RESOURCE_GROUP \
    --scopes $(az sql server show --name $SQL_SERVER --resource-group $RESOURCE_GROUP --query id -o tsv) \
    --condition "count SecurityEvent |where Threat == 'SQL.Injection' > 0" \
    --window-size 5m \
    --evaluation-frequency 1m

# Storage access anomalies
az monitor metrics alert create \
    --name storage-anomaly-alert \
    --resource-group $RESOURCE_GROUP \
    --scopes $(az storage account show --name $STORAGE_ACCOUNT --resource-group $RESOURCE_GROUP --query id -o tsv) \
    --condition "avg SuccessE2ELatency > 1000" \
    --window-size 5m
```

### Backup and Recovery

**Automated Backups**:
- SQL: 7-day point-in-time restore (Basic tier)
- Storage: 7-day soft delete for blobs
- Key Vault: 7-day soft delete recovery

**Manual Backup Process**:

```bash
# SQL Database
az sql db export \
    --name $SQL_DATABASE \
    --server $SQL_SERVER \
    --resource-group $RESOURCE_GROUP \
    --admin-user $ADMIN_USER \
    --admin-password $ADMIN_PASSWORD \
    --storage-key $(az storage account keys list --account-name $STORAGE_ACCOUNT --query "[0].value" -o tsv) \
    --storage-key-type StorageAccessKey \
    --storage-uri "https://${STORAGE_ACCOUNT}.blob.core.windows.net/backups/backup-$(date +%Y%m%d).bacpac"

# Storage (copy to secondary region)
az storage blob copy start-batch \
    --source-container transcriptions \
    --destination-container transcriptions-backup \
    --account-name $STORAGE_ACCOUNT
```

## Security Checklist for Production

Use this checklist before going to production:

### Network Security
- [ ] Remove SQL "AllowAllIps" firewall rule
- [ ] Configure storage account network rules
- [ ] Enable VNet integration for App Service
- [ ] Configure private endpoints for sensitive resources
- [ ] Set up Network Security Groups (NSGs)
- [ ] Enable DDoS protection

### Identity and Access
- [ ] Enable Entra ID SSO authentication
- [ ] Configure Conditional Access policies
- [ ] Require MFA for all users
- [ ] Use managed identities instead of connection strings
- [ ] Review and minimize Key Vault access policies
- [ ] Enable JIT (Just-In-Time) access for management

### Data Protection
- [ ] Enable SQL auditing
- [ ] Enable SQL threat detection
- [ ] Configure blob lifecycle management
- [ ] Implement data retention policies
- [ ] Enable geo-redundant backups
- [ ] Test backup restore procedures

### Monitoring and Compliance
- [ ] Enable Microsoft Defender for Cloud
- [ ] Configure security alerts
- [ ] Set up Log Analytics workspace
- [ ] Enable diagnostic logs for all resources
- [ ] Configure Azure Policy
- [ ] Enable compliance reporting
- [ ] Set up Azure Sentinel (if required)

### Application Security
- [ ] Implement Web Application Firewall (WAF)
- [ ] Enable App Service diagnostic logs
- [ ] Configure CORS policies
- [ ] Implement rate limiting
- [ ] Scan container images for vulnerabilities
- [ ] Enable Application Insights security features

### Secrets Management
- [ ] Rotate all secrets and keys
- [ ] Enable Key Vault purge protection
- [ ] Set up automated key rotation
- [ ] Audit Key Vault access logs
- [ ] Use separate Key Vaults per environment

## Security Best Practices

1. **Principle of Least Privilege**: Grant minimum necessary permissions
2. **Defense in Depth**: Multiple layers of security
3. **Zero Trust**: Never trust, always verify
4. **Regular Audits**: Review access logs monthly
5. **Patch Management**: Keep all services updated
6. **Incident Response Plan**: Document and test procedures
7. **Security Training**: Educate team on security practices
8. **Secure Development**: Follow OWASP guidelines

## Vulnerability Management

### Regular Security Tasks

**Weekly**:
- Review security alerts in Security Center
- Check failed login attempts
- Review unusual access patterns

**Monthly**:
- Rotate API keys
- Review user access rights
- Update dependencies
- Run vulnerability scans

**Quarterly**:
- Penetration testing
- Security audit
- Disaster recovery drill
- Review and update security policies

## Summary

### Current State (Development)
✅ **Good**: Strong defaults, encryption enabled, HTTPS enforced
⚠️ **Moderate Risk**: Some services publicly accessible for dev convenience

### Production Recommendations Priority

**High Priority** (Critical for production):
1. Remove SQL "AllowAllIps" firewall rule
2. Enable Entra ID SSO
3. Configure network restrictions on Storage
4. Enable SQL auditing and threat detection
5. Enable Key Vault purge protection

**Medium Priority** (Enhance security):
6. Add VNet integration
7. Enable private endpoints
8. Configure Conditional Access
9. Enable Microsoft Defender for Cloud
10. Set up security monitoring and alerts

**Low Priority** (Nice to have):
11. Customer-managed encryption keys
12. Geo-redundant storage
13. Azure Front Door with WAF
14. Container image scanning
15. Advanced compliance reporting

### Security Score Improvement Plan

| Phase | Timeline | Security Score | Cost Impact |
|-------|----------|----------------|-------------|
| Current (Dev) | - | 7/10 | Baseline |
| Phase 1 (High Priority) | Week 1-2 | 8.5/10 | +$0-5/month |
| Phase 2 (Medium Priority) | Week 3-4 | 9/10 | +$15-30/month |
| Phase 3 (Low Priority) | Week 5-8 | 9.5/10 | +$50-100/month |

All resources have secure defaults enabled. For production, follow the hardening steps in this document to achieve enterprise-grade security.
