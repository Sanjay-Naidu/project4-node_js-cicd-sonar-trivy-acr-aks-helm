# Runbook

Operational procedures for the deployed service.

```bash
# Assumed by every command below
az aks get-credentials -g "$AZURE_RESOURCE_GROUP" -n "$AKS_CLUSTER_NAME" --overwrite-existing
kubelogin convert-kubeconfig -l azurecli
export NS=orders-api
```

---

## Health check

```bash
kubectl -n $NS get deploy,rs,pods,svc,ingress,hpa,pdb -o wide
kubectl -n $NS get events --sort-by=.lastTimestamp | tail -30
helm -n $NS history orders-api
```

Which build is actually running:

```bash
kubectl -n $NS get pods -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[0].image}{"\n"}{end}'
curl -s "http://$(kubectl -n $NS get svc orders-api -o jsonpath='{.status.loadBalancer.ingress[0].ip}')/healthz" | jq
```

---

## Deploying

### Normal path
Merge to `main`. CI runs the gates, pushes the image and calls the CD workflow.

### Deploy a specific build
**Actions → CD → Run workflow**, supply the image tag (git short SHA) and environment. Nothing is rebuilt — the artefact that was tested is the one that ships.

### From a workstation
```bash
helm upgrade --install orders-api deploy/helm/orders-api \
  --namespace $NS --create-namespace \
  --values deploy/helm/orders-api/values-dev.yaml \
  --set image.repository="${ACR_LOGIN_SERVER}/ordersapi/orders-api" \
  --set image.tag="<git-short-sha>" \
  --atomic --wait --timeout 10m
```

---

## Rolling back

`helm upgrade --atomic` already rolls back automatically when a rollout fails. Manual rollback is for when a deploy *succeeded* but the build is bad.

```bash
helm -n $NS history orders-api

# previous revision
helm -n $NS rollback orders-api

# a specific revision
helm -n $NS rollback orders-api 7

kubectl -n $NS rollout status deploy/orders-api --timeout=5m
```

Rolling back the *Kubernetes* object rather than the Helm release leaves Helm's recorded state stale, and the next `helm upgrade` will undo it. Prefer `helm rollback`. The emergency escape hatch, accepting that caveat:

```bash
kubectl -n $NS rollout undo deploy/orders-api
```

---

## Proving zero-downtime

```bash
./scripts/zero-downtime-check.sh
```

Hammers the endpoint while restarting the Deployment and reports dropped requests. Expected result: `0 failed`.

Manually, in two terminals:

```bash
# terminal 1
IP=$(kubectl -n $NS get svc orders-api -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
while true; do
  curl -s -o /dev/null -w "%{http_code}\n" --max-time 5 "http://$IP/healthz/ready"
  sleep 0.2
done

# terminal 2
kubectl -n $NS rollout restart deploy/orders-api
kubectl -n $NS rollout status deploy/orders-api
```

Terminal 1 should print an unbroken stream of `200`.

Watch the mechanism itself:

```bash
kubectl -n $NS get pods -w
```

New pod `Running` but `0/1` ready → startup probe in progress. Old pod stays ready until the new one passes. A terminating pod stays `Running` for the drain window while readiness reports 503.

---

## Debugging

### Pods not starting

```bash
kubectl -n $NS describe pod <pod>
kubectl -n $NS logs <pod> --previous   # logs from the crashed instance
```

| Symptom | Cause | Fix |
|---|---|---|
| `ImagePullBackOff` | kubelet lacks `AcrPull`, or the tag does not exist | `az role assignment list --scope <acr-id>`; `az acr repository show-tags -n <acr> --repository ordersapi/orders-api` |
| `CrashLoopBackOff` | config validation failed at boot | `kubectl logs --previous` — `config.js` prints exactly which variable is wrong |
| `Pending` | no schedulable node | `kubectl describe pod` → events; usually insufficient CPU, or hard anti-affinity on too few nodes |
| `CreateContainerConfigError` | ConfigMap missing or key mismatch | `kubectl -n $NS get cm orders-api -o yaml` |
| Running but never Ready | startup probe failing | `kubectl exec` and curl `/healthz/startup`; check `STARTUP_DELAY_MS` against `failureThreshold × periodSeconds` |

### Traffic not arriving

Work inward, one layer at a time:

