# OpenWhispr Entra ID SSO Integration Guide

This guide explains how to deploy and manage OpenWhispr with Microsoft Entra ID (formerly Azure Active Directory) Single Sign-On authentication.

## Overview

The Entra ID SSO integration provides:

- 🔐 **Enterprise Authentication**: Users sign in with Microsoft organizational accounts
- 🔐 **Multi-Factor Authentication (MFA)**: Leverage your organization's MFA policies
- 🔐 **Role-Based Access Control (RBAC)**: Admin and User roles with different permissions
- 🔐 **Conditional Access**: Apply policies based on location, device, risk level, etc.
- 🔐 **Single Sign-On**: Users authenticate once across all your applications
- 🔐 **Audit Logging**: Track all sign-ins and access attempts
- 🔐 **Token Management**: Automatic token refresh and secure session handling

## Architecture

### Components

1. **Entra ID App Registration**
   - Application (client) ID
   - Client secret for authentication
   - Redirect URIs configured automatically
   - App roles: Administrator and User

2. **App Service Easy Auth**
   - Integrated authentication layer
   - No code changes required in your application
   - Automatic token validation and renewal
   - Session management

3. **Key Vault Integration**
   - Client ID and secret stored securely
   - Retrieved at runtime by App Service

4. **SQL Database Schema**
   - Enhanced with user_id and user_email columns
   - Tracks which user created each transcription

### Authentication Flow

```
User → Web App → Azure App Service
                      ↓
                 Not authenticated?
                      ↓
         Redirect to Entra ID Login
                      ↓
              User signs in with
          Microsoft account + MFA
                      ↓
            Entra ID validates
              credentials & MFA
                      ↓
          Returns token to App Service
                      ↓
              App Service validates
            token & creates session
                      ↓
         User redirected to application
                      ↓
        Token stored in cookie (.auth)
                      ↓
    Application receives user claims
         (name, email, roles, etc.)
```

## Prerequisites

### Required Permissions

To deploy with SSO, you need ONE of the following in your Azure AD tenant:

1. **Global Administrator** role
2. **Application Administrator** role
3. **Cloud Application Administrator** role
4. **Custom role** with these permissions:
   - `microsoft.directory/applications/create`
   - `microsoft.directory/applications/credentials/update`
   - `microsoft.directory/servicePrincipals/create`

### Required Azure Roles

- **Owner** or **Contributor** on the Azure subscription
- **User Access Administrator** (to grant managed identity permissions)

## Deployment

### Option 1: Automated Deployment (Recommended)

```bash
cd infrastructure/bicep

# Run the SSO deployment script
./deploy-with-sso.sh
```

The script will:
1. ✅ Verify your Azure login and permissions
2. ✅ Prompt for SQL password
3. ✅ Create resource group
4. ✅ Deploy all infrastructure with Entra ID
5. ✅ Create app registration automatically
6. ✅ Configure App Service authentication
7. ✅ Store credentials in Key Vault
8. ✅ Create database schema with user tracking
9. ✅ Generate deployment info file

**Deployment time**: 15-20 minutes

### Option 2: Manual Deployment

```bash
# Set up PATH
export PATH=$PATH:$HOME/.local/bin

# Login to Azure
az login

# Set variables
RESOURCE_GROUP="rg-openwhispr-dev"
LOCATION="eastus"
SQL_PASSWORD="YourSecurePassword123!"
OBJECT_ID=$(az ad signed-in-user show --query id -o tsv)

# Create resource group
az group create \
    --name $RESOURCE_GROUP \
    --location $LOCATION

# Deploy with SSO enabled
az deployment group create \
    --name openwhispr-sso-deployment \
    --resource-group $RESOURCE_GROUP \
    --template-file main-entra.bicep \
    --parameters environment=dev \
    --parameters sqlAdministratorPassword="$SQL_PASSWORD" \
    --parameters objectId="$OBJECT_ID" \
    --parameters enableEntraIdAuth=true
```

### Permission Issues

If deployment fails with permission errors:

1. **Check your roles**:
   ```bash
   az role assignment list --assignee $(az ad signed-in-user show --query id -o tsv) --all
   ```

