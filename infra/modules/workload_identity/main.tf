# Per-workload Azure identity for a Kubernetes service account. Pods annotated
# with this identity's client ID exchange their projected service-account token
# for an Entra ID token: no secret ever lands in the cluster.
#
# This is the reusable unit of the onboarding path: every mission app gets one.

resource "azurerm_user_assigned_identity" "this" {
  name                = "id-${var.name_prefix}-${var.workload_name}"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

resource "azurerm_federated_identity_credential" "this" {
  name                      = "aks-${var.namespace}-${var.service_account_name}"
  user_assigned_identity_id = azurerm_user_assigned_identity.this.id
  issuer                    = var.oidc_issuer_url
  subject                   = "system:serviceaccount:${var.namespace}:${var.service_account_name}"
  audience                  = ["api://AzureADTokenExchange"]
}

resource "azurerm_role_assignment" "key_vault_secrets_user" {
  scope                            = var.key_vault_id
  role_definition_name             = "Key Vault Secrets User"
  principal_id                     = azurerm_user_assigned_identity.this.principal_id
  skip_service_principal_aad_check = true
}
