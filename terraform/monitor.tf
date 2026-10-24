resource "azurerm_log_analytics_workspace" "main" {
  name                = "log-${var.prefix}-${random_string.suffix.result}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
}

resource "azurerm_monitor_action_group" "email" {
  name                = "ag-${var.prefix}"
  resource_group_name = azurerm_resource_group.main.name
  short_name          = "p09alert"

  email_receiver {
    name                    = "equipo"
    email_address           = var.alert_email
    use_common_alert_schema = true
  }
}

# Data Factory: ejecuciones de pipelines, actividades y triggers
resource "azurerm_monitor_diagnostic_setting" "adf" {
  name                       = "diag-adf"
  target_resource_id         = azurerm_data_factory.main.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.main.id

  enabled_log {
    category = "PipelineRuns"
  }
  enabled_log {
    category = "ActivityRuns"
  }
  enabled_log {
    category = "TriggerRuns"
  }
  enabled_metric {
    category = "AllMetrics"
  }
}

# Synapse Serverless: consultas SQL terminadas (rendimiento)
resource "azurerm_monitor_diagnostic_setting" "synapse" {
  name                       = "diag-synapse"
  target_resource_id         = azurerm_synapse_workspace.main.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.main.id

  enabled_log {
    category = "BuiltinSqlReqsEnded"
  }
}

# Data Lake: operaciones sobre blobs
resource "azurerm_monitor_diagnostic_setting" "datalake" {
  name                       = "diag-datalake"
  target_resource_id         = "${azurerm_storage_account.datalake.id}/blobServices/default"
  log_analytics_workspace_id = azurerm_log_analytics_workspace.main.id

  enabled_log {
    category = "StorageRead"
  }
  enabled_log {
    category = "StorageWrite"
  }
  enabled_log {
    category = "StorageDelete"
  }
}

# Alerta: falla un pipeline de Data Factory
resource "azurerm_monitor_metric_alert" "adf_fallos" {
  name                = "alert-adf-fallos"
  resource_group_name = azurerm_resource_group.main.name
  scopes              = [azurerm_data_factory.main.id]
  description         = "Un pipeline de Data Factory fallo (incluye el bloqueo del quality gate)"
  severity            = 2
  frequency           = "PT5M"
  window_size         = "PT15M"

  criteria {
    metric_namespace = "Microsoft.DataFactory/factories"
    metric_name      = "PipelineFailedRuns"
    aggregation      = "Total"
    operator         = "GreaterThan"
    threshold        = 0
  }

  action {
    action_group_id = azurerm_monitor_action_group.email.id
  }
}

# Presupuesto mensual con avisos por correo
data "azurerm_subscription" "p09" {}

resource "azurerm_consumption_budget_subscription" "main" {
  name            = "budget-${var.prefix}"
  subscription_id = data.azurerm_subscription.p09.id
  amount          = var.budget_amount
  time_grain      = "Monthly"

  time_period {
    start_date = "2026-10-01T00:00:00Z"
  }

  notification {
    enabled        = true
    threshold      = 50
    operator       = "GreaterThan"
    threshold_type = "Actual"
    contact_emails = [var.alert_email]
  }
  notification {
    enabled        = true
    threshold      = 80
    operator       = "GreaterThan"
    threshold_type = "Actual"
    contact_emails = [var.alert_email]
  }
  notification {
    enabled        = true
    threshold      = 100
    operator       = "GreaterThan"
    threshold_type = "Actual"
    contact_emails = [var.alert_email]
  }
  notification {
    enabled        = true
    threshold      = 100
    operator       = "GreaterThan"
    threshold_type = "Forecasted"
    contact_emails = [var.alert_email]
  }
}