2. **Grant app registration permissions** (requires Global Admin):
   ```bash
   ./grant-app-registration-permissions.sh
   ```

3. **Alternative**: Ask your Global Administrator to:
   - Run the deployment script, OR
   - Create the app registration manually (see Manual Setup section)

## Post-Deployment Configuration

### 1. Verify Deployment

```bash
# Get deployment outputs
DEPLOYMENT_NAME="openwhispr-sso-deployment"
RESOURCE_GROUP="rg-openwhispr-dev"

# Check web app URL
az deployment group show \
    --name $DEPLOYMENT_NAME \
    --resource-group $RESOURCE_GROUP \
    --query properties.outputs.webAppUrl.value -o tsv

# Check Entra ID app ID
az deployment group show \
    --name $DEPLOYMENT_NAME \
    --resource-group $RESOURCE_GROUP \
    --query properties.outputs.entraIdAppId.value -o tsv
```

### 2. Assign Users to Application

Users must be assigned to the application before they can sign in.

**Via Azure Portal**:

1. Go to **Azure Portal** → **Entra ID** → **Enterprise Applications**
2. Find **OpenWhispr-DEV** (or your environment name)
3. Click **Users and groups** → **Add user/group**
4. Select users and assign a role:
   - **Administrator**: Full access to all features
   - **User**: Basic transcription features only
5. Click **Assign**

**Via Azure CLI**:

```bash
# Get the app's service principal ID
SP_ID=$(az ad sp list --display-name "OpenWhispr-DEV" --query "[0].id" -o tsv)

# Get user's object ID
USER_ID=$(az ad user show --id user@yourdomain.com --query id -o tsv)

# Get app role IDs
ADMIN_ROLE_ID=$(az ad sp show --id $SP_ID --query "appRoles[?value=='Admin'].id" -o tsv)
USER_ROLE_ID=$(az ad sp show --id $SP_ID --query "appRoles[?value=='User'].id" -o tsv)

# Assign Admin role
az rest --method POST \
    --uri "https://graph.microsoft.com/v1.0/servicePrincipals/${SP_ID}/appRoleAssignedTo" \
    --body "{
        \"principalId\": \"${USER_ID}\",
        \"resourceId\": \"${SP_ID}\",
        \"appRoleId\": \"${ADMIN_ROLE_ID}\"
    }"

# Or assign User role
az rest --method POST \
    --uri "https://graph.microsoft.com/v1.0/servicePrincipals/${SP_ID}/appRoleAssignedTo" \
    --body "{
        \"principalId\": \"${USER_ID}\",
        \"resourceId\": \"${SP_ID}\",
        \"appRoleId\": \"${USER_ROLE_ID}\"
    }"
```

### 3. Assign Groups (Recommended for Enterprises)

Instead of assigning individual users, assign groups:

1. Go to **Entra ID** → **Groups**
2. Create groups: "OpenWhispr Admins" and "OpenWhispr Users"
3. Add members to groups
4. In **Enterprise Applications** → **OpenWhispr-DEV** → **Users and groups**
5. Click **Add user/group** → Select the group → Assign role

### 4. Test Authentication

```bash
# Get web app URL
WEB_APP_URL=$(az deployment group show \
    --name $DEPLOYMENT_NAME \
    --resource-group $RESOURCE_GROUP \
    --query properties.outputs.webAppUrl.value -o tsv)

echo "Open this URL: $WEB_APP_URL"
```

Expected behavior:
1. Navigating to the URL redirects to Microsoft login
2. User signs in with organizational account
3. MFA prompt if configured
4. Consent prompt (first time only)
5. Redirect back to application with authenticated session

### 5. Configure Additional Settings

**Token Expiration** (default: 8 hours):

```bash
WEB_APP_NAME=$(az deployment group show \
    --name $DEPLOYMENT_NAME \
    --resource-group $RESOURCE_GROUP \
    --query properties.outputs.webAppName.value -o tsv)

# Update token expiration to 24 hours
az webapp auth update \
    --name $WEB_APP_NAME \
    --resource-group $RESOURCE_GROUP \
    --token-refresh-extension-hours 72
```

