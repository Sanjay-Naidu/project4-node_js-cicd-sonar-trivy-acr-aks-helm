<#
.SYNOPSIS
    Wires an existing Entra ID app registration to GitHub Actions via OIDC.

.DESCRIPTION
    You create the resource group, the state storage account and the app
    registration by hand. This script does the fiddly rest:

      1. Federated credentials  - the trust that lets GitHub mint tokens Azure
                                  will accept. No client secret is ever created.
      2. Role assignments       - what that identity is allowed to do, scoped to
                                  one resource group and one storage container.
      3. GitHub variables       - printed ready to paste (or set automatically
                                  with -SetGitHubVariables if gh CLI is present).

    Idempotent: safe to re-run after adding an environment or changing scope.

.PARAMETER AppClientId
    Application (client) ID of the app registration you created.

.PARAMETER GitHubRepo
    owner/repo, e.g. sanjaynaidu/nodejs-devsecops-aks

.PARAMETER ResourceGroup
    Resource group the workload is deployed into (created manually).

.PARAMETER StateStorageAccount
    Storage account holding Terraform state (created manually).

.PARAMETER StateResourceGroup
    Resource group of the state storage account. Defaults to -ResourceGroup.

.PARAMETER StateContainer
    Blob container for state. Default: tfstate

.PARAMETER SetGitHubVariables
    Also push the repository variables using the gh CLI.

.EXAMPLE
    ./azure-oidc-setup.ps1 -AppClientId "00000000-0000-0000-0000-000000000000" `
                           -GitHubRepo "Sanjay-Naidu/project4-node_js-cicd-sonar-trivy-acr-aks-helm" `
                           -ResourceGroup "rg-ordersapi-dev" `
                           -StateStorageAccount "stordersapitfstate001" `
                           -SetGitHubVariables

.NOTES
    This file must stay pure ASCII. Windows PowerShell 5.1 decodes a .ps1 with
    no byte-order mark as Windows-1252, so a UTF-8 character such as an em dash
    is read as three mojibake bytes - one of which is a double quote. That
    unbalances every string after it and the script fails to parse with errors
    pointing at unrelated lines far below the real cause.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$AppClientId,
    [Parameter(Mandatory = $true)][string]$GitHubRepo,
    [Parameter(Mandatory = $true)][string]$ResourceGroup,
    [Parameter(Mandatory = $true)][string]$StateStorageAccount,
    [string]$StateResourceGroup = "",
    [string]$StateContainer = "tfstate",
    [switch]$SetGitHubVariables
)

# Deliberately NOT 'Stop'. In Windows PowerShell 5.1 anything a native
# executable writes to stderr is wrapped in a NativeCommandError record, so
# 'Stop' turns an ordinary "not found" probe - such as checking whether a
# service principal already exists - into a fatal error. Every az call that
# must succeed is instead guarded explicitly on its output or $LASTEXITCODE,
# which is both accurate and idempotent-friendly.
$ErrorActionPreference = 'Continue'

if ([string]::IsNullOrWhiteSpace($StateResourceGroup)) {
    $StateResourceGroup = $ResourceGroup
}

if ($GitHubRepo -notmatch '^[^/]+/[^/]+$') {
    throw "GitHubRepo must be in 'owner/repo' form. Got: $GitHubRepo"
}

function Write-Step { param([string]$Message) Write-Host "`n==> $Message" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Message) Write-Host "    [ok] $Message" -ForegroundColor Green }
function Write-Skip { param([string]$Message) Write-Host "    [--] $Message" -ForegroundColor DarkGray }

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
Write-Step "Checking prerequisites"

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw "Azure CLI not found. Install it from https://aka.ms/installazurecli"
}

$accountJson = az account show --output json 2>$null
if ([string]::IsNullOrWhiteSpace($accountJson)) {
    throw "Not logged in. Run: az login"
}
$account = $accountJson | ConvertFrom-Json

$SubscriptionId = $account.id
$TenantId       = $account.tenantId
Write-Ok "Subscription: $($account.name) ($SubscriptionId)"
Write-Ok "Tenant:       $TenantId"

# The service principal is the security principal; the app registration is only
# its definition. Role assignments target the SP's object id, NOT the client id -
# mixing these up is the single most common failure in this setup.
$spObjectId = az ad sp show --id $AppClientId --query id --output tsv 2>$null
if ([string]::IsNullOrWhiteSpace($spObjectId)) {
    Write-Host "    No service principal for app $AppClientId yet; creating one..." -ForegroundColor Yellow
    az ad sp create --id $AppClientId --output none 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw "Could not create a service principal for app id '$AppClientId'. Check the app registration exists and that you may create service principals in this tenant."
    }

    # Entra ID is eventually consistent: the SP is not always readable on the
    # very next call, and an empty object id here would silently produce role
    # assignments against nothing.
    for ($i = 1; $i -le 6; $i++) {
        Start-Sleep -Seconds 5
        $spObjectId = az ad sp show --id $AppClientId --query id --output tsv 2>$null
        if (-not [string]::IsNullOrWhiteSpace($spObjectId)) { break }
        Write-Host "    waiting for the service principal to appear ($i/6)..." -ForegroundColor DarkYellow
    }
}
if ([string]::IsNullOrWhiteSpace($spObjectId)) {
    throw "Service principal for app '$AppClientId' never became readable."
}
Write-Ok "Service principal object id: $spObjectId"

