locals {
  adf_name = "adf-${var.prefix}-${random_string.suffix.result}"

  # Esquema de Bronze (todo texto) y de Silver (ya tipado)
  bronze_schema = "output(device_id as string, event_time as string, temperature as string, humidity as string, pressure as string)"
  silver_schema = "output(device_id as string, event_time as timestamp, temperature as double, humidity as double, pressure as double)"

  # Métricas persistidas por el Data Flow de calidad y leídas por Lookup
  m = "activity('leer_metricas').output.firstRow"
}

# ---------- Data Factory ----------
resource "azurerm_data_factory" "main" {
  name                = local.adf_name
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name

  identity {
    type = "SystemAssigned"
  }
}

# Permisos de la identidad de ADF sobre las dos Storage Accounts
resource "azurerm_role_assignment" "adf_datalake" {
  scope                            = azurerm_storage_account.datalake.id
  role_definition_name             = "Storage Blob Data Contributor"
  principal_id                     = azurerm_data_factory.main.identity[0].principal_id
  skip_service_principal_aad_check = true
}

resource "azurerm_role_assignment" "adf_aux" {
  scope                            = azurerm_storage_account.aux.id
  role_definition_name             = "Storage Blob Data Reader"
  principal_id                     = azurerm_data_factory.main.identity[0].principal_id
  skip_service_principal_aad_check = true
}

# ---------- Runtime para Data Flows (el clúster se reutiliza 5 min) ----------
resource "azurerm_data_factory_integration_runtime_azure" "dataflow" {
  name             = "ir-dataflow"
  data_factory_id  = azurerm_data_factory.main.id
  location         = var.location
  compute_type     = "General"
  core_count       = 8
  time_to_live_min = 5
  cleanup_enabled  = true
}

# ---------- Origen: CSV en la Storage auxiliar ----------
resource "azurerm_storage_container" "origen" {
  name                  = "origen"
  storage_account_id    = azurerm_storage_account.aux.id
  container_access_type = "private"
}

resource "azurerm_storage_blob" "csv" {
  name                   = "telemetria.csv"
  storage_account_name   = azurerm_storage_account.aux.name
  storage_container_name = azurerm_storage_container.origen.name
  type                   = "Block"
  source                 = "${path.module}/../data/telemetria_batch.csv"
}

# ---------- Linked services (con identidad administrada) ----------
resource "azurerm_data_factory_linked_service_azure_blob_storage" "aux" {
  name                 = "ls_aux"
  data_factory_id      = azurerm_data_factory.main.id
  service_endpoint     = azurerm_storage_account.aux.primary_blob_endpoint
  use_managed_identity = true
}

resource "azurerm_data_factory_linked_service_data_lake_storage_gen2" "datalake" {
  name                 = "ls_datalake"
  data_factory_id      = azurerm_data_factory.main.id
  url                  = azurerm_storage_account.datalake.primary_dfs_endpoint
  use_managed_identity = true
}

# ---------- Datasets ----------
resource "azurerm_data_factory_dataset_delimited_text" "origen" {
  name                = "ds_origen_csv"
  data_factory_id     = azurerm_data_factory.main.id
  linked_service_name = azurerm_data_factory_linked_service_azure_blob_storage.aux.name

  azure_blob_storage_location {
    container = azurerm_storage_container.origen.name
    filename  = "telemetria.csv"
  }

  column_delimiter    = ","
  row_delimiter       = "\n"
  encoding            = "UTF-8"
  first_row_as_header = true
}

resource "azurerm_data_factory_dataset_parquet" "bronze" {
  name                = "ds_bronze_batch"
  data_factory_id     = azurerm_data_factory.main.id
  linked_service_name = azurerm_data_factory_linked_service_data_lake_storage_gen2.datalake.name

  azure_blob_fs_location {
    file_system = "bronze"
    path        = "batch"
    filename    = "telemetria.parquet"
  }

  compression_codec = "snappy"
}

resource "azurerm_data_factory_dataset_parquet" "calidad" {
  name                = "ds_calidad"
  data_factory_id     = azurerm_data_factory.main.id
  linked_service_name = azurerm_data_factory_linked_service_data_lake_storage_gen2.datalake.name

  azure_blob_fs_location {
    file_system = "bronze"
    path        = "_calidad"
  }

  compression_codec = "snappy"
}

resource "azurerm_data_factory_dataset_parquet" "silver" {
  name                = "ds_silver"
  data_factory_id     = azurerm_data_factory.main.id
  linked_service_name = azurerm_data_factory_linked_service_data_lake_storage_gen2.datalake.name

  azure_blob_fs_location {
    file_system = "silver"
    path        = "telemetria"
  }

  compression_codec = "snappy"
}

