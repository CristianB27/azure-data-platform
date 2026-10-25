# ---------- Red privada para el Data Lake (solo si deploy_expensive) ----------

resource "azurerm_virtual_network" "main" {
  count               = var.deploy_expensive ? 1 : 0
  name                = "vnet-${var.prefix}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  address_space       = ["10.10.0.0/16"]
}

resource "azurerm_subnet" "endpoints" {
  count                = var.deploy_expensive ? 1 : 0
  name                 = "snet-endpoints"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main[0].name
  address_prefixes     = ["10.10.1.0/24"]
}

# DNS privado: resuelve el nombre del Data Lake a la IP privada
resource "azurerm_private_dns_zone" "dfs" {
  count               = var.deploy_expensive ? 1 : 0
  name                = "privatelink.dfs.core.windows.net"
  resource_group_name = azurerm_resource_group.main.name
}

resource "azurerm_private_dns_zone_virtual_network_link" "dfs" {
  count                 = var.deploy_expensive ? 1 : 0
  name                  = "link-dfs"
  resource_group_name   = azurerm_resource_group.main.name
  private_dns_zone_name = azurerm_private_dns_zone.dfs[0].name
  virtual_network_id    = azurerm_virtual_network.main[0].id
}

# Private Endpoint hacia el Data Lake (ADLS Gen2, subrecurso dfs)
resource "azurerm_private_endpoint" "datalake_dfs" {
  count               = var.deploy_expensive ? 1 : 0
  name                = "pe-${var.prefix}-datalake-dfs"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  subnet_id           = azurerm_subnet.endpoints[0].id

  private_service_connection {
    name                           = "psc-datalake-dfs"
    private_connection_resource_id = azurerm_storage_account.datalake.id
    subresource_names              = ["dfs"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "dns-dfs"
    private_dns_zone_ids = [azurerm_private_dns_zone.dfs[0].id]
  }
}