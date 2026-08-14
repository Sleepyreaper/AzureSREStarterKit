data "azurerm_resource_group" "agent" {
  name = var.resource_group_name
}

resource "azurerm_log_analytics_workspace" "agent" {
  name                = "law-${var.name_prefix}"
  location            = var.location
  resource_group_name = data.azurerm_resource_group.agent.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
  daily_quota_gb      = var.log_daily_quota_gb
  tags                = var.tags
}

resource "azurerm_application_insights" "agent" {
  name                = "appi-${var.name_prefix}"
  location            = var.location
  resource_group_name = data.azurerm_resource_group.agent.name
  workspace_id        = azurerm_log_analytics_workspace.agent.id
  application_type    = "web"
  tags                = var.tags
}

resource "azurerm_monitor_action_group" "agent" {
  name                = "ag-${var.name_prefix}-sre-agent"
  resource_group_name = data.azurerm_resource_group.agent.name
  short_name          = "sreagent"
  enabled             = true
  tags                = var.tags
}

resource "azurerm_user_assigned_identity" "agent" {
  name                = "id-${var.agent_name}"
  location            = var.location
  resource_group_name = data.azurerm_resource_group.agent.name
  tags                = var.tags
}

resource "azurerm_role_assignment" "managed_resource_reader" {
  scope                = data.azurerm_resource_group.agent.id
  role_definition_name = "Reader"
  principal_id         = azurerm_user_assigned_identity.agent.principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "managed_resource_monitoring_reader" {
  scope                = data.azurerm_resource_group.agent.id
  role_definition_name = "Monitoring Reader"
  principal_id         = azurerm_user_assigned_identity.agent.principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "log_analytics_reader" {
  scope                = azurerm_log_analytics_workspace.agent.id
  role_definition_name = "Log Analytics Reader"
  principal_id         = azurerm_user_assigned_identity.agent.principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "monitoring_contributor" {
  scope                = data.azurerm_resource_group.agent.id
  role_definition_name = "Monitoring Contributor"
  principal_id         = azurerm_user_assigned_identity.agent.principal_id
  principal_type       = "ServicePrincipal"
}

resource "azapi_resource" "agent" {
  type                      = "Microsoft.App/agents@2025-05-01-preview"
  name                      = var.agent_name
  parent_id                 = data.azurerm_resource_group.agent.id
  location                  = var.location
  schema_validation_enabled = false
  response_export_values    = ["properties.agentEndpoint", "properties.provisioningState", "properties.powerState"]

  identity {
    type         = "SystemAssigned, UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.agent.id]
  }

  body = jsonencode({
    tags = merge(var.tags, {
      "hidden-link: /app-insights-resource-id" = azurerm_application_insights.agent.id
    })
    properties = {
      actionConfiguration = {
        mode        = "Review"
        identity    = azurerm_user_assigned_identity.agent.id
        accessLevel = "Low"
      }
      defaultModel = {
        provider = "MicrosoftFoundry"
        name     = "Automatic"
      }
      knowledgeGraphConfiguration = {
        identity         = azurerm_user_assigned_identity.agent.id
        managedResources = [data.azurerm_resource_group.agent.id]
      }
      logConfiguration = {
        applicationInsightsConfiguration = {
          appId            = azurerm_application_insights.agent.app_id
          connectionString = azurerm_application_insights.agent.connection_string
        }
      }
      incidentManagementConfiguration = {
        type           = "AzMonitor"
        connectionName = "azmonitor"
      }
      upgradeChannel        = "Stable"
      monthlyAgentUnitLimit = var.monthly_agent_unit_limit
    }
  })

  depends_on = [
    azurerm_role_assignment.log_analytics_reader,
    azurerm_role_assignment.managed_resource_monitoring_reader,
    azurerm_role_assignment.managed_resource_reader,
    azurerm_role_assignment.monitoring_contributor,
  ]
}

resource "azurerm_role_assignment" "agent_administrator" {
  for_each = toset(var.administrator_principal_ids)

  scope                = azapi_resource.agent.id
  role_definition_name = "SRE Agent Administrator"
  principal_id         = each.value
}

resource "azurerm_role_assignment" "deployment_agent_administrator" {
  count = var.deployment_principal_object_id == null ? 0 : 1

  scope                            = azapi_resource.agent.id
  role_definition_name             = "SRE Agent Administrator"
  principal_id                     = var.deployment_principal_object_id
  principal_type                   = "ServicePrincipal"
  skip_service_principal_aad_check = true
}
