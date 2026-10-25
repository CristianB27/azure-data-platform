# Streaming -> Bronze -> (quality gate) -> Silver -> Gold
# Misma secuencia que el batch, sin excepciones (PDF 4.2).
# No usa count: solo define ADF; los datos de Bronze persisten aunque el streaming se apague.

locals {
  # JSON que escribe Stream Analytics en bronze/streaming/agregados/{fecha}/{hora}/
  bronze_stream_schema = "output(device_id as string, window_end as string, avg_temperature as double, max_temperature as double, avg_humidity as double, max_humidity as double, avg_pressure as double, events as long)"
  silver_stream_schema = "output(device_id as string, window_end as timestamp, avg_temperature as double, max_temperature as double, avg_humidity as double, max_humidity as double, avg_pressure as double, events as long)"
}

# Linked service Blob hacia el Data Lake (el dataset JSON solo admite endpoint Blob)
resource "azurerm_data_factory_linked_service_azure_blob_storage" "datalake_blob" {
  name                 = "ls_datalake_blob"
  data_factory_id      = azurerm_data_factory.main.id
  service_endpoint     = azurerm_storage_account.datalake.primary_blob_endpoint
  use_managed_identity = true
  storage_kind         = "StorageV2"
}

# ---------- Datasets ----------
resource "azurerm_data_factory_dataset_json" "bronze_stream" {
  name                = "ds_bronze_streaming"
  data_factory_id     = azurerm_data_factory.main.id
  linked_service_name = azurerm_data_factory_linked_service_azure_blob_storage.datalake_blob.name

  azure_blob_storage_location {
    container = "bronze"
    path      = "streaming/agregados"
    filename  = "*.json"
  }

  encoding = "UTF-8"
}

resource "azurerm_data_factory_dataset_parquet" "calidad_stream" {
  name                = "ds_calidad_streaming"
  data_factory_id     = azurerm_data_factory.main.id
  linked_service_name = azurerm_data_factory_linked_service_data_lake_storage_gen2.datalake.name

  azure_blob_fs_location {
    file_system = "bronze"
    path        = "_calidad_streaming"
  }

  compression_codec = "snappy"
}

resource "azurerm_data_factory_dataset_parquet" "silver_stream" {
  name                = "ds_silver_streaming"
  data_factory_id     = azurerm_data_factory.main.id
  linked_service_name = azurerm_data_factory_linked_service_data_lake_storage_gen2.datalake.name

  azure_blob_fs_location {
    file_system = "silver"
    path        = "telemetria_streaming"
  }

  compression_codec = "snappy"
}

resource "azurerm_data_factory_dataset_parquet" "gold_stream" {
  name                = "ds_gold_streaming"
  data_factory_id     = azurerm_data_factory.main.id
  linked_service_name = azurerm_data_factory_linked_service_data_lake_storage_gen2.datalake.name

  azure_blob_fs_location {
    file_system = "gold"
    path        = "telemetria_streaming_diaria"
  }

  compression_codec = "snappy"
}

# ---------- Data Flow 1: quality gate del streaming ----------
resource "azurerm_data_factory_data_flow" "calidad_stream" {
  name            = "df_calidad_streaming"
  data_factory_id = azurerm_data_factory.main.id

  source {
    name = "fuente"
    dataset {
      name = azurerm_data_factory_dataset_json.bronze_stream.name
    }
  }

  sink {
    name = "metricasSink"
    dataset {
      name = azurerm_data_factory_dataset_parquet.calidad_stream.name
    }
  }

  transformation {
    name = "metricas"
  }

  script_lines = [
    "source(${local.bronze_stream_schema}, allowSchemaDrift: false, validateSchema: false, ignoreNoFilesFound: false, documentForm: 'documentPerLine', wildcardPaths:['streaming/agregados/*/*/*.json']) ~> fuente",
    "fuente aggregate(total = count(), nulos = countIf(isNull(device_id) || isNull(window_end) || isNull(avg_temperature) || isNull(max_temperature) || isNull(avg_humidity) || isNull(avg_pressure) || isNull(events)), distintos = countDistinct(device_id, window_end)) ~> metricas",
    "metricas sink(allowSchemaDrift: true, validateSchema: false, format: 'parquet', partitionFileNames:['metricas.parquet'], truncate: true, umask: 0022, preCommands: [], postCommands: [], skipDuplicateMapInputs: true, skipDuplicateMapOutputs: true, partitionBy('hash', 1)) ~> metricasSink",
  ]
}