```bash
# 1. Are there endpoints at all? Empty means readiness is failing.
kubectl -n $NS get endpoints orders-api

# 2. Does the pod answer directly?
kubectl -n $NS port-forward deploy/orders-api 8080:3000
curl localhost:8080/healthz

# 3. Does the Service route?
kubectl -n $NS run tmp --rm -it --image=curlimages/curl --restart=Never -- \
  curl -s http://orders-api/healthz

# 4. Does the ingress route?
kubectl -n ingress-nginx logs -l app.kubernetes.io/component=controller --tail=100

# 5. Is the LoadBalancer IP assigned?
kubectl -n $NS get svc orders-api -o wide
```

If step 3 fails but step 2 succeeds, suspect the NetworkPolicy:

```bash
kubectl -n $NS get networkpolicy orders-api -o yaml
kubectl -n $NS delete networkpolicy orders-api   # temporarily, to confirm
```

### High latency

```bash
kubectl -n $NS top pods
kubectl -n $NS get hpa orders-api -w
```

Node.js is single-threaded per pod: sustained CPU near the request means you need more replicas, not a bigger pod. If pods are being OOM-killed (`kubectl describe pod` → `Reason: OOMKilled`), raise `resources.limits.memory`.

---

## Scaling

```bash
# temporary manual override (the HPA will reclaim it)
kubectl -n $NS scale deploy/orders-api --replicas=6

# permanent
helm upgrade orders-api deploy/helm/orders-api -n $NS --reuse-values \
  --set autoscaling.minReplicas=5 --set autoscaling.maxReplicas=15
```

Cluster (node) autoscaling:

```bash
az aks nodepool update -g "$AZURE_RESOURCE_GROUP" --cluster-name "$AKS_CLUSTER_NAME" \
  --name system --update-cluster-autoscaler --min-count 2 --max-count 5
```

`Pending` pods with `Insufficient cpu` mean the *cluster* autoscaler is at its ceiling, not the HPA.

---

## Certificates and DNS

The default setup uses HTTP on the raw ingress IP so there is nothing to configure. To add TLS:

1. Point a DNS A record at the ingress IP, or use `nip.io` (`orders.<IP>.nip.io`).
2. Run **Platform bootstrap** with cert-manager enabled.
3. Create a ClusterIssuer:

```bash
kubectl apply -f - <<'EOF'
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: you@example.com
    privateKeySecretRef:
      name: letsencrypt-prod
    solvers:
      - http01:
          ingress:
            ingressClassName: nginx
EOF
```

4. Redeploy with the TLS values from `values-prod.yaml`.

Let's Encrypt will not issue for `nip.io` at any volume — it is rate-limited as a public suffix. Use a real domain for anything lasting.

---

## Tightening CI access

The `Azure Kubernetes Service RBAC Cluster Admin` role granted in `rbac.tf` is broader than a deployment needs. To scope it to one namespace instead:

```hcl
resource "azurerm_role_assignment" "cicd_aks_rbac_writer" {
  scope                = "${azurerm_kubernetes_cluster.main.id}/namespaces/orders-api"
  role_definition_name = "Azure Kubernetes Service RBAC Writer"
  principal_id         = var.cicd_principal_object_id
}
```

Caveat: RBAC Writer cannot create the namespace or manage cluster-scoped objects, so the namespace must be pre-created and the ingress controller installed separately (which the platform workflow already does).

---

## Restricting API server access

`authorized_ip_ranges` is empty by default because GitHub-hosted runners use a large, rotating IP range. To lock it down you need either a self-hosted runner with a static egress IP, or a scheduled job syncing GitHub's published ranges:

```bash
curl -s https://api.github.com/meta | jq -r '.actions[]' | grep -v ':'
```

That list contains thousands of CIDRs and changes often — treat it as a stopgap, not a control.

---

## Incident checklist

1. **Assess** — `kubectl get pods`, `helm history`, recent deploys.
2. **Mitigate first** — `helm rollback` if a deploy correlates. Diagnose afterwards.
3. **Collect** — logs (`--previous` for crashed containers), events, `describe`. These are lost when pods are replaced.
4. **Verify** — `./scripts/zero-downtime-check.sh`, confirm endpoint counts.
5. **Write it down** — if the cause was a gap in the pipeline, add a gate.

---

## Emergency teardown

Billing runs even when nothing is being used:

```bash
# stop compute, keep everything else (fastest cost stop)
az aks stop -g "$AZURE_RESOURCE_GROUP" -n "$AKS_CLUSTER_NAME"

# full teardown
# Actions → Infrastructure destroy → type DESTROY
```

`az aks stop` keeps the control plane, node config and disks, and restarts in a few minutes with `az aks start`. Use it overnight; use the destroy workflow when you are done.
