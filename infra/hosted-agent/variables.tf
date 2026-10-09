variable "project_endpoint" {
  type        = string
  description = "Foundry project data-plane endpoint."

  validation {
    condition     = can(regex("^https://[^/?#]+/api/projects/[^/?#]+/?$", var.project_endpoint))
    error_message = "Use an HTTPS Foundry project endpoint without a query or fragment."
  }
}

variable "agent_name" {
  type        = string
  description = "Logical hosted agent to manage."
  default     = "private-registry-agent"
}

variable "image_uri" {
  type        = string
  description = "Prebuilt linux/amd64 image in the private registry."

  validation {
    condition     = can(regex("^[^/]+/.+(@sha256:[0-9a-f]{64}|:[A-Za-z0-9_.-]+)$", var.image_uri))
    error_message = "Use a registry image URI with a tag or sha256 digest."
  }
}

variable "registry_connection_name" {
  type        = string
  description = "Foundry project registry connection name or resource ID."
  default     = "jfrog-registry"
}

variable "model_deployment_name" {
  type        = string
  description = "Existing Foundry model deployment used by the container."
  default     = "gpt-5-mini"
}

variable "cpu" {
  type        = string
  description = "Hosted-agent CPU allocation."
  default     = "0.5"
}

variable "memory" {
  type        = string
  description = "Hosted-agent memory allocation."
  default     = "1Gi"
}

variable "import_existing_agent" {
  type        = bool
  description = "Adopt the existing logical agent into Terraform state on the first apply."
  default     = true
}
