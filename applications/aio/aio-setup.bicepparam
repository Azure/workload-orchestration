using 'aio-setup.bicep'
param capability = '<capability>'
param targetConfigTemplate = '''
configs:
  clusterName: ${{$val(clusterName)}}
  customLocationName: ${{$val(customLocationName)}}
  aioExtensionName : ${{$val(aioExtensionName)}} 
  aioInstanceName : ${{$val(aioInstanceName)}}'''
param contextId = '<arm id of context>' // Context ID for the deployment (must already exist)
// Target represents a K8s cluster, this configuration for each target cluster
param targets  = [
  {
    name: 'aio-test1'
    resourceGroupName: 'aio-test'
    location: '<location>'
    configuration: '''
clusterName: "<arc enabled cluster name>"
customLocationName: "<aio custom location name>"
aioExtensionName: "<aio extension name>"
aioInstanceName: "<aio instance name>"'''
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
  schemaRegistryId: '<arm id of schema registry>'
  adrNamespaceId: '<arm id of adr namespace>'
}
}
