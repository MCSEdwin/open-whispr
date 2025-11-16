// App Service Authentication Configuration with Entra ID
param webAppName string
param clientId string
@secure()
param clientSecret string
param tenantId string
param allowedAudiences array = []

// Reference to existing Web App
resource webApp 'Microsoft.Web/sites@2023-01-01' existing = {
  name: webAppName
}

// Configure App Service Authentication (Easy Auth)
resource authSettings 'Microsoft.Web/sites/config@2023-01-01' = {
  parent: webApp
  name: 'authsettingsV2'
  properties: {
    globalValidation: {
      requireAuthentication: true
      unauthenticatedClientAction: 'RedirectToLoginPage'
      redirectToProvider: 'azureActiveDirectory'
    }
    httpSettings: {
      requireHttps: true
      routes: {
        apiPrefix: '/.auth'
      }
    }
    login: {
      tokenStore: {
        enabled: true
        tokenRefreshExtensionHours: 72
      }
      preserveUrlFragmentsForLogins: false
      allowedExternalRedirectUrls: []
      cookieExpiration: {
        convention: 'FixedTime'
        timeToExpiration: '08:00:00'
      }
      nonce: {
        validateNonce: true
        nonceExpirationInterval: '00:05:00'
      }
    }
    identityProviders: {
      azureActiveDirectory: {
        enabled: true
        registration: {
          openIdIssuer: 'https://sts.windows.net/${tenantId}/v2.0'
          clientId: clientId
          clientSecretSettingName: 'MICROSOFT_PROVIDER_AUTHENTICATION_SECRET'
        }
        login: {
          loginParameters: []
          disableWWWAuthenticate: false
        }
        validation: {
          jwtClaimChecks: {}
          allowedAudiences: empty(allowedAudiences) ? [
            'api://${clientId}'
            'https://${webApp.properties.defaultHostName}'
          ] : allowedAudiences
          defaultAuthorizationPolicy: {
            allowedPrincipals: {}
          }
        }
        isAutoProvisioned: false
      }
    }
  }
}

// Store client secret in app settings
resource appSettings 'Microsoft.Web/sites/config@2023-01-01' = {
  parent: webApp
  name: 'appsettings'
  properties: {
    MICROSOFT_PROVIDER_AUTHENTICATION_SECRET: clientSecret
    WEBSITE_AUTH_ENABLED: 'True'
    WEBSITE_AUTH_AAD_ALLOWED_TENANTS: tenantId
  }
  dependsOn: [
    authSettings
  ]
}

output authConfigured bool = true