**Require specific domains**:

Edit the `allowedAudiences` in `modules/app-service-auth.bicep` to restrict tokens to your domain.

## User Management

### App Roles

Two roles are configured:

| Role | Value | Description | Permissions |
|------|-------|-------------|-------------|
| Administrator | `Admin` | Full administrative access | - All transcription features<br>- View all users' transcriptions<br>- Manage settings<br>- Access analytics |
| User | `User` | Standard user access | - Create transcriptions<br>- View own transcriptions<br>- Basic settings |

### Accessing User Information in Your Application

The authenticated user's information is available via HTTP headers:

```javascript
// In your application code
const userId = req.headers['x-ms-client-principal-id'];
const userName = req.headers['x-ms-client-principal-name'];
const userEmail = req.headers['x-ms-client-principal-email'];
const userRoles = JSON.parse(req.headers['x-ms-client-principal']).claims
    .filter(c => c.typ === 'roles')
    .map(c => c.val);

// Check if user is admin
const isAdmin = userRoles.includes('Admin');
```

### User Claims Available

- `name`: User's display name
- `email`: User's email address
- `oid`: User's object ID (unique identifier)
- `tid`: Tenant ID
- `roles`: Array of assigned app roles
- `preferred_username`: User's UPN

## Security Configuration

### 1. Conditional Access Policies

Apply additional security policies:

1. **Require MFA**: Go to **Entra ID** → **Security** → **Conditional Access**
2. Create new policy:
   - Users: Select groups or all users
   - Cloud apps: Select "OpenWhispr-DEV"
   - Grant: Require multi-factor authentication
3. Enable policy

### 2. Require Managed Devices

```
Conditional Access Policy:
- Cloud apps: OpenWhispr-DEV
- Grant: Require device to be marked as compliant OR
        Require Hybrid Azure AD joined device
```

### 3. Location-Based Access

```
Conditional Access Policy:
- Cloud apps: OpenWhispr-DEV
- Conditions: Locations → Include/Exclude specific locations
- Grant: Block access OR Require MFA
```

### 4. Sign-in Frequency

Force users to re-authenticate periodically:

```
Conditional Access Policy:
- Cloud apps: OpenWhispr-DEV
- Session: Sign-in frequency → Every 1 day
```

## Monitoring and Auditing

### Sign-in Logs

View all authentication attempts:

```bash
# Via Azure Portal
Portal → Entra ID → Monitoring → Sign-in logs → Filter by application

# Via Azure CLI
az monitor activity-log list \
    --resource-group $RESOURCE_GROUP \
    --start-time 2025-11-15T00:00:00Z \
    --query "[?contains(resourceId, 'OpenWhispr')]"
```

### Audit Logs

Track administrative actions:

```
Portal → Entra ID → Monitoring → Audit logs
Filter by: Service = "Enterprise Applications"
```

### Application Insights

Authentication metrics are automatically logged:

```bash
# Query failed authentications
az monitor app-insights query \
    --app appi-openwhispr-dev \
    --resource-group $RESOURCE_GROUP \
    --analytics-query "
        requests
        | where url contains '.auth'
        | where resultCode >= 400
        | summarize count() by bin(timestamp, 1h), resultCode
    "
```

## Troubleshooting

### Users Can't Sign In

**Issue**: "AADSTS50105: The signed in user is not assigned to a role"

**Solution**: Assign users to the application (see User Management section)

---

**Issue**: "AADSTS700016: Application not found in the directory"

**Solution**: Verify app registration exists and tenant ID is correct

```bash
az ad app list --display-name "OpenWhispr-DEV"
```

---

**Issue**: "AADSTS65001: The user or administrator has not consented"

**Solution**: Grant admin consent

```bash
APP_ID=$(az ad app list --display-name "OpenWhispr-DEV" --query "[0].appId" -o tsv)
az ad app permission admin-consent --id $APP_ID
```

### Authentication Loop

**Issue**: Redirects to login repeatedly