$rgId = az group show --name $ResourceGroup --query id --output tsv 2>$null
if (-not $rgId) { throw "Resource group '$ResourceGroup' not found. Create it first." }
Write-Ok "Resource group: $rgId"

$saId = az storage account show --name $StateStorageAccount --resource-group $StateResourceGroup --query id --output tsv 2>$null
if (-not $saId) { throw "Storage account '$StateStorageAccount' not found in '$StateResourceGroup'." }
Write-Ok "State storage account: $StateStorageAccount"

# ---------------------------------------------------------------------------
# 1. Federated credentials
#
# The `subject` must match EXACTLY what GitHub puts in the OIDC token, and each
# distinct trigger shape needs its own credential. A workflow whose job declares
# `environment: dev` produces an environment subject, NOT a branch subject -
# which is why a deploy job can fail to authenticate even though the push to
# main worked fine.
# ---------------------------------------------------------------------------
Write-Step "Creating federated credentials"

# The trigger shapes that need a credential. Each becomes a subject suffix.
$credentialSuffixes = @(
    @{ slug = "main-branch";       suffix = "ref:refs/heads/main";      description = "Pushes to main (CI: build and push image)" },
    @{ slug = "pull-request";      suffix = "pull_request";             description = "Pull requests (terraform plan; no write access used)" },
    @{ slug = "env-dev";           suffix = "environment:dev";          description = "CD job targeting the dev environment" },
    @{ slug = "env-prod";          suffix = "environment:prod";         description = "CD job targeting the prod environment" },
    @{ slug = "env-infra-apply";   suffix = "environment:infra-apply";  description = "terraform apply (approval-gated environment)" },
    @{ slug = "env-infra-destroy"; suffix = "environment:infra-destroy"; description = "terraform destroy (approval-gated environment)" }
)

<#
GitHub issues OIDC subjects in one of two shapes:

  classic     repo:OWNER/REPO:environment:dev
  immutable   repo:OWNER@<ownerId>/REPO@<repoId>:environment:dev

The immutable form is a hardening feature - a renamed or recreated repository
cannot inherit the previous repository's trust - and it is enabled per
repository/organisation. There is no reliable way to know in advance which one
your workflows will present; you find out when a run fails with:

  AADSTS700213: No matching federated identity record found for presented
  assertion subject 'repo:owner@123/repo@456:environment:dev'

so credentials are created for BOTH shapes. They are cheap, and having the
unused one costs nothing.
#>
$subjectPrefixes = @("repo:${GitHubRepo}")

try {
    $meta = Invoke-RestMethod -Uri "https://api.github.com/repos/${GitHubRepo}" `
        -Headers @{ 'User-Agent' = 'azure-oidc-setup'; 'Accept' = 'application/vnd.github+json' } `
        -TimeoutSec 30
    $immutable = "repo:$($meta.owner.login)@$($meta.owner.id)/$($meta.name)@$($meta.id)"
    $subjectPrefixes += $immutable
    Write-Ok "Immutable-id subject prefix: $immutable"
}
catch {
    Write-Host "    [warn] Could not read repository ids from api.github.com." -ForegroundColor Yellow
    Write-Host "           Only classic subjects will be created. If a workflow later fails with" -ForegroundColor Yellow
    Write-Host "           AADSTS700213, re-run this script once the API is reachable." -ForegroundColor Yellow
}

$credentials = @()
foreach ($prefix in $subjectPrefixes) {
    # "gh-" for the classic shape, "ghid-" for the immutable-id shape.
    $shape = if ($prefix -match '@\d+') { "ghid" } else { "gh" }
    foreach ($c in $credentialSuffixes) {
        $credentials += @{
            name        = "$shape-$($c.slug)"
            subject     = "${prefix}:$($c.suffix)"
            description = $c.description
        }
    }
}

$existing = az ad app federated-credential list --id $AppClientId --output json | ConvertFrom-Json
$existingSubjects = @($existing | ForEach-Object { $_.subject })

