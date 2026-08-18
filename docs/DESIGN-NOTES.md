# Design notes

Why this project is built the way it is, what broke on the way, and where the
limits are. Every claim below is grounded in something actually in this
repository rather than in general advice.

---

## In short

A Node.js REST API delivered to AKS through GitHub Actions. The build runs
through Maven — `frontend-maven-plugin` drives the npm lifecycle — so lint,
tests and coverage all happen under one command. SonarCloud gates on quality
with `qualitygate.wait`, Trivy gates on vulnerabilities, and the image is
scanned *before* it is pushed so a vulnerable artefact never reaches the
registry. Infrastructure is Terraform with remote state in Azure Storage.
Deployment is Helm with `maxUnavailable: 0` rolling updates, three probes and
an application-level connection drain. Everything authenticates with GitHub
OIDC federated credentials — there is no stored secret in the repo or in Azure.

---

## Key design decisions

### Why three probes rather than two

They answer different questions and have different consequences.

A liveness probe that checks a database is how a slow database becomes a total
outage: every pod fails liveness at the same moment, Kubernetes restarts all of
them simultaneously, and the restart storm adds load to the database that was
already struggling. Here `/healthz/live` only asks whether the process is still
a working HTTP server — the one condition a restart can actually fix.

The startup probe exists so the other two can be tuned properly. Without it,
liveness needs an `initialDelaySeconds` covering worst-case boot, and that delay
then applies for the pod's entire life — so a hang ten hours later goes
undetected for just as long. Splitting them means a slow boot is tolerated and a
hang is still caught in about 30 seconds.

### Zero-downtime is more than `maxUnavailable: 0`

That setting is necessary but not sufficient, and the gap is where most
deployments quietly drop requests.

When a pod is deleted, two things happen **in parallel** with no ordering
guarantee: the endpoints controller removes it from the Service (which then has
to propagate to kube-proxy on every node and to the ingress controller's own
cache), and the kubelet sends `SIGTERM`. A process that exits promptly on
`SIGTERM` therefore stops listening while proxies are still routing to it.

The fix is in `app/src/index.js`: on `SIGTERM` readiness flips to 503, the
process keeps serving for an 8-second drain window, and only then closes the
listener. `terminationGracePeriodSeconds: 45` is set to comfortably exceed that,
so the kubelet never `SIGKILL`s mid-drain.

`scripts/zero-downtime-check.sh` hammers the endpoint through a rolling restart
and reports dropped requests. The expected result is zero.

### A memory limit but no CPU limit

CPU limits are enforced by CFS quota: once the container spends its slice of a
100ms period the kernel simply stops scheduling it. On a single-threaded Node
event loop that shows up as multi-hundred-millisecond stalls in p99 latency,
even at average utilisation well below the limit. The CPU *request* still
guarantees a scheduling share, which is what actually matters.

Memory is the opposite. It is incompressible — a process cannot be asked to use
less, only killed — so without a limit a leak grows until the node runs out and
the kernel starts evicting *other* pods. The limit turns a cluster-wide incident
into a single-pod restart.

### Scanning the image before pushing it

The image is built with `load: true`, scanned in the runner's local daemon, and
only then pushed. Scanning after the push means the vulnerable image is already
in the registry and already pullable by anything with credentials.

`ignore-unfixed` is set, because failing on a CVE with no available patch gives
people no action to take except bypassing the gate.

### Which gates block and which do not

Blocking: image vulnerabilities, committed secrets, the Sonar quality gate,
`npm audit`, tests and lint.

Advisory (reported to the Security tab): Trivy IaC misconfiguration and the
filesystem scan.

The distinction is whether a finding is unambiguous. A HIGH CVE in a shipped
image always is. "ACR should have a private endpoint" is a documented cost
trade-off here — Basic SKU does not support it — and blocking every push on that
would train everyone to ignore the scanner, which is worse than not running it.

`.trivyignore` requires a reason and an expiry date for every suppression. An
undated suppression is indistinguishable from switching the scanner off.

### OIDC, and the two details that actually bite

Saying "we use OIDC instead of stored secrets" is easy. The parts that take a
failed pipeline to learn:

**A job that declares `environment:` emits a different subject.** A push to main
produces `repo:owner/repo:ref:refs/heads/main`, but a job with
`environment: dev` produces `repo:owner/repo:environment:dev`. They need
separate federated credentials, which is why there are six here — and why a
build job can authenticate perfectly while the deploy job fails.

**GitHub can also issue immutable-id subjects.** Instead of `repo:owner/repo:…`
you get `repo:owner@68593879/repo@1338448763:…`, so a renamed repository cannot
inherit the old one's trust. There is no way to know in advance which form your
repository uses; you find out from `AADSTS700213`. `scripts/azure-oidc-setup.ps1`
now reads the ids from the GitHub API and creates credentials for both shapes.

One more, on the Azure side: **`Contributor` cannot create role assignments**,
and this stack creates four. The CI principal also needs
`Role Based Access Control Administrator`, scoped to the single resource group.

### Disabling local cluster accounts

`local_account_disabled = true` removes the static cluster-admin certificate
that `az aks get-credentials --admin` would otherwise hand out. Combined with
Azure RBAC, every `kubectl` call is an auditable Entra ID identity and cluster
access is granted and revoked in the same place as every other Azure permission.