**Solution**:
1. Check redirect URI matches exactly: `https://your-app.azurewebsites.net/.auth/login/aad/callback`
2. Verify client secret hasn't expired
3. Check App Service auth logs:
   ```bash
   az webapp log tail --name $WEB_APP_NAME --resource-group $RESOURCE_GROUP
   ```

### Token Expired

**Issue**: "Token expired" error

**Solution**: Configure token refresh

```bash
az webapp auth update \
    --name $WEB_APP_NAME \
    --resource-group $RESOURCE_GROUP \
    --token-refresh-extension-hours 72
```

### Claims Missing

**Issue**: User roles or claims not available

**Solution**:
1. Verify token configuration includes roles claim
2. Check app registration optional claims:
   ```bash
   APP_ID=$(az ad app list --display-name "OpenWhispr-DEV" --query "[0].appId" -o tsv)
   az ad app show --id $APP_ID --query "optionalClaims"
   ```

## Advanced Configuration

### Custom Claims

Add custom user attributes:

1. **Entra ID** → **App registrations** → **OpenWhispr-DEV**
2. **Token configuration** → **Add optional claim**
3. Select claim type (ID, Access, SAML)
4. Add claims: email, family_name, given_name, upn, etc.

### Multiple Environments

Deploy separate app registrations for dev/staging/prod:

```bash
# Development
./deploy-with-sso.sh  # Uses environment=dev

# Staging
ENVIRONMENT=staging ./deploy-with-sso.sh

# Production
ENVIRONMENT=prod ./deploy-with-sso.sh
```

Each environment gets its own app registration: OpenWhispr-DEV, OpenWhispr-STAGING, OpenWhispr-PROD

### External Users (B2B)

Invite external users:

1. **Entra ID** → **Users** → **New guest user**
2. Enter email address of external user
3. Send invitation
4. Assign to OpenWhispr application
5. External user receives email with link to accept

### API Access

Generate tokens for API access:

```bash
# Get access token
ACCESS_TOKEN=$(az account get-access-token \
    --resource api://$APP_ID \
    --query accessToken -o tsv)

# Use in API requests
curl -H "Authorization: Bearer $ACCESS_TOKEN" \
    https://your-app.azurewebsites.net/api/transcriptions
```

## Migration from Non-SSO

If you deployed without SSO and want to add it:

1. **Backup data**:
   ```bash
   az sql db export --name $DB_NAME --server $SERVER_NAME --storage-uri ...
   ```

2. **Deploy SSO version**:
   ```bash
   ./deploy-with-sso.sh
   ```

3. **Migrate data** (if using different resource group):
   ```bash
   # Export from old database, import to new
   ```

4. **Update DNS** (if using custom domain)

5. **Test thoroughly**

6. **Decommission old deployment**

## Cost Impact

SSO adds minimal cost:

| Component | Cost |
|-----------|------|
| Entra ID App Registration | Free |
| App Service Authentication | No additional cost |
| Deployment Script (one-time) | ~$0.01 |
| **Total Additional Monthly Cost** | **~$0** |

## Support

### Documentation
- [Microsoft Entra ID Documentation](https://docs.microsoft.com/en-us/entra/identity/)
- [App Service Authentication](https://docs.microsoft.com/en-us/azure/app-service/overview-authentication-authorization)
- [Conditional Access](https://docs.microsoft.com/en-us/entra/identity/conditional-access/)

### Common Commands

```bash
# View app registration
az ad app show --id $APP_ID

# List assigned users
az ad sp show --id $SP_ID --query "appRoleAssignments"

# Check authentication configuration
az webapp auth show --name $WEB_APP_NAME --resource-group $RESOURCE_GROUP

# View sign-in logs
Portal → Entra ID → Sign-in logs

# Test endpoint
curl -I https://your-app.azurewebsites.net
# Should return 302 redirect to login
```

## Summary

You now have enterprise-grade authentication with:

- ✅ SSO with Microsoft accounts
- ✅ Multi-factor authentication support
- ✅ Role-based access control (Admin/User)
- ✅ Conditional Access policies
- ✅ Comprehensive audit logging
- ✅ Automatic token management
- ✅ Secure credential storage in Key Vault
- ✅ User tracking in database

All configured and ready to use!