resource "azurerm_data_factory_dataset_parquet" "gold" {
  name                = "ds_gold"
  data_factory_id     = azurerm_data_factory.main.id
  linked_service_name = azurerm_data_factory_linked_service_data_lake_storage_gen2.datalake.name

  azure_blob_fs_location {
    file_system = "gold"
    path        = "telemetria_diaria"
  }

  compression_codec = "snappy"
}

# ---------- Data Flow 1: quality gate (persiste las métricas para Lookup) ----------
resource "azurerm_data_factory_data_flow" "calidad" {
  name            = "df_calidad"
  data_factory_id = azurerm_data_factory.main.id

  source {
    name = "fuente"
    dataset {
      name = azurerm_data_factory_dataset_parquet.bronze.name
    }
  }

  sink {
    name = "metricasSink"
    dataset {
      name = azurerm_data_factory_dataset_parquet.calidad.name
    }
  }

  transformation {
    name = "metricas"
  }

  script_lines = [
    "source(${local.bronze_schema}, allowSchemaDrift: false, validateSchema: false, ignoreNoFilesFound: false, format: 'parquet') ~> fuente",
    "fuente aggregate(total = count(), nulos = countIf(isNull(device_id) || isNull(event_time) || isNull(temperature) || isNull(humidity) || isNull(pressure)), distintos = countDistinct(device_id, event_time)) ~> metricas",
    "metricas sink(allowSchemaDrift: true, validateSchema: false, format: 'parquet', partitionFileNames:['metricas.parquet'], truncate: true, umask: 0022, preCommands: [], postCommands: [], skipDuplicateMapInputs: true, skipDuplicateMapOutputs: true, partitionBy('hash', 1)) ~> metricasSink",
  ]
}

# ---------- Data Flow 2: Bronze -> Silver ----------
resource "azurerm_data_factory_data_flow" "silver" {
  name            = "df_silver"
  data_factory_id = azurerm_data_factory.main.id

  source {
    name = "fuente"
    dataset {
      name = azurerm_data_factory_dataset_parquet.bronze.name
    }
  }

  sink {
    name = "destinoSilver"
    dataset {
      name = azurerm_data_factory_dataset_parquet.silver.name
    }
  }

  transformation {
    name = "tipos"
  }
  transformation {
    name = "sinNulos"
  }
  transformation {
    name = "sinDuplicados"
  }

  script_lines = [
    "source(${local.bronze_schema}, allowSchemaDrift: false, validateSchema: false, ignoreNoFilesFound: false, format: 'parquet') ~> fuente",
    "fuente derive(temperature = toDouble(temperature), humidity = toDouble(humidity), pressure = toDouble(pressure), event_time = coalesce(toTimestamp(event_time, 'yyyy-MM-dd HH:mm:ss'), toTimestamp(event_time, 'dd/MM/yyyy HH:mm:ss'))) ~> tipos",
    "tipos filter(!isNull(device_id) && !isNull(event_time) && !isNull(temperature) && !isNull(humidity) && !isNull(pressure)) ~> sinNulos",
    "sinNulos aggregate(groupBy(device_id, event_time), temperature = first(temperature), humidity = first(humidity), pressure = first(pressure)) ~> sinDuplicados",
    "sinDuplicados sink(allowSchemaDrift: true, validateSchema: false, format: 'parquet', truncate: true, umask: 0022, preCommands: [], postCommands: [], skipDuplicateMapInputs: true, skipDuplicateMapOutputs: true) ~> destinoSilver",
  ]
}

# ---------- Data Flow 3: Silver -> Gold ----------
resource "azurerm_data_factory_data_flow" "gold" {
  name            = "df_gold"
  data_factory_id = azurerm_data_factory.main.id

  source {
    name = "fuente"
    dataset {
      name = azurerm_data_factory_dataset_parquet.silver.name
    }
  }

  sink {
    name = "destinoGold"
    dataset {
      name = azurerm_data_factory_dataset_parquet.gold.name
    }
  }

  transformation {
    name = "conFecha"
  }
  transformation {
    name = "diario"
  }

  script_lines = [
    "source(${local.silver_schema}, allowSchemaDrift: false, validateSchema: false, ignoreNoFilesFound: false, format: 'parquet') ~> fuente",
    "fuente derive(fecha = toDate(event_time)) ~> conFecha",
    "conFecha aggregate(groupBy(device_id, fecha), lecturas = count(), temp_promedio = round(avg(temperature), 2), temp_maxima = max(temperature), humedad_promedio = round(avg(humidity), 2), presion_promedio = round(avg(pressure), 2)) ~> diario",
    "diario sink(allowSchemaDrift: true, validateSchema: false, format: 'parquet', truncate: true, umask: 0022, preCommands: [], postCommands: [], skipDuplicateMapInputs: true, skipDuplicateMapOutputs: true) ~> destinoGold",
  ]
}

