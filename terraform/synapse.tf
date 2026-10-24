# Sistema de archivos propio del workspace dentro del Data Lake
resource "azurerm_storage_data_lake_gen2_filesystem" "synapse" {
  name               = "synapse"
  storage_account_id = azurerm_storage_account.datalake.id
}

resource "azurerm_synapse_workspace" "main" {
  name                                 = "syn-${var.prefix}-${random_string.suffix.result}"
  resource_group_name                  = azurerm_resource_group.main.name
  location                             = var.synapse_location
  storage_data_lake_gen2_filesystem_id = azurerm_storage_data_lake_gen2_filesystem.synapse.id
  sql_administrator_login              = "sqladminp09"
  sql_administrator_login_password     = var.synapse_admin_password

  identity {
    type = "SystemAssigned"
  }
}

# Acceso abierto para la demo; se restringe en la fase de seguridad
resource "azurerm_synapse_firewall_rule" "allow_all" {
  name                 = "AllowAll"
  synapse_workspace_id = azurerm_synapse_workspace.main.id
  start_ip_address     = "0.0.0.0"
  end_ip_address       = "255.255.255.255"
}

# El workspace lee Silver y Gold con su identidad administrada
resource "azurerm_role_assignment" "synapse_datalake" {
  scope                = azurerm_storage_account.datalake.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_synapse_workspace.main.identity[0].principal_id
}

output "synapse_sql_serverless_endpoint" {
  value = azurerm_synapse_workspace.main.connectivity_endpoints["sqlOnDemand"]
}

# Usuario como administrador del workspace (para Synapse Studio)
resource "azurerm_synapse_role_assignment" "admin_usuario" {
  synapse_workspace_id = azurerm_synapse_workspace.main.id
  role_name            = "Synapse Administrator"
  principal_id         = "89ef98c4-fc9e-401c-98a1-58db1ed553e2"
  principal_type       = "User"

  depends_on = [azurerm_synapse_firewall_rule.allow_all]
}