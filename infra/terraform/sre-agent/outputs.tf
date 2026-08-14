output "resource_group_name" {
  description = "Resource group containing the SRE Agent."
  value       = data.azurerm_resource_group.agent.name
}

output "sre_agent_name" {
  description = "SRE Agent resource name."
  value       = azapi_resource.agent.name
}

output "sre_agent_endpoint" {
  description = "SRE Agent data-plane endpoint."
  value       = try(jsondecode(azapi_resource.agent.output).properties.agentEndpoint, null)
}

output "sre_agent_provisioning_state" {
  description = "SRE Agent provisioning state."
  value       = try(jsondecode(azapi_resource.agent.output).properties.provisioningState, null)
}

output "log_analytics_workspace_id" {
  description = "Log Analytics workspace resource ID."
  value       = azurerm_log_analytics_workspace.agent.id
}

output "log_analytics_workspace_name" {
  description = "Log Analytics workspace name."
  value       = azurerm_log_analytics_workspace.agent.name
}

output "application_insights_id" {
  description = "Application Insights resource ID."
  value       = azurerm_application_insights.agent.id
}