# ---------- Pipeline batch ----------
resource "azurerm_data_factory_pipeline" "batch" {
  name            = "pl_batch_medallion"
  data_factory_id = azurerm_data_factory.main.id

  parameters = {
    max_null_pct = "20"
  }

  activities_json = jsonencode([
    {
      name = "copy_csv_a_bronze"
      type = "Copy"
      inputs = [{
        referenceName = azurerm_data_factory_dataset_delimited_text.origen.name
        type          = "DatasetReference"
      }]
      outputs = [{
        referenceName = azurerm_data_factory_dataset_parquet.bronze.name
        type          = "DatasetReference"
      }]
      typeProperties = {
        source = {
          type           = "DelimitedTextSource"
          storeSettings  = { type = "AzureBlobStorageReadSettings", recursive = false }
          formatSettings = { type = "DelimitedTextReadSettings" }
        }
        sink = {
          type           = "ParquetSink"
          storeSettings  = { type = "AzureBlobFSWriteSettings" }
          formatSettings = { type = "ParquetWriteSettings" }
        }
        enableStaging = false
      }
    },
    {
      name      = "df_calidad"
      type      = "ExecuteDataFlow"
      dependsOn = [{ activity = "copy_csv_a_bronze", dependencyConditions = ["Succeeded"] }]
      typeProperties = {
        dataflow           = { referenceName = azurerm_data_factory_data_flow.calidad.name, type = "DataFlowReference" }
        compute            = { coreCount = 8, computeType = "General" }
        integrationRuntime = { referenceName = azurerm_data_factory_integration_runtime_azure.dataflow.name, type = "IntegrationRuntimeReference" }
        traceLevel         = "Fine"
      }
    },
    {
      name      = "leer_metricas"
      type      = "Lookup"
      dependsOn = [{ activity = "df_calidad", dependencyConditions = ["Succeeded"] }]
      typeProperties = {
        source = {
          type          = "ParquetSource"
          storeSettings = { type = "AzureBlobFSReadSettings", recursive = false, wildcardFileName = "*.parquet" }
        }
        dataset = {
          referenceName = azurerm_data_factory_dataset_parquet.calidad.name
          type          = "DatasetReference"
        }
        firstRowOnly = true
      }
    },
    {
      name      = "validar_calidad"
      type      = "IfCondition"
      dependsOn = [{ activity = "leer_metricas", dependencyConditions = ["Succeeded"] }]
      typeProperties = {
        # Pasa si hay filas y el % de nulos no supera el umbral
        expression = {
          type  = "Expression"
          value = "@and(greater(int(${local.m}.total), 0), lessOrEquals(div(mul(float(${local.m}.nulos), 100), float(max(1, int(${local.m}.total)))), float(pipeline().parameters.max_null_pct)))"
        }
        ifTrueActivities = [
          {
            name = "df_silver"
            type = "ExecuteDataFlow"
            typeProperties = {
              dataflow           = { referenceName = azurerm_data_factory_data_flow.silver.name, type = "DataFlowReference" }
              compute            = { coreCount = 8, computeType = "General" }
              integrationRuntime = { referenceName = azurerm_data_factory_integration_runtime_azure.dataflow.name, type = "IntegrationRuntimeReference" }
              traceLevel         = "Fine"
            }
          },
          {
            name      = "df_gold"
            type      = "ExecuteDataFlow"
            dependsOn = [{ activity = "df_silver", dependencyConditions = ["Succeeded"] }]
            typeProperties = {
              dataflow           = { referenceName = azurerm_data_factory_data_flow.gold.name, type = "DataFlowReference" }
              compute            = { coreCount = 8, computeType = "General" }
              integrationRuntime = { referenceName = azurerm_data_factory_integration_runtime_azure.dataflow.name, type = "IntegrationRuntimeReference" }
              traceLevel         = "Fine"
            }
          },
        ]
        ifFalseActivities = [
          {
            name = "bloquear_promocion"
            type = "Fail"
            typeProperties = {
              message   = "Quality gate no superado: el lote tiene 0 filas o demasiados nulos. No se promueve a Silver."
              errorCode = "CalidadDatos"
            }
          },
        ]
      }
    },
  ])

  depends_on = [
    azurerm_role_assignment.adf_datalake,
    azurerm_role_assignment.adf_aux,
  ]
}

# ---------- Trigger diario 2:00 AM (Colombia), creado desactivado ----------
resource "azurerm_data_factory_trigger_schedule" "diario" {
  name            = "tr_diario_2am"
  data_factory_id = azurerm_data_factory.main.id
  pipeline_name   = azurerm_data_factory_pipeline.batch.name

  frequency  = "Day"
  interval   = 1
  start_time = "2026-10-05T00:00:00Z"
  time_zone  = "SA Pacific Standard Time"
  activated  = false

  schedule {
    hours   = [2]
    minutes = [0]
  }
}
