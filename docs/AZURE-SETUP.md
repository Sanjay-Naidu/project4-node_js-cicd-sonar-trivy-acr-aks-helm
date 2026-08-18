# Azure setup

Everything needed to take this repository from clone to a running cluster.

Three things are created by hand — the resource group, the Terraform state storage account, and the Entra ID app registration. Everything else is Terraform's job. That split is deliberate: those three are the "bootstrap" resources that Terraform cannot manage without a chicken-and-egg problem (it needs somewhere to keep state, and an identity to authenticate with, before it can run at all).

---

## 0. Prerequisites

| Tool | Needed for |
|---|---|
| Azure CLI ≥ 2.60 | everything below |
| A GitHub account | the repository and Actions |
| A SonarCloud account | the quality gate (free for public repos) |

```bash
az login
az account set --subscription "<your subscription>"
az account show --output table
```

### Check quota AND SKU permission first

These are two different checks, and the most common first-`apply` failure is passing one while failing the other.

**1. Regional vCPU quota.** The default here (2 × `Standard_D2as_v7`) needs **4**:

```bash
az vm list-usage --location eastus --output table | grep "Total Regional vCPUs"
```

**2. Whether the SKU is permitted at all.** Many trial and MSDN subscriptions block whole families — burstable B-series in particular:

```bash
az vm list-skus --location eastus --size Standard_D2as_v7 --query "[].restrictions" -o json
# [] means usable. Anything else lists the restriction.
```

The trap: `az vm list-usage` will happily report `Standard BS Family vCPUs: limit 4`, implying B-series is available, while AKS rejects the create with:

```
The VM size of Standard_B2s is not allowed in your subscription in location 'eastus'.
```

Quota says "you may use this many"; SKU permission says "you may use this type". You need both. If `Standard_D2as_v7` is restricted on your subscription, the error message from AKS conveniently lists every size that *is* allowed — pick the cheapest one with at least 2 vCPU and 4 GiB.

---

## 1. Resource group

```bash
az group create --name rg-ordersapi-dev --location eastus
```

Terraform reads this as a data source and never manages it, so `terraform destroy` leaves it intact.

---

## 2. Terraform state storage

The storage account name must be globally unique, 3–24 characters, lowercase alphanumeric only.

```bash
STORAGE_ACCOUNT="stordersapitf$RANDOM"

az storage account create \
  --name "$STORAGE_ACCOUNT" \
  --resource-group rg-ordersapi-dev \
  --location eastus \
  --sku Standard_LRS \
  --kind StorageV2 \
  --min-tls-version TLS1_2 \
  --allow-blob-public-access false \
  --allow-shared-key-access false

# Versioning is the cheapest possible insurance against a corrupted or
# truncated state file - it lets you roll back to the previous state blob.
az storage account blob-service-properties update \
  --account-name "$STORAGE_ACCOUNT" \
  --resource-group rg-ordersapi-dev \
  --enable-versioning true

az storage container create \
  --name tfstate \
  --account-name "$STORAGE_ACCOUNT" \
  --auth-mode login

echo "Storage account: $STORAGE_ACCOUNT"
```

`--allow-shared-key-access false` disables the account access keys entirely. The Terraform backend uses `use_azuread_auth = true`, so it authenticates with an Entra ID token instead — there is no key to leak, and the `Storage Blob Data Contributor` role assignment (step 4) is what grants access.

> **Note:** with shared key access disabled you must pass `--auth-mode login` to every `az storage` command, and your own user needs `Storage Blob Data Contributor` on the account to browse the state in the portal.

---

## 3. App registration

```bash
az ad app create --display-name "gh-ordersapi-oidc"

APP_CLIENT_ID=$(az ad app list --display-name "gh-ordersapi-oidc" --query "[0].appId" -o tsv)
echo "Client ID: $APP_CLIENT_ID"
```

Do **not** create a client secret. The whole point of the OIDC setup is that no secret exists.

---

## 4. Wire up OIDC

```powershell
./scripts/azure-oidc-setup.ps1 `
  -AppClientId "<APP_CLIENT_ID>" `
  -GitHubRepo "<owner>/<repo>" `
  -ResourceGroup "rg-ordersapi-dev" `
  -StateStorageAccount "<storage account from step 2>" `
  -SetGitHubVariables
```

```bash
./scripts/azure-oidc-setup.sh \
  --app-client-id "<APP_CLIENT_ID>" \
  --github-repo "<owner>/<repo>" \
  --resource-group "rg-ordersapi-dev" \
  --state-storage-account "<storage account>" \
  --set-github-variables
