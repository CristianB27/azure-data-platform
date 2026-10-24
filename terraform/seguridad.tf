variable "usuario_object_id" {
  description = "Object ID del usuario del equipo con lectura en las capas"
  type        = string
  default     = "89ef98c4-fc9e-401c-98a1-58db1ed553e2"
}

locals {
  contenedores_id = "${azurerm_storage_account.datalake.id}/blobServices/default/containers"
}

# Synapse: solo lectura en Silver y Gold (Bronze queda sin acceso)
resource "azurerm_role_assignment" "synapse_lectura" {
  for_each                         = toset(["silver", "gold"])
  scope                            = "${local.contenedores_id}/${each.key}"
  role_definition_name             = "Storage Blob Data Reader"
  principal_id                     = azurerm_synapse_workspace.main.identity[0].principal_id
  skip_service_principal_aad_check = true

  depends_on = [azurerm_storage_data_lake_gen2_filesystem.layers]
}

# Synapse: escritura solo en su propio contenedor de trabajo
resource "azurerm_role_assignment" "synapse_propio" {
  scope                            = "${local.contenedores_id}/${azurerm_storage_data_lake_gen2_filesystem.synapse.name}"
  role_definition_name             = "Storage Blob Data Contributor"
  principal_id                     = azurerm_synapse_workspace.main.identity[0].principal_id
  skip_service_principal_aad_check = true
}

# Usuario del equipo: lectura en las tres capas
resource "azurerm_role_assignment" "usuario_lectura" {
  for_each             = toset(["bronze", "silver", "gold"])
  scope                = "${local.contenedores_id}/${each.key}"
  role_definition_name = "Storage Blob Data Reader"
  principal_id         = var.usuario_object_id

  depends_on = [azurerm_storage_data_lake_gen2_filesystem.layers]
}