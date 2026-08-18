# Interview notes

Talking points for this project, and the questions the design invites.

The value of a portfolio project is not that it works — it is that you can explain *why* each decision was made and what the alternative would have cost. Everything below is grounded in something actually in this repository.

---

## The 90-second version

> "It's a Node.js REST API delivered to AKS through GitHub Actions. The build runs through Maven — `frontend-maven-plugin` drives the npm lifecycle — so lint, tests and coverage happen under one command. SonarQube gates on quality with `qualitygate.wait`, Trivy gates on vulnerabilities, and the image is scanned *before* it's pushed so a vulnerable artefact never reaches the registry. Infrastructure is Terraform with remote state in Azure Storage. Deployment is Helm with `maxUnavailable: 0` rolling updates, three probes and an application-level connection drain, so deploys are genuinely zero-downtime. The whole thing authenticates with GitHub OIDC federated credentials — there isn't a single stored secret anywhere in the repo or in Azure."

Then stop and let them pick a thread.

---

## The strongest threads to be asked about

### 1. Why three probes?

The point is that they answer different questions with different consequences.

The line that lands: **"A liveness probe that checks the database is how you turn a slow database into a total outage."** Every pod fails liveness at once, Kubernetes restarts all of them simultaneously, and the restart storm adds load to the database that was already struggling.

Then the startup probe: without it you have to set `initialDelaySeconds` on liveness to cover worst-case boot, and that delay applies for the pod's whole life — so a hang ten hours later goes undetected for that long. The startup probe lets you tolerate a slow boot *and* detect a hang quickly.

### 2. "Zero-downtime" — prove it

`maxUnavailable: 0` is necessary but not sufficient, and this is where most candidates stop.

The real issue is a race: when a pod is deleted, endpoint removal and `SIGTERM` happen **in parallel**, with no ordering guarantee. A process that exits promptly on `SIGTERM` stops listening while kube-proxy and NGINX are still routing to it. Result: a second or two of connection-refused per pod, every deploy.

The fix is in `app/src/index.js` — on `SIGTERM`, readiness flips to 503, the process keeps serving for an 8-second drain window, *then* closes the listener. `terminationGracePeriodSeconds: 45` exceeds that so the kubelet doesn't `SIGKILL` mid-drain.

There is a test for it (`tests/health.test.js` — "keeps serving business traffic while draining") and a script that proves it live (`scripts/zero-downtime-check.sh`).

### 3. No CPU limit — deliberate

This one often reads as an oversight, so state it first: **"The CPU limit is omitted on purpose."**

CPU limits are enforced by CFS quota — the kernel stops scheduling the container for the rest of each 100ms period once the quota is spent. On a single-threaded Node event loop that shows up as multi-hundred-millisecond p99 stalls at average utilisation well below the limit. The CPU *request* still guarantees a scheduling share.

Memory is the opposite: incompressible, can't be throttled, only killed. Without a limit a leak takes out other pods on the node. So memory is capped and CPU is not.

### 4. Why the image is scanned before the push

Scanning after push means the vulnerable image is already in the registry and already pullable. Here the build uses `load: true`, Trivy scans the local daemon image, and only then does it push. Same artefact, correct order.

Related: `ignore-unfixed` is set, because failing on a CVE with no available patch just trains people to bypass the gate.

### 5. Why some gates block and some don't

Blocking: image CVEs, committed secrets, Sonar quality gate, `npm audit`, tests, lint.
Advisory: Trivy IaC misconfiguration, filesystem scan.

The distinction is whether a finding is unambiguous. "HIGH CVE in the shipped image" always is. "ACR should have a private endpoint" is a documented trade-off here — Basic SKU doesn't support it. Blocking on that would train the team to ignore the scanner, which is strictly worse than not running it.

`.trivyignore` requires a reason and an expiry on every suppression.

### 6. OIDC, and the detail that proves you've done it

Anyone can say "we use OIDC instead of secrets." The detail that shows you actually built it:

**The federated credential subject must match exactly, and `environment:` changes the subject.** A job that declares `environment: dev` emits `repo:owner/repo:environment:dev`, *not* the branch subject. So the build job authenticates fine and the deploy job fails with `AADSTS70021`. This repo creates six credentials for that reason.

Second detail: **`Contributor` cannot create role assignments.** Terraform creates four of them, so the CI principal also needs `Role Based Access Control Administrator`. Without it the apply gets partway through and fails.

### 7. `local_account_disabled`

Disabling local accounts kills the static cluster-admin kubeconfig — `az aks get-credentials --admin` stops working entirely. Combined with `azure_rbac_enabled`, every `kubectl` call is an auditable Entra ID identity, and cluster access is granted and revoked in the same place as every other Azure permission.

The operational consequence, which is the part worth mentioning: you now need `kubelogin` in CI, and forgetting it produces a confusing `Unauthorized` after a *successful* `get-credentials`.