# ---------- Data Flow 2: Bronze (JSON) -> Silver ----------
resource "azurerm_data_factory_data_flow" "silver_stream" {
  name            = "df_silver_streaming"
  data_factory_id = azurerm_data_factory.main.id

  source {
    name = "fuente"
    dataset {
      name = azurerm_data_factory_dataset_json.bronze_stream.name
    }
  }

  sink {
    name = "destinoSilver"
    dataset {
      name = azurerm_data_factory_dataset_parquet.silver_stream.name
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
    "source(${local.bronze_stream_schema}, allowSchemaDrift: false, validateSchema: false, ignoreNoFilesFound: false, documentForm: 'documentPerLine', wildcardPaths:['streaming/agregados/*/*/*.json']) ~> fuente",
    "fuente derive(window_end = toTimestamp(replace(substring(window_end, 1, 19), 'T', ' '), 'yyyy-MM-dd HH:mm:ss')) ~> tipos",
    "tipos filter(!isNull(device_id) && !isNull(window_end) && !isNull(avg_temperature) && !isNull(max_temperature) && !isNull(avg_humidity) && !isNull(avg_pressure) && !isNull(events)) ~> sinNulos",
    "sinNulos aggregate(groupBy(device_id, window_end), avg_temperature = first(avg_temperature), max_temperature = first(max_temperature), avg_humidity = first(avg_humidity), max_humidity = first(max_humidity), avg_pressure = first(avg_pressure), events = first(events)) ~> sinDuplicados",
    "sinDuplicados sink(allowSchemaDrift: true, validateSchema: false, format: 'parquet', truncate: true, umask: 0022, preCommands: [], postCommands: [], skipDuplicateMapInputs: true, skipDuplicateMapOutputs: true) ~> destinoSilver",
  ]
}

# ---------- Data Flow 3: Silver -> Gold (mismo esquema que el Gold batch) ----------
resource "azurerm_data_factory_data_flow" "gold_stream" {
  name            = "df_gold_streaming"
  data_factory_id = azurerm_data_factory.main.id

  source {
    name = "fuente"
    dataset {
      name = azurerm_data_factory_dataset_parquet.silver_stream.name
    }
  }

  sink {
    name = "destinoGold"
    dataset {
      name = azurerm_data_factory_dataset_parquet.gold_stream.name
    }
  }

  transformation {
    name = "conFecha"
  }
  transformation {
    name = "diario"
  }

  script_lines = [
    "source(${local.silver_stream_schema}, allowSchemaDrift: false, validateSchema: false, ignoreNoFilesFound: false, format: 'parquet') ~> fuente",
    "fuente derive(fecha = toDate(window_end)) ~> conFecha",
    "conFecha aggregate(groupBy(device_id, fecha), lecturas = sum(events), temp_promedio = round(sum(avg_temperature * events) / sum(events), 2), temp_maxima = max(max_temperature), humedad_promedio = round(sum(avg_humidity * events) / sum(events), 2), presion_promedio = round(sum(avg_pressure * events) / sum(events), 2)) ~> diario",
    "diario sink(allowSchemaDrift: true, validateSchema: false, format: 'parquet', truncate: true, umask: 0022, preCommands: [], postCommands: [], skipDuplicateMapInputs: true, skipDuplicateMapOutputs: true) ~> destinoGold",
  ]
}

# ---------- Pipeline del streaming ----------
resource "azurerm_data_factory_pipeline" "streaming" {
  name            = "pl_streaming_medallion"
  data_factory_id = azurerm_data_factory.main.id

  parameters = {
    max_null_pct = "20"
  }

  activities_json = jsonencode([
    {
      name = "df_calidad_streaming"
      type = "ExecuteDataFlow"
      typeProperties = {
        dataFlow           = { referenceName = azurerm_data_factory_data_flow.calidad_stream.name, type = "DataFlowReference" }
        compute            = { coreCount = 8, computeType = "General" }
        integrationRuntime = { referenceName = azurerm_data_factory_integration_runtime_azure.dataflow.name, type = "IntegrationRuntimeReference" }
        traceLevel         = "Fine"
      }
    },
    {
      name      = "leer_metricas"
      type      = "Lookup"
      dependsOn = [{ activity = "df_calidad_streaming", dependencyConditions = ["Succeeded"] }]
      typeProperties = {
        source = {
          type          = "ParquetSource"
          storeSettings = { type = "AzureBlobFSReadSettings", recursive = false, wildcardFileName = "*.parquet" }
        }
        dataset = {
          referenceName = azurerm_data_factory_dataset_parquet.calidad_stream.name
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
        expression = {
          type  = "Expression"
          value = "@and(greater(int(${local.m}.total), 0), lessOrEquals(div(mul(float(${local.m}.nulos), 100), float(max(1, int(${local.m}.total)))), float(pipeline().parameters.max_null_pct)))"
        }
        ifTrueActivities = [
          {
            name = "df_silver_streaming"
            type = "ExecuteDataFlow"
            typeProperties = {
              dataFlow           = { referenceName = azurerm_data_factory_data_flow.silver_stream.name, type = "DataFlowReference" }
              compute            = { coreCount = 8, computeType = "General" }
              integrationRuntime = { referenceName = azurerm_data_factory_integration_runtime_azure.dataflow.name, type = "IntegrationRuntimeReference" }
              traceLevel         = "Fine"
            }
          },
          {
            name      = "df_gold_streaming"
            type      = "ExecuteDataFlow"
            dependsOn = [{ activity = "df_silver_streaming", dependencyConditions = ["Succeeded"] }]
            typeProperties = {
              dataFlow           = { referenceName = azurerm_data_factory_data_flow.gold_stream.name, type = "DataFlowReference" }
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
              message   = "Quality gate (streaming) no superado: 0 filas o demasiados nulos. No se promueve a Silver."
              errorCode = "CalidadDatos"
            }
          },
        ]
      }
    },
  ])

  depends_on = [
    azurerm_role_assignment.adf_datalake,
  ]
}

# Trigger horario, creado desactivado (se corre a mano para la evidencia)
resource "azurerm_data_factory_trigger_schedule" "streaming_horario" {
  name            = "tr_streaming_horario"
  data_factory_id = azurerm_data_factory.main.id
  pipeline_name   = azurerm_data_factory_pipeline.streaming.name

  frequency  = "Hour"
  interval   = 1
  start_time = "2026-10-05T00:00:00Z"
  activated  = false
}