foreach ($cred in $credentials) {
    if ($existingSubjects -contains $cred.subject) {
        Write-Skip "$($cred.name) - already present"
        continue
    }

    $body = @{
        name        = $cred.name
        issuer      = "https://token.actions.githubusercontent.com"
        subject     = $cred.subject
        description = $cred.description
        audiences   = @("api://AzureADTokenExchange")
    } | ConvertTo-Json -Compress

    $tmp = New-TemporaryFile
    try {
        # Passed via file: inline JSON on Windows gets mangled by quoting rules.
        Set-Content -Path $tmp -Value $body -Encoding utf8
        az ad app federated-credential create --id $AppClientId --parameters "@$tmp" --output none
        # The Azure CLI is a native executable: a failure sets $LASTEXITCODE but
        # does NOT raise a PowerShell error, so it must be checked explicitly or
        # every failure is silently reported as success.
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to create federated credential '$($cred.name)' (az exit code $LASTEXITCODE)."
        }
        Write-Ok "$($cred.name) -> $($cred.subject)"
    }
    finally {
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------------------
# 2. Role assignments
# ---------------------------------------------------------------------------
Write-Step "Assigning roles"

function Add-RoleAssignment {
    param([string]$Role, [string]$Scope, [string]$Why)

    $already = az role assignment list --assignee $spObjectId --scope $Scope `
                 --role $Role --query "[0].id" --output tsv 2>$null
    if ($already) {
        Write-Skip "$Role - already assigned"
        return
    }

    # Retry: a freshly created service principal takes a few seconds to become
    # visible to the RBAC service, and the first attempt often fails with
    # PrincipalNotFound.
    #
    # Note the explicit $LASTEXITCODE check rather than try/catch: `az` is a
    # native executable, so a non-zero exit does not raise a PowerShell error
    # and a try/catch here would never fire.
    for ($i = 1; $i -le 5; $i++) {
        $output = az role assignment create --assignee-object-id $spObjectId `
            --assignee-principal-type ServicePrincipal `
            --role $Role --scope $Scope --output none 2>&1

        if ($LASTEXITCODE -eq 0) {
            Write-Ok "$Role  ($Why)"
            return
        }

        if ($i -eq 5) {
            Write-Host "    $output" -ForegroundColor Red
            throw "Failed to assign '$Role' at scope $Scope after 5 attempts."
        }
        Write-Host "    retrying ($i/5) - Entra ID replication delay..." -ForegroundColor DarkYellow
        Start-Sleep -Seconds 10
    }
}

Add-RoleAssignment -Role "Contributor" -Scope $rgId `
    -Why "create and manage AKS, ACR, VNet, Log Analytics"

# Contributor explicitly EXCLUDES writing role assignments. Terraform creates
# four of them (AcrPull for kubelet, AcrPush + two AKS roles for CI), so
# without this the apply fails partway through with AuthorizationFailed.
Add-RoleAssignment -Role "Role Based Access Control Administrator" -Scope $rgId `
    -Why "Terraform creates role assignments; Contributor cannot"

# Data-plane access to the state blobs. Control-plane Contributor on the
# storage account is NOT sufficient when the backend uses use_azuread_auth.
Add-RoleAssignment -Role "Storage Blob Data Contributor" -Scope $saId `
    -Why "read/write the Terraform state blob with Entra ID auth"

# Needed by `az aks get-credentials`; the in-cluster permissions themselves are
# granted by Terraform in rbac.tf.
Add-RoleAssignment -Role "Azure Kubernetes Service Cluster User Role" -Scope $rgId `
    -Why "fetch the cluster kubeconfig"

# ---------------------------------------------------------------------------
# 3. Report
# ---------------------------------------------------------------------------
Write-Step "GitHub repository variables"

$variables = [ordered]@{
    AZURE_CLIENT_ID        = $AppClientId
    AZURE_TENANT_ID        = $TenantId
    AZURE_SUBSCRIPTION_ID  = $SubscriptionId
    AZURE_RESOURCE_GROUP   = $ResourceGroup
    TFSTATE_RESOURCE_GROUP = $StateResourceGroup
    TFSTATE_STORAGE_ACCOUNT = $StateStorageAccount
    TFSTATE_CONTAINER      = $StateContainer
}

Write-Host ""
Write-Host "  Settings -> Secrets and variables -> Actions -> Variables" -ForegroundColor Yellow
Write-Host ""
$variables.GetEnumerator() | ForEach-Object {
    Write-Host ("    {0,-24} {1}" -f $_.Key, $_.Value)
}
Write-Host ""
Write-Host "  Set after 'Infrastructure -> apply' completes (values are printed by that run):" -ForegroundColor Yellow
Write-Host "    ACR_NAME, ACR_LOGIN_SERVER, AKS_CLUSTER_NAME"
Write-Host ""
Write-Host "  Secret required for the quality gate:" -ForegroundColor Yellow
Write-Host "    SONAR_TOKEN              (from sonarcloud.io)"
Write-Host "  Plus variables SONAR_ORGANIZATION and SONAR_PROJECT_KEY."
Write-Host ""

if ($SetGitHubVariables) {
    Write-Step "Setting repository variables via gh CLI"
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        Write-Warning "gh CLI not found - set the variables manually using the list above."
    }
    else {
        foreach ($kv in $variables.GetEnumerator()) {
            gh variable set $kv.Key --body $kv.Value --repo $GitHubRepo
            Write-Ok "$($kv.Key) set"
        }
    }
}

Write-Step "Terraform still needs the SP object id"
Write-Host @"
    Add this to infra/terraform/environments/dev.tfvars so Terraform can grant
    the CI principal AcrPush and AKS RBAC Cluster Admin:

        cicd_principal_object_id = "$spObjectId"

    Note this is the service principal OBJECT id, not the client id.
"@ -ForegroundColor Yellow

Write-Host "`nDone.`n" -ForegroundColor Green