```

### What it does, and why each part matters

**Federated credentials.** A trust relationship saying "GitHub Actions, running in *this* repository, under *this* trigger, may obtain a token for this app." The `subject` claim must match exactly what GitHub puts in the token:

| Subject | Emitted when |
|---|---|
| `repo:owner/repo:ref:refs/heads/main` | a workflow runs on a push to `main` |
| `repo:owner/repo:pull_request` | a workflow runs on a pull request |
| `repo:owner/repo:environment:dev` | a **job** declares `environment: dev` |

The last row is the one that catches people out. As soon as a job specifies an `environment:`, GitHub emits an *environment* subject rather than a branch subject — so a deploy job fails to authenticate even though the build job on the same commit succeeded. This repo uses four environments (`dev`, `prod`, `infra-apply`, `infra-destroy`) and the script creates a credential for each.

**Role assignments.**

| Role | Scope | Why |
|---|---|---|
| `Contributor` | resource group | create AKS, ACR, VNet, Log Analytics |
| `Role Based Access Control Administrator` | resource group | **Contributor cannot create role assignments.** Terraform creates four of them (AcrPull for the kubelet, AcrPush and two AKS roles for CI). Without this the apply fails partway through with `AuthorizationFailed` |
| `Storage Blob Data Contributor` | storage account | read/write the state blob. Control-plane `Contributor` is *not* sufficient when the backend uses Entra ID auth |
| `Azure Kubernetes Service Cluster User Role` | resource group | permission to run `az aks get-credentials`. Grants nothing inside the cluster — the in-cluster rights come from `rbac.tf` |

---

## 5. Repository configuration

**Settings → Secrets and variables → Actions**

### Variables — set before the first run

| Variable | Where it comes from |
|---|---|
| `AZURE_CLIENT_ID` | app registration |
| `AZURE_TENANT_ID` | `az account show --query tenantId -o tsv` |
| `AZURE_SUBSCRIPTION_ID` | `az account show --query id -o tsv` |
| `AZURE_RESOURCE_GROUP` | `rg-ordersapi-dev` |
| `TFSTATE_RESOURCE_GROUP` | `rg-ordersapi-dev` |
| `TFSTATE_STORAGE_ACCOUNT` | step 2 |
| `TFSTATE_CONTAINER` | `tfstate` |
| `SONAR_ORGANIZATION` | SonarCloud organisation key |
| `SONAR_PROJECT_KEY` | SonarCloud project key |

### Variables — set after `Infrastructure → apply`

That workflow prints them in its job summary.

| Variable | Example |
|---|---|
| `ACR_NAME` | `acrordersapidevx7k2p9` |
| `ACR_LOGIN_SERVER` | `acrordersapidevx7k2p9.azurecr.io` |
| `AKS_CLUSTER_NAME` | `aks-ordersapi-dev` |

### Optional

| Variable | Default | Purpose |
|---|---|---|
| `AKS_NAMESPACE` | `orders-api` | target namespace |
| `SONAR_HOST_URL` | `https://sonarcloud.io` | set for self-hosted SonarQube |
| `ENABLE_IMAGE_SIGNING` | `true` | set `false` to skip cosign |

### Secrets

| Secret | Purpose |
|---|---|
| `SONAR_TOKEN` | SonarCloud analysis token |

There is no `AZURE_CREDENTIALS` secret. That is the point.

---

## 6. Terraform variable

The service principal object id lets Terraform grant the CI identity `AcrPush` and AKS RBAC. Add it to `infra/terraform/environments/dev.tfvars`:

```bash
az ad sp show --id "$APP_CLIENT_ID" --query id -o tsv
```

```hcl
cicd_principal_object_id = "<the object id>"
```

> This is the service principal **object id**, not the application (client) id. They are different GUIDs and using the wrong one produces a `PrincipalNotFound` error at apply time.

You can leave it empty on the first apply and fill it in afterwards — the role assignments are behind a `count` guard.

---

## 7. SonarCloud

1. Sign in at [sonarcloud.io](https://sonarcloud.io) with GitHub.
2. Import the repository. Note the **organisation key** and **project key**.
3. **Administration → Analysis Method** → turn *Automatic Analysis* **off**. It conflicts with CI-based analysis, and leaving it on produces a confusing "project already analysed" error.
4. **My Account → Security** → generate a token → save as the `SONAR_TOKEN` secret.

---

## 8. Run the workflows

| # | Workflow | Notes |
|---|---|---|
| 1 | **Infrastructure** → `apply`, `dev` | ~10–15 minutes. Approve the `infra-apply` environment if you added a gate |
| 2 | *set `ACR_NAME`, `ACR_LOGIN_SERVER`, `AKS_CLUSTER_NAME`* | from the job summary |
| 3 | **Platform bootstrap** → ingress on | installs ingress-nginx, prints the public IP |
| 4 | **CI** | or just push to `main` |

`app/package-lock.json` is committed, so `npm ci` works immediately. **Bootstrap lockfile** is only for regenerating it later without a local Node install.

Verify:

```bash
az aks get-credentials -g rg-ordersapi-dev -n aks-ordersapi-dev
kubelogin convert-kubeconfig -l azurecli

kubectl -n orders-api get deploy,pods,svc,ingress,hpa,pdb
curl "http://$(kubectl -n ingress-nginx get svc ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}')/healthz"
```

---

## Troubleshooting

**`AADSTS70021: No matching federated identity record found`**
The token's subject does not match any federated credential. Print what GitHub actually sent and compare:
```bash
az ad app federated-credential list --id <APP_CLIENT_ID> --query "[].{name:name, subject:subject}" -o table
```
Almost always an `environment:` subject that has no credential.

**`AuthorizationFailed` during `terraform apply`, on a role assignment**
The `Role Based Access Control Administrator` assignment is missing. Re-run the setup script.

**`Error: retrieving Storage Account ... AuthorizationPermissionMismatch`**
`Storage Blob Data Contributor` on the storage account is missing, or was assigned less than a minute ago — Entra ID propagation takes a moment.

**`Insufficient regional vCPU quota`**
See the quota check at the top. Lower `node_count`, change `node_vm_size`, or move region.

**`az aks get-credentials` works but `kubectl` returns Unauthorized**
`kubelogin convert-kubeconfig -l azurecli` was not run. The cluster has local accounts disabled, so the kubeconfig is Entra-backed and needs the conversion.

**Terraform state lock stuck after a cancelled run**
```bash
terraform force-unlock <LOCK_ID>
```
Only when you are certain no other apply is running.
