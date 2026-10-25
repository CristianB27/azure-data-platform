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

# ---------- Monitoreo de Stream Analytics (solo si deploy_expensive) ----------

# Alerta: el job deja de recibir/procesar eventos
resource "azurerm_monitor_metric_alert" "asa_sin_eventos" {
  count               = var.deploy_expensive ? 1 : 0
  name                = "alert-asa-sin-eventos"
  resource_group_name = azurerm_resource_group.main.name
  scopes              = [azurerm_stream_analytics_job.main[0].id]
  description         = "Stream Analytics no esta procesando eventos de entrada"
  severity            = 2
  frequency           = "PT1M"
  window_size         = "PT5M"

  criteria {
    metric_namespace = "Microsoft.StreamAnalytics/streamingjobs"
    metric_name      = "InputEvents"
    aggregation      = "Total"
    operator         = "LessThan"
    threshold        = 1
  }

  action {
    action_group_id = azurerm_monitor_action_group.email.id
  }
}

# Alerta: retraso del watermark (latencia del streaming)
resource "azurerm_monitor_metric_alert" "asa_watermark" {
  count               = var.deploy_expensive ? 1 : 0
  name                = "alert-asa-watermark"
  resource_group_name = azurerm_resource_group.main.name
  scopes              = [azurerm_stream_analytics_job.main[0].id]
  description         = "El watermark delay de Stream Analytics supera 120 s"
  severity            = 3
  frequency           = "PT1M"
  window_size         = "PT5M"

  criteria {
    metric_namespace = "Microsoft.StreamAnalytics/streamingjobs"
    metric_name      = "OutputWatermarkDelaySeconds"
    aggregation      = "Maximum"
    operator         = "GreaterThan"
    threshold        = 120
  }

  action {
    action_group_id = azurerm_monitor_action_group.email.id
  }
}

# Logs y métricas del job hacia Log Analytics
resource "azurerm_monitor_diagnostic_setting" "asa" {
  count                      = var.deploy_expensive ? 1 : 0
  name                       = "diag-asa"
  target_resource_id         = azurerm_stream_analytics_job.main[0].id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.main.id

  enabled_log {
    category = "Execution"
  }
  enabled_metric {
    category = "AllMetrics"
  }
}