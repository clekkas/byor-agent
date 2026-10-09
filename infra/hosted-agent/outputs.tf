output "agent_version" {
  description = "Latest version returned by the serialized agent deployment."
  value       = tostring(azapi_data_plane_resource.hosted_agent.output.versions.latest.version)
}

output "agent_endpoint" {
  description = "Responses-protocol endpoint for the logical hosted agent."
  value       = "${local.project_endpoint}/agents/${var.agent_name}/endpoint/protocols/openai/responses?api-version=v1"
}

output "image_uri" {
  description = "Image configured on the Terraform-managed agent version."
  value       = var.image_uri
}
