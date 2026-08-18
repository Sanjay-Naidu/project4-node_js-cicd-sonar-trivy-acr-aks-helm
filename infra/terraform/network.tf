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
 * IMPORTANT - this cost a broken deployment to learn, so it is written down:
 *
 * AKS creates its OWN NSG in the node resource group and attaches it to the
 * node NICs. When a Service of type LoadBalancer is created, the cloud
 * controller automatically programs "Allow Internet -> <port>" rules on THAT
 * NSG. It does not know about, and will never touch, a custom NSG attached to
 * the subnet.
 *
 * Traffic must pass BOTH NSGs. So a subnet NSG that ends in DenyAllInBound -
 * which looks like good practice - silently blackholes every LoadBalancer and
 * ingress Service on the cluster, while the pods themselves stay perfectly
 * healthy. The symptom is maddening: `helm test` passes in-cluster, endpoints
 * are populated, the LB reports healthy, and every request from the internet
 * times out.
 *
 * The AllowInternetToLoadBalancedServices rule below is what makes the ingress
 * controller and the LoadBalancer Service reachable. The alternative is to not
 * attach a custom NSG at all and let AKS manage it, which is what most AKS
 * deployments do; an explicit rule is kept here because "deny by default with
 * documented exceptions" is worth more than one saved resource.
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

  # The data path for every LoadBalancer / ingress Service on this cluster.
  #
  # 80/443 carry the traffic (AKS load balancer rules use floating IP, so the
  # node sees the original destination port). The 30000-32767 range is the
  # Kubernetes nodePort range, included because a Service without floating IP
  # is forwarded to its nodePort instead - covering both modes means adding a
  # Service never requires an infrastructure change.
  security_rule {
    name                       = "AllowInternetToLoadBalancedServices"
    priority                   = 120
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_ranges    = ["80", "443", "30000-32767"]
    source_address_prefix      = "Internet"
    destination_address_prefix = "*"
  }

  # Everything not explicitly allowed above. SSH (22) is deliberately not
  # opened: node access goes through `kubectl debug node/...`, not a bastion.
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