### 8. Why Maven for a Node app

Be honest: Maven doesn't build JavaScript. `frontend-maven-plugin` provisions a project-local Node toolchain and binds npm scripts to Maven phases.

It's a real pattern in organisations standardised on Maven — one build command, one artifact repository, one Sonar integration across a polyglot estate. The cost is a JVM and a Node download per build. If asked what you'd do greenfield with no such constraint: npm directly, with `sonar-scanner-cli`.

Showing you know it's a trade-off is better than pretending it's optimal.

---

## Questions you should expect

**"What happens if a deploy fails halfway?"**
`helm upgrade --atomic` rolls back automatically using `progressDeadlineSeconds`. The workflow then captures pod state, events and logs in a `failure()` step — because that evidence disappears when the failed pods are deleted.

**"How do you roll back a bad build that deployed successfully?"**
`helm rollback` — not `kubectl rollout undo`, which leaves Helm's recorded state stale so the next upgrade silently undoes the rollback.

**"How would you add a database?"**
`orderStore.js` is already written as a repository interface, so it's a single-file swap. The infrastructure side: Azure Database for PostgreSQL with a private endpoint into the cluster VNet, credentials in Key Vault surfaced through the CSI driver (already enabled on the cluster), accessed via workload identity — which is why `oidc_issuer_enabled` and `workload_identity_enabled` are on even though nothing uses them yet.

Then the honest part: readiness would check the connection pool, liveness still wouldn't.

**"Why is `latest` never used?"**
A mutable tag means two pods in one ReplicaSet can run different code, and rollback becomes meaningless. The chart enforces it at template time — `_helpers.tpl` calls `fail` if the tag is empty or `latest`.

**"How do you know the NetworkPolicy actually does anything?"**
Because `network_policy = "azure"` is set on the cluster. Without a policy engine, NetworkPolicy objects are silently ignored — the manifest implies protection that doesn't exist, which is worse than having none.

Then the honest limitation: the ingress rule is permissive on the app port, because Azure LB traffic and kubelet probes arrive from addresses no pod or namespace selector can express. The real value is the egress restriction — DNS and outbound 443 only, with `169.254.0.0/16` excluded to block the Instance Metadata Service, which is the standard container-escape-to-cloud-credentials path.

**"What would you change for real production?"**
Have a genuine list:
- Separate system and user node pools; `only_critical_addons_enabled` on the system pool
- Three availability zones (the trial subscription has no zonal capacity, so `availability_zones = []` here)
- Private cluster with API server IP restrictions (needs self-hosted runners)
- ACR Premium with a private endpoint and image retention
- Progressive delivery — Argo Rollouts or Flagger for canary with automatic metric-based abort
- `AcrPull`-scoped namespaces and `RBAC Writer` instead of `Cluster Admin` for CI
- Alerting on the metrics that already exist, with SLOs and error budgets
- `kube-audit` logs enabled (excluded here purely for the ingestion cap)

**"What's the weakest part?"**
Answer it straight — deflecting reads badly:
- Storage is in-memory, so it's not genuinely stateful. Deliberate: a database adds cost and moving parts without changing the delivery story.
- Single node pool, no zones — trial subscription capacity constraints.
- CI has cluster-admin rather than namespace-scoped RBAC. `docs/RUNBOOK.md` documents the tighter variant and why it needs the namespace pre-created.
- No progressive delivery. Rolling update with automatic rollback, but not canary with metric analysis.
- The API server is publicly reachable, because GitHub-hosted runners have no stable egress IP.

---

## What to show on screen

In this order:

1. **The Actions run graph** — the job DAG, with gates fanning out and converging on deploy.
2. **A failing gate** — deliberately introduce a HIGH CVE or drop coverage, and show the pipeline refusing to ship. A green pipeline proves it runs; a red one proves it *gates*.
3. **The Security tab** — Trivy and CodeQL findings as first-class GitHub data.
4. **`kubectl get pods -w` during a rollout** — new pod `0/1` while the startup probe runs, old pod still serving.
5. **`zero-downtime-check.sh`** — `0 failed` while pods are being replaced.
6. **The SonarCloud dashboard** — coverage and quality gate.
7. **The destroy workflow** — cost awareness is a senior signal, and most portfolio projects have no teardown story at all.

---

## Things not to claim

- Don't call it "production-ready". It's production-*shaped*: the mechanics are real, the capacity and durability are not.
- Don't say "fully automated" about infrastructure — `terraform apply` is deliberately manual behind an approval gate, and that's the right call.
- Don't overstate the NetworkPolicy. Explain the ingress limitation before someone finds it.
- If you didn't write something yourself, say so and explain what you understand about it. "I used the standard chart and here's what I changed and why" is a fine answer. Claiming authorship of code you can't explain is the one failure mode that ends an interview.
