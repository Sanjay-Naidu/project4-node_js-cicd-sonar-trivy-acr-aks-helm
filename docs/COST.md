# Cost

Sized for a 30-day Azure free trial (~$159 / ₹13,000 credit).

> Prices are `eastus` pay-as-you-go list, accurate to roughly ±15% and subject to change. Use them to compare options, not to forecast a bill. Check the live figure with the [Azure pricing calculator](https://azure.microsoft.com/pricing/calculator/) or `az costmanagement`.

---

## What the default `dev` profile costs

| Resource | Configuration | ~USD/month | ~USD/day |
|---|---|---:|---:|
| AKS control plane | Free tier | $0.00 | $0.00 |
| Nodes | 2 × `Standard_B2s` (2 vCPU / 4 GiB) | $60.00 | $2.00 |
| OS disks | 2 × 64 GB Standard SSD (E6) | $9.60 | $0.32 |
| Standard Load Balancer | 1 rule set | $18.25 | $0.61 |
| Public IPs | 2 × static standard (ingress + Service) | $7.30 | $0.24 |
| ACR | Basic, 10 GB included | $5.00 | $0.17 |
| Log Analytics | 0.2 GB/day cap @ $2.76/GB | $16.56 | $0.55 |
| Storage (state) | LRS, < 1 MB | $0.02 | $0.00 |
| Bandwidth | light demo traffic | ~$1.00 | $0.03 |
| **Total** | | **~$117** | **~$3.92** |

**≈ 30 days on a $159 credit**, with room to spare.

### Realistic usage is much lower

The table assumes the cluster runs 24×7 for a month. For a portfolio project you typically want it live for a few days of demos:

| Pattern | Cost |
|---|---|
| 3 days continuous | ~$12 |
| 7 days continuous | ~$27 |
| 30 days, stopped nightly (`az aks stop`) | ~$60 |
| 30 days continuous | ~$117 |

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
| `Standard_B2s` | `Standard_D2s_v5` | $30 |
| ACR **Basic** | Premium (private endpoints, geo-replication) | $45 |
| 2 nodes | 3 nodes | $30 |
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
