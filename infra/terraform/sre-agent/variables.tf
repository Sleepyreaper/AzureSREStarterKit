variable "resource_group_name" {
  description = "Existing resource group containing the SRE Agent and monitoring resources."
  type        = string
  default     = "rg-sre-agent-demo"
}

variable "location" {
  description = "Azure region that supports Microsoft.App/agents."
  type        = string
  default     = "swedencentral"

  validation {
    condition = contains([
      "australiaeast",
      "canadacentral",
      "eastus2",
      "francecentral",
      "italynorth",
      "koreacentral",
      "polandcentral",
      "southafricanorth",
      "southeastasia",
      "swedencentral",
      "uksouth",
    ], var.location)
    error_message = "location must support Microsoft.App/agents."
  }
}

variable "name_prefix" {
  description = "Prefix for monitoring resource names."
  type        = string
  default     = "sre-agent-demo"
}

variable "agent_name" {
  description = "SRE Agent resource name."
  type        = string
  default     = "subscription-sre-agent"

  validation {
    condition     = can(regex("^[A-Za-z]([-A-Za-z0-9]{0,30}[A-Za-z0-9])$", var.agent_name))
    error_message = "agent_name must start with a letter and contain 2-32 letters, numbers, or hyphens."
  }
}

variable "monthly_agent_unit_limit" {
  description = "Monthly SRE Agent unit limit used as a cost guardrail."
  type        = number
  default     = 10000

  validation {
    condition     = var.monthly_agent_unit_limit > 0
    error_message = "monthly_agent_unit_limit must be greater than zero."
  }
}

variable "log_daily_quota_gb" {
  description = "Log Analytics daily ingestion cap in GB."
  type        = number
  default     = 1

  validation {
    condition     = var.log_daily_quota_gb > 0
    error_message = "log_daily_quota_gb must be greater than zero."
  }
}

variable "administrator_principal_ids" {
  description = "Human Entra object IDs granted SRE Agent Administrator."
  type        = list(string)
  default     = []
  nullable    = false
}

variable "deployment_principal_object_id" {
  description = "GitHub Actions deployment identity object ID granted SRE Agent Administrator."
  type        = string
  default     = null
  nullable    = true
}

variable "tags" {
  description = "Tags applied to deployed resources."
  type        = map(string)
  default = {
    environment = "demo"
    managed-by  = "terraform"
    workload    = "sre-agent"
  }
}
