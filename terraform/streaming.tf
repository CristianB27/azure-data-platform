locals {
  tags_temp = { entorno = "temporal" }
}

# ---------- Event Hubs ----------
resource "azurerm_eventhub_namespace" "main" {
  count               = var.deploy_expensive ? 1 : 0
  name                = "evh-${var.prefix}-${random_string.suffix.result}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  sku                 = "Standard"
  capacity            = 1
  tags                = local.tags_temp
}

resource "azurerm_eventhub" "telemetria" {
  count             = var.deploy_expensive ? 1 : 0
  name              = "telemetria"
  namespace_id      = azurerm_eventhub_namespace.main[0].id
  partition_count   = 4
  message_retention = 7
}

# ---------- Stream Analytics ----------
resource "azurerm_stream_analytics_job" "main" {
  count                                    = var.deploy_expensive ? 1 : 0
  name                                     = "asa-${var.prefix}"
  resource_group_name                      = azurerm_resource_group.main.name
  location                                 = azurerm_resource_group.main.location
  compatibility_level                      = "1.2"
  data_locale                              = "en-US"
  events_late_arrival_max_delay_in_seconds = 60
  events_out_of_order_max_delay_in_seconds = 50
  events_out_of_order_policy               = "Adjust"
  output_error_policy                      = "Drop"
  streaming_units                          = 1
  tags                                     = local.tags_temp

  transformation_query = <<QUERY
SELECT
    device_id,
    System.Timestamp() AS window_end,
    AVG(temperature) AS avg_temperature,
    MAX(temperature) AS max_temperature,
    AVG(humidity) AS avg_humidity,
    MAX(humidity) AS max_humidity,
    AVG(pressure) AS avg_pressure,
    COUNT(*) AS events
INTO [salida-bronze]
FROM [entrada-eventhub] TIMESTAMP BY event_time
GROUP BY device_id, TumblingWindow(minute, 1)

SELECT
    device_id AS partition_key,
    CAST(System.Timestamp() AS nvarchar(max)) AS row_key,
    MAX(temperature) AS max_temperature,
    ${var.temperature_threshold} AS threshold
INTO [salida-alertas]
FROM [entrada-eventhub] TIMESTAMP BY event_time
GROUP BY device_id, TumblingWindow(minute, 1)
HAVING MAX(temperature) > ${var.temperature_threshold}
QUERY
}

resource "azurerm_stream_analytics_stream_input_eventhub" "entrada" {
  count                        = var.deploy_expensive ? 1 : 0
  name                         = "entrada-eventhub"
  stream_analytics_job_name    = azurerm_stream_analytics_job.main[0].name
  resource_group_name          = azurerm_resource_group.main.name
  eventhub_name                = azurerm_eventhub.telemetria[0].name
  eventhub_consumer_group_name = "$Default"
  servicebus_namespace         = azurerm_eventhub_namespace.main[0].name
  shared_access_policy_name    = "RootManageSharedAccessKey"
  shared_access_policy_key     = azurerm_eventhub_namespace.main[0].default_primary_key

  serialization {
    type     = "Json"
    encoding = "UTF8"
  }
}

resource "azurerm_stream_analytics_output_blob" "bronze" {
  count                     = var.deploy_expensive ? 1 : 0
  name                      = "salida-bronze"
  stream_analytics_job_name = azurerm_stream_analytics_job.main[0].name
  resource_group_name       = azurerm_resource_group.main.name
  storage_account_name      = azurerm_storage_account.datalake.name
  storage_account_key       = azurerm_storage_account.datalake.primary_access_key
  storage_container_name    = "bronze"
  path_pattern              = "streaming/agregados/{date}/{time}"
  date_format               = "yyyy-MM-dd"
  time_format               = "HH"

  serialization {
    type     = "Json"
    encoding = "UTF8"
    format   = "LineSeparated"
  }

  depends_on = [azurerm_storage_data_lake_gen2_filesystem.layers]
}

resource "azurerm_stream_analytics_output_table" "alertas" {
  count                     = var.deploy_expensive ? 1 : 0
  name                      = "salida-alertas"
  stream_analytics_job_name = azurerm_stream_analytics_job.main[0].name
  resource_group_name       = azurerm_resource_group.main.name
  storage_account_name      = azurerm_storage_account.aux.name
  storage_account_key       = azurerm_storage_account.aux.primary_access_key
  table                     = azurerm_storage_table.alertas.name
  partition_key             = "partition_key"
  row_key                   = "row_key"
  batch_size                = 100
}

# Arranca el job al desplegar (y lo detiene al destruir)
resource "azurerm_stream_analytics_job_schedule" "inicio" {
  count                   = var.deploy_expensive ? 1 : 0
  stream_analytics_job_id = azurerm_stream_analytics_job.main[0].id
  start_mode              = "JobStartTime"

  depends_on = [
    azurerm_stream_analytics_stream_input_eventhub.entrada,
    azurerm_stream_analytics_output_blob.bronze,
    azurerm_stream_analytics_output_table.alertas,
  ]
}