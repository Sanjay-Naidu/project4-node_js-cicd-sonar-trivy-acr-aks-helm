/**
 * Cluster networking.
 *
 * A dedicated VNet rather than AKS-managed networking, because that is what
 * makes the cluster peerable, firewall-able and private-endpoint-capable later
 * without a rebuild. Azure CNI *Overlay* is used so pods draw from an overlay
 * CIDR instead of consuming real VNet addresses - the /24 node subnet below
 * would otherwise cap the cluster at a handful of pods.
 */

resource "azurerm_virtual_network" "main" {
  name                = local.vnet_name
  location            = data.azurerm_resource_group.main.location
  resource_group_name = data.azurerm_resource_group.main.name
  address_space       = var.vnet_address_space
  tags                = local.common_tags
}

resource "azurerm_subnet" "aks" {
  name                 = "snet-aks-nodes"
  resource_group_name  = data.azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = [var.aks_subnet_prefix]
}

/**
 * Baseline NSG on the node subnet.
 *
 * Azure's default rules already deny inbound from the internet; this exists to
 * make that explicit and auditable, and gives Trivy/Checkov something concrete
 * to assert against. Ingress traffic reaches pods via the Standard Load
 * Balancer, whose rules AKS programs itself - it does not transit this NSG as
 * internet-inbound.
 */
resource "azurerm_network_security_group" "aks" {
  name                = "nsg-${local.name_prefix}-nodes"
  location            = data.azurerm_resource_group.main.location
  resource_group_name = data.azurerm_resource_group.main.name
  tags                = local.common_tags

  security_rule {
    name                       = "AllowVnetInBound"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "VirtualNetwork"
  }

  security_rule {
    name                       = "AllowAzureLoadBalancerInBound"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "AzureLoadBalancer"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "DenyAllInBound"
    priority                   = 4096
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "aks" {
  subnet_id                 = azurerm_subnet.aks.id
  network_security_group_id = azurerm_network_security_group.aks.id
}
