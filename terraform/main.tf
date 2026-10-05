resource "azurerm_resource_group" "main" {
  name     = "rg-${var.prefix}-data"
  location = var.location
}

resource "random_string" "suffix" {
  length  = 4
  upper   = false
  special = false
}

# ---------- Data Lake (persistente) ----------
resource "azurerm_storage_account" "datalake" {
  name                     = "stp09utbdl${random_string.suffix.result}"
  resource_group_name      = azurerm_resource_group.main.name
  location                 = azurerm_resource_group.main.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  account_kind             = "StorageV2"
  is_hns_enabled           = true
  min_tls_version          = "TLS1_2"
}

resource "azurerm_storage_data_lake_gen2_filesystem" "layers" {
  for_each           = toset(["bronze", "silver", "gold"])
  name               = each.key
  storage_account_id = azurerm_storage_account.datalake.id
}

# Bronze: más de 90 días -> Cool; más de 365 días -> Archive
resource "azurerm_storage_management_policy" "lifecycle" {
  storage_account_id = azurerm_storage_account.datalake.id

  rule {
    name    = "bronze-tiering"
    enabled = true

    filters {
      prefix_match = ["bronze/"]
      blob_types   = ["blockBlob"]
    }

    actions {
      base_blob {
        tier_to_cool_after_days_since_modification_greater_than    = 90
        tier_to_archive_after_days_since_modification_greater_than = 365
      }
    }
  }
}

# ---------- Storage auxiliar: tabla de alertas (persistente) ----------
resource "azurerm_storage_account" "aux" {
  name                     = "stp09utbaux${random_string.suffix.result}"
  resource_group_name      = azurerm_resource_group.main.name
  location                 = azurerm_resource_group.main.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  account_kind             = "StorageV2"
  min_tls_version          = "TLS1_2"
}

resource "azurerm_storage_table" "alertas" {
  name               = "alertas"
  storage_account_id = azurerm_storage_account.aux.id
}