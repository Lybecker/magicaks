provider "azurerm" {
    version = "~>1.5"
}

terraform {
  backend "azurerm" {
    container_name = "tfstate"
    key = "magicaks"
    storage_account_name = "longlasting"
  }
}

resource "azurerm_resource_group" "rg" {
    name     = var.resource_group_name
    location = var.location
}

module "aks" {
    source = "./aks"
    agent_count = var.agent_count
    dns_prefix = var.dns_prefix
    cluster_name = var.cluster_name
    resource_group_name = azurerm_resource_group.rg.name
    location = var.location
    client_id = var.client_id
    client_secret = var.client_secret
    aad_client_appid = var.aad_client_appid
    aad_server_appid = var.aad_server_appid
    aad_server_app_secret = var.aad_server_app_secret
    aad_tenant_id = var.aad_tenant_id
    k8s_subnet_id = var.k8s_subnet_id
}

module flux {
  source = "./flux"
  resource_group_name = azurerm_resource_group.rg.name
  cluster_name = module.aks.name
  ghuser = var.ghuser
  repo = var.k8s_manifest_repo
  pat = var.pat
  flux_recreate = var.flux_recreate
}

resource "azurerm_key_vault" "keyvault" {
  name                        = "${var.cluster_name}-keyvault"
  location                    = var.location
  tenant_id                   = var.tenant_id
  resource_group_name         = azurerm_resource_group.rg.name
  
  enabled_for_deployment          = true
  enabled_for_disk_encryption     = true
  enabled_for_template_deployment = true

  # TODO check and confirm the iffyness of this block!
  network_acls {
    bypass = "AzureServices"
    default_action = "Allow"
    virtual_network_subnet_ids = [var.k8s_subnet_id]
  }

  # Access policy for service principal credentials on the cluster to access kv.
  access_policy {
    tenant_id = var.tenant_id
    object_id = var.client_id

    key_permissions = [
      "get", "create"
    ]

    secret_permissions = [
      "get", "set"
    ]

    storage_permissions = [
      "get", "set"
    ]
  }

  # Access policy for this particular TF run to insert the secret into kv
  access_policy {
    tenant_id = var.tenant_id
    object_id = "3fe3253a-c76e-42aa-ac6a-88a31f287403"

    key_permissions = [
      "get", "create", "delete"
    ]

    secret_permissions = [
      "get", "set", "delete"
    ]

    storage_permissions = [
      "get", "set", "delete"
    ]
  }

  sku_name = "standard"
}

module "servicebus" {  
  source = "./servicebus"
  resource_group_name = azurerm_resource_group.rg.name
  cluster_name = module.aks.name
  location = var.location
  keyvault_id = azurerm_key_vault.keyvault.id
  keyvault_name = azurerm_key_vault.keyvault.name
}

resource "azurerm_key_vault_secret" "sbconnectionstring" {
  name         = "${module.aks.name}-servicebus-connectionstring"
  value        = module.servicebus.primary_connection_string
  key_vault_id = azurerm_key_vault.keyvault.id

  provisioner "local-exec" {
    command = "${path.cwd}/utils/expose-secret.sh ${self.name} ${azurerm_key_vault.keyvault.name} ${var.app_name}"
  }
}