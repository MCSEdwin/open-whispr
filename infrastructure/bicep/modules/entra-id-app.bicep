// Entra ID App Registration using Deployment Script
// This module creates an Entra ID app registration with app roles and permissions

param location string
param appName string
param webAppUrl string
param tenantId string
param tags object = {}

// User Assigned Managed Identity for the deployment script
resource managedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-${appName}-deployer'
  location: location
  tags: tags
}

// Deployment script to create Entra ID app registration
resource appRegistrationScript 'Microsoft.Resources/deploymentScripts@2023-08-01' = {
  name: 'script-create-app-registration'
  location: location
  tags: tags
  kind: 'AzureCLI'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${managedIdentity.id}': {}
    }
  }
  properties: {
    azCliVersion: '2.50.0'
    timeout: 'PT30M'
    retentionInterval: 'P1D'
    cleanupPreference: 'OnSuccess'
    environmentVariables: [
      {
        name: 'APP_NAME'
        value: appName
      }
      {
        name: 'WEB_APP_URL'
        value: webAppUrl
      }
      {
        name: 'TENANT_ID'
        value: tenantId
      }
    ]
    scriptContent: '''
      #!/bin/bash
      set -e

      echo "Creating Entra ID App Registration for $APP_NAME..."

      # Check if app already exists
      EXISTING_APP=$(az ad app list --display-name "$APP_NAME" --query "[0].appId" -o tsv)

      if [ -z "$EXISTING_APP" ]; then
        echo "Creating new app registration..."

        # Create app registration with app roles
        APP_ID=$(az ad app create \
          --display-name "$APP_NAME" \
          --sign-in-audience AzureADMyOrg \
          --web-redirect-uris "${WEB_APP_URL}/.auth/login/aad/callback" \
          --enable-id-token-issuance true \
          --enable-access-token-issuance true \
          --query appId -o tsv)

        echo "App Registration created with App ID: $APP_ID"
      else
        echo "App registration already exists with App ID: $EXISTING_APP"
        APP_ID=$EXISTING_APP

        # Update redirect URIs
        az ad app update \
          --id "$APP_ID" \
          --web-redirect-uris "${WEB_APP_URL}/.auth/login/aad/callback"
      fi

      # Get Object ID
      OBJECT_ID=$(az ad app show --id "$APP_ID" --query id -o tsv)

      # Create app roles manifest
      cat > app-roles.json <<EOF
[
  {
    "allowedMemberTypes": ["User"],
    "description": "Administrators have full access to all features",
    "displayName": "Administrator",
    "id": "$(uuidgen)",
    "isEnabled": true,
    "value": "Admin"
  },
  {
    "allowedMemberTypes": ["User"],
    "description": "Users can access basic transcription features",
    "displayName": "User",
    "id": "$(uuidgen)",
    "isEnabled": true,
    "value": "User"
  }
]
EOF

      # Update app roles
      az ad app update --id "$APP_ID" --app-roles @app-roles.json

      # Create service principal if it doesn't exist
      SP_ID=$(az ad sp list --filter "appId eq '$APP_ID'" --query "[0].id" -o tsv)

      if [ -z "$SP_ID" ]; then
        echo "Creating service principal..."
        SP_ID=$(az ad sp create --id "$APP_ID" --query id -o tsv)
        echo "Service Principal created: $SP_ID"
      else
        echo "Service Principal already exists: $SP_ID"
      fi

      # Create client secret
      SECRET_NAME="OpenWhispr-Secret-$(date +%s)"
      CLIENT_SECRET=$(az ad app credential reset \
        --id "$APP_ID" \
        --display-name "$SECRET_NAME" \
        --years 2 \
        --query password -o tsv)

      # Output results
      echo "=== App Registration Complete ==="
      echo "Application (client) ID: $APP_ID"
      echo "Object ID: $OBJECT_ID"
      echo "Directory (tenant) ID: $TENANT_ID"
      echo "Service Principal ID: $SP_ID"

      # Store outputs in JSON format for Bicep
      OUTPUT_JSON=$(cat <<EOFF
{
  "appId": "$APP_ID",
  "objectId": "$OBJECT_ID",
  "servicePrincipalId": "$SP_ID",
  "tenantId": "$TENANT_ID",
  "clientSecret": "$CLIENT_SECRET"
}
EOFF
)

      echo "$OUTPUT_JSON" > $AZ_SCRIPTS_OUTPUT_PATH
    '''
  }
}

// Outputs from the deployment script
output appId string = appRegistrationScript.properties.outputs.appId
output objectId string = appRegistrationScript.properties.outputs.objectId
output servicePrincipalId string = appRegistrationScript.properties.outputs.servicePrincipalId
output tenantId string = appRegistrationScript.properties.outputs.tenantId
output clientSecret string = appRegistrationScript.properties.outputs.clientSecret
output managedIdentityId string = managedIdentity.id
output managedIdentityPrincipalId string = managedIdentity.properties.principalId