The operational cost is real and worth stating: CI needs `kubelogin`, and a
human operator gets `Forbidden` until they are given an explicit role
assignment — which happened during this build and is the correct behaviour.

### Maven for a JavaScript application

Maven does not build JavaScript. `frontend-maven-plugin` provisions a
project-local Node/npm toolchain and binds npm scripts onto Maven phases, so
`mvn verify` genuinely runs `npm ci` → ESLint → Jest with coverage, and nothing
beyond a JDK is required on the build agent.

This is a real pattern in organisations standardised on Maven: one build
command, one artifact repository and one Sonar integration across a polyglot
estate. Greenfield with no such constraint, npm directly with
`sonar-scanner-cli` is the simpler answer.

---

## What broke while building this

### The Trivy gate blocked a real image

The image build failed on 24 HIGH and 2 CRITICAL findings. Alpine's OS packages
were clean — every finding was inside **npm's own bundled dependencies**
(`sigstore`, `glob`, `minimatch`, `cross-spawn`, `brace-expansion`), which ship
inside `node:*-alpine` and which the running container never touches.

The container entrypoint is `node`. A package manager in the runtime image is
dead weight, and it is dead weight carrying its own CVEs. Deleting npm, npx and
yarn from the runtime stage took the image to zero findings and removed the most
useful tool an attacker finds after a container escape. A guard in the Dockerfile
fails the build if a future base image reintroduces it.

### `Standard_B2s` is not allowed on this subscription

The first `terraform apply` failed with:

```
The VM size of Standard_B2s is not allowed in your subscription in location 'eastus'.
```

Burstable B-series is blocked at the subscription level. That is a **SKU
permission** restriction, entirely separate from quota — and the two disagree in
a way that is genuinely misleading, because `az vm list-usage` cheerfully
reports `Standard BS Family vCPUs: limit 4`.

Quota answers "how many may I use"; SKU permission answers "may I use this type
at all". Both have to pass. `Standard_D2as_v7` is the cheapest permitted family
meeting the AKS system-pool minimum, which roughly doubled the compute line and
made the stop/destroy levers matter far more.

### Two NSGs, and a silent blackhole

After a completely successful deploy — rollout confirmed, `helm test` passing,
endpoints populated, load balancer reporting healthy — every request from the
internet timed out. No error anywhere.

AKS creates its own NSG in the node resource group and attaches it to the node
NICs. When a LoadBalancer Service appears, the cloud controller programs
`Allow Internet -> port` rules onto **that** NSG. It knows nothing about a custom
NSG attached to the subnet, and traffic has to pass both. So the tidy-looking
`DenyAllInBound` on the subnet NSG was dropping all external traffic while the
cluster reported perfect health.

The lesson generalises: "healthy in-cluster" and "reachable from outside" are
different assertions. That is exactly why the pipeline runs `helm test` *and* a
separate external endpoint probe — and the external probe is what caught this.

---

## Common questions

**What happens if a deploy fails halfway?**
`helm upgrade --atomic` rolls back automatically using `progressDeadlineSeconds`.
The workflow then captures pod state, events and logs in a `failure()` step,
because that evidence disappears as soon as the failed pods are replaced.

**How do you roll back a bad build that deployed successfully?**
`helm rollback` — not `kubectl rollout undo`, which leaves Helm's recorded state
stale so the next upgrade silently reverts the rollback.

**How would you add a database?**
`orderStore.js` is written as a repository interface, so it is a single-file
swap. Infrastructure side: Azure Database for PostgreSQL with a private endpoint
into the cluster VNet, credentials in Key Vault via the CSI driver (already
enabled), accessed through workload identity — which is why `oidc_issuer_enabled`
and `workload_identity_enabled` are on even though nothing uses them yet.
Readiness would check the connection pool; liveness still would not.

**Why is `latest` never used?**
A mutable tag means two pods in one ReplicaSet can run different code, and
rollback stops meaning anything. The chart enforces it at template time —
`_helpers.tpl` calls `fail` if the tag is empty or `latest`.

**How do you know the NetworkPolicy does anything?**
Because `network_policy = "azure"` is set on the cluster. Without a policy
engine, NetworkPolicy objects are silently ignored, which is worse than having
none — the manifest implies protection that does not exist.

The honest limitation: the ingress rule is permissive on the app port, because
Azure LB traffic and kubelet probes arrive from addresses no pod or namespace
selector can express. The real value is the egress half — DNS and outbound 443
only, with `169.254.0.0/16` excluded to block the Instance Metadata Service,
which is the standard path from container escape to stolen cloud credentials.

---

## Known limitations

Stated plainly, because they are deliberate trade-offs rather than oversights:

- **Storage is in-memory**, so the service is not genuinely stateful. A database
  would add cost and moving parts without changing the delivery story.
- **Single node pool, no availability zones** — the trial subscription has a
  4 vCPU regional cap and no zonal capacity for the SKUs it permits.
- **CI holds cluster-admin** rather than namespace-scoped RBAC. `RUNBOOK.md`
  documents the narrower `RBAC Writer` variant and why it needs the namespace
  pre-created.
- **No progressive delivery.** Rolling updates with automatic rollback, but not
  canary analysis with metric-based abort.
- **The API server is publicly reachable**, because GitHub-hosted runners have no
  stable egress IP range to allow-list.
- **`kube-audit` logs are disabled** — they are by far the highest-volume
  category and would exhaust the Log Analytics daily cap on their own.
