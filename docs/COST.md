# Cost

Sized to run on an Azure free-trial credit for a demo period, then be destroyed.

> Prices are `eastus` pay-as-you-go list, accurate to roughly ±15% and subject to change. Use them to compare options, not to forecast a bill. Node prices below were pulled from the [Azure Retail Prices API](https://prices.azure.com/api/retail/prices) rather than guessed.

---

## What the default `dev` profile costs

| Resource | Configuration | ~USD/month | ~USD/day |
|---|---|---:|---:|
| AKS control plane | Free tier | $0.00 | $0.00 |
| Nodes | 2 × `Standard_D2as_v7` (2 vCPU / 8 GiB) | $132.56 | $4.42 |
| OS disks | 2 × 64 GB Standard SSD (E6) | $9.60 | $0.32 |
| Standard Load Balancer | 1 rule set | $18.25 | $0.61 |
| Public IPs | 2 × static standard (ingress + Service) | $7.30 | $0.24 |
| ACR | Basic, 10 GB included | $5.00 | $0.17 |
| Log Analytics | 0.2 GB/day cap @ $2.76/GB | $16.56 | $0.55 |
| Storage (state) | LRS, < 1 MB | $0.02 | $0.00 |
| Bandwidth | light demo traffic | ~$1.00 | $0.03 |
| **Total** | | **~$190** | **~$6.34** |

### Why the nodes cost more than they "should"

The obvious choice is `Standard_B2s` at roughly $30/month — half the price. It does not work here, and the reason is worth knowing:

```
The VM size of Standard_B2s is not allowed in your subscription in location 'eastus'.
```

Burstable B-series is **not permitted** on this subscription. That is a *SKU permission* restriction, entirely separate from quota — and the two disagree in a way that is genuinely misleading:

```bash
# Reports a limit of 4. Implies B2s is usable. It is not.
az vm list-usage --location eastus --output table | grep "Standard BS"

# This is the check that actually matters:
az vm list-skus --location eastus --size Standard_D2as_v7 --query "[].restrictions"
```

Of the families this subscription does permit (D/E/F v7 and the confidential-compute v3/v5 series), `Standard_D2as_v7` is the cheapest that meets the AKS system-pool minimum of 2 vCPU / 4 GiB. At $66.28/month per node it roughly doubles the compute line — which is exactly why the stop and destroy levers below stop being optional.

### Realistic usage is much lower

The table assumes the cluster runs 24×7 for a month. For a portfolio project you typically want it live for a few days of demos:

| Pattern | Cost |
|---|---|
| 3 days continuous | ~$19 |
| 7 days continuous | ~$44 |
| 30 days, stopped nightly (`az aks stop`) | ~$95 |
| 30 days continuous | ~$190 |

---

## The two levers that matter

### 1. `az aks stop` — the big one

```bash
az aks stop  -g rg-ordersapi-dev -n aks-ordersapi-dev   # end of day
az aks start -g rg-ordersapi-dev -n aks-ordersapi-dev   # ~3-5 min to resume
```

Deallocates the node VMs — which are ~60% of the bill — while keeping the cluster config, disks and load balancers. Everything comes back as it was.

### 2. Destroy when finished

**Actions → Infrastructure destroy → type `DESTROY`**

Takes the bill to effectively zero. Redeploying from scratch takes about 15 minutes, so there is little reason to leave an idle cluster running.

---

## Where the cost decisions were made

| Decision | Alternative | Monthly saving |
|---|---|---|
| AKS **Free** tier | Standard (99.95% API SLA) | $73 |
| `Standard_D2as_v7` | `Standard_D2s_v7` (the permitted default) | $60 |
| ACR **Basic** | Premium (private endpoints, geo-replication) | $45 |
| 2 nodes | 3 nodes | $66 |
| Log Analytics capped at 0.2 GB/day | uncapped | unbounded |
| No Application Gateway / WAF | AGIC | $250+ |
| No Azure Firewall | egress filtering | $912 |
| No Key Vault Premium (HSM) | HSM-backed keys | $1,000+ |

`values-prod.yaml` and `environments/prod.tfvars` show what the production shape would be — roughly $400–500/month for the same architecture at real capacity.

---

## The ingestion cap is the important guard rail

```hcl
daily_quota_gb = 0.2
```

The most likely way to lose a trial credit is not the cluster — it is a crash-looping pod writing to stdout at high volume. Log Analytics bills ~$2.76/GB with no upper bound, and a tight restart loop can ingest tens of gigabytes overnight. The cap makes the worst case bounded: logs are dropped once it is hit, which is the right trade for a demo.

To disable ingestion entirely:

```hcl
enable_monitoring = false   # saves ~$17/month
```

---

## Watching the spend

```bash
# credit remaining (trial subscriptions)
az consumption budget list -o table

# month-to-date by resource
az consumption usage list --start-date 2026-08-01 --end-date 2026-08-31 \
  --query "[].{name:instanceName, cost:pretaxCost, currency:currency}" -o table

# what actually exists right now
az resource list -g rg-ordersapi-dev -o table
az resource list -g rg-ordersapi-dev-nodes -o table
```

Set a budget alert before you start — it costs nothing and is the difference between noticing on day 2 and noticing on day 25:

**Portal → Cost Management → Budgets → Add** — $50 monthly, alerts at 50% / 80% / 100%.

---

## Teardown checklist

Terraform destroys what it created. These are the things it deliberately does **not** touch:

- [ ] **Infrastructure destroy** workflow completed successfully
- [ ] `az resource list -g rg-ordersapi-dev -o table` → empty
- [ ] `az resource list -g rg-ordersapi-dev-nodes -o table` → group gone
- [ ] No orphaned public IPs: `az network public-ip list -o table`
- [ ] No orphaned disks: `az disk list -o table`
- [ ] Resource group deleted, if you want it gone: `az group delete -n rg-ordersapi-dev`
- [ ] State storage account deleted (created manually — Terraform will not remove it)
- [ ] App registration deleted: `az ad app delete --id <APP_CLIENT_ID>`

Orphaned public IPs and disks are the usual survivors, because they are created by Kubernetes rather than Terraform. The destroy workflow deletes LoadBalancer Services first to avoid exactly this, but it is worth confirming.

---

## After the trial expires

The cluster stops, the resources remain, and nothing is deleted immediately. To keep the repository useful as a portfolio piece without any Azure spend:

- The full pipeline **through image build, scan and push** works on any subscription — including a $0 one, if you point it at a free registry.
- Every CI gate (Maven, Sonar, Trivy, CodeQL, Helm lint, kubeconform, Terraform validate) runs on GitHub-hosted runners with **no cloud account at all**.
- Screenshot the working deployment, the Actions run graph, the Security tab and the SonarCloud dashboard before tearing down. Those are what an interviewer actually looks at.
