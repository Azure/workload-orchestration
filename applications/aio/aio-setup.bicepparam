using 'aio-setup.bicep'
param capability = 'chevron1'
param targetConfigTemplate = '''
configs:
  clusterName: ${{$val(clusterName)}}
  customLocationName: ${{$val(customLocationName)}}
  aioExtensionName : ${{$val(aioExtensionName)}} 
  aioInstanceName : ${{$val(aioInstanceName)}}'''
param contextId = '/subscriptions/ef51d910-b329-4603-b2bf-5841fa1d6bdf/resourceGroups/gademo1/providers/Microsoft.Edge/contexts/gademo1-Context' // Context ID for the deployment (must already exist)
// Target represents a K8s cluster, this configuration for each target cluster
param targets  = [
  {
    name: 'aio-test1'
    resourceGroupName: 'aio-test'
    location: 'eastus'
    configuration: '''
clusterName: "aio-test-Cluster"
customLocationName: "aio-test-cl"
aioExtensionName: "aio-test-extn"
aioInstanceName: "aio-test-instance"'''
  }
]

param opEnablementSolutionTemplate = {
  name: 'aio-op-enablement-st'
  version: '1.0.0'
  configuration: {
  clusterName: '\${{$config(cloud-target-config/1.0.0, clusterName)}}'
}
}

param opInstanceSolutionTemplate = {
  name: 'aio-op-instance-st'
  version: '1.0.0'
 configuration: {
  clExtensionIds: []
  customLocationName: '\${{$config(cloud-target-config/1.0.0, customLocationName)}}'
  aioInstanceName: '\${{$config(cloud-target-config/1.0.0, aioInstanceName)}}'
  clusterName: '\${{$config(cloud-target-config/1.0.0, clusterName)}}'
  schemaRegistryId: '/subscriptions/ef51d910-b329-4603-b2bf-5841fa1d6bdf/resourceGroups/aio-test/providers/Microsoft.DeviceRegistry/schemaRegistries/aio-test-sr'
  adrNamespaceId: '/subscriptions/ef51d910-b329-4603-b2bf-5841fa1d6bdf/resourceGroups/aio-test/providers/Microsoft.DeviceRegistry/namespaces/aio-test-sr-namespace'
}
}
