// Azure Container Instance for Whisper processing
param location string
param containerGroupName string
param tags object = {}
param storageAccountName string
param storageAccountKey string

resource containerGroup 'Microsoft.ContainerInstance/containerGroups@2023-05-01' = {
  name: containerGroupName
  location: location
  tags: tags
  properties: {
    containers: [
      {
        name: 'whisper-processor'
        properties: {
          image: 'onerahmet/openai-whisper-asr-webservice:latest'
          resources: {
            requests: {
              cpu: 2
              memoryInGB: 4
            }
          }
          ports: [
            {
              port: 9000
              protocol: 'TCP'
            }
          ]
          environmentVariables: [
            {
              name: 'ASR_MODEL'
              value: 'base'
            }
            {
              name: 'ASR_ENGINE'
              value: 'openai_whisper'
            }
          ]
          volumeMounts: [
            {
              name: 'whisper-models'
              mountPath: '/root/.cache/whisper'
            }
          ]
        }
      }
    ]
    osType: 'Linux'
    restartPolicy: 'Always'
    ipAddress: {
      type: 'Public'
      ports: [
        {
          port: 9000
          protocol: 'TCP'
        }
      ]
      dnsNameLabel: containerGroupName
    }
    volumes: [
      {
        name: 'whisper-models'
        azureFile: {
          shareName: 'whisper-models'
          storageAccountName: storageAccountName
          storageAccountKey: storageAccountKey
        }
      }
    ]
  }
}

output containerGroupId string = containerGroup.id
output containerGroupName string = containerGroup.name
output containerGroupIpAddress string = containerGroup.properties.ipAddress.ip
output containerGroupFqdn string = containerGroup.properties.ipAddress.fqdn
output whisperEndpoint string = 'http://${containerGroup.properties.ipAddress.fqdn}:9000'
