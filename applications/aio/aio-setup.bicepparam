using 'aio-setup.bicep'

param location = '<location>'
param targetConfigTemplate = '''
configs:
  clusterName: ${{$val(clusterName)}}
  customLocationName: ${{$val(customLocationName)}}
  aioExtensionName : ${{$val(aioExtensionName)}} 
  aioInstanceName : ${{$val(aioInstanceName)}}'''
param contextId = '<contextId>' // Context ID for the deployment (must already exist)
// Target represents a K8s cluster, this configuration for each target cluster
param targets  = [
  {
    name: '<target name>'
    capability: '<capability name>'
    configuration: '''
clusterName: "<arc enable cluster name>"
customLocationName: "<cluster name>"
aioExtensionName: "<aio extension name>"
aioInstanceName: "<aio instance name>"'''
  }
]

param opEnablementSolutionTemplate = {
  name: 'aio-op-enablement-st'
  version: '1.0.0'
  capability: '<caoability>'
  configuration: {
  clusterName: '\${{$config(cloud-target-config/1.0.0, clusterName)}}'
}
}

param opInstanceSolutionTemplate = {
  name: 'aio-op-instance-st'
  version: '1.0.0'
  capability: '<capability name>'
 configuration: {
  clExtensionIds: []
  customLocationName: '\${{$config(cloud-target-config/1.0.0, customLocationName)}}'
  aioInstanceName: '\${{$config(cloud-target-config/1.0.0, aioInstanceName)}}'
  clusterName: '\${{$config(cloud-target-config/1.0.0, clusterName)}}'
  schemaRegistryId: '/subscriptions/ef51d910-b329-4603-b2bf-5841fa1d6bdf/resourceGroups/aio-test/providers/Microsoft.DeviceRegistry/schemaRegistries/aio-sr'
  adrNamespaceId: '/subscriptions/ef51d910-b329-4603-b2bf-5841fa1d6bdf/resourceGroups/aio-test/providers/Microsoft.DeviceRegistry/namespaces/aio-srn'
}
}
