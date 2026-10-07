output "registry_connection_id" {
  description = "Full resource ID of the registry connection."
  value       = azapi_resource.registry_connection.id
}

output "registry_connection_name" {
  description = "Value to use for registryConnectionId in azure.yaml."
  value       = azapi_resource.registry_connection.name
}

output "project_id" {
  description = "Foundry project resource ID."
  value       = data.azapi_resource.project.id
}

output "project_principal_id" {
  description = "Project managed identity object ID. Bind this in the registry's OIDC identity mapping."
  value       = data.azapi_resource.project.output.identity.principalId
}
