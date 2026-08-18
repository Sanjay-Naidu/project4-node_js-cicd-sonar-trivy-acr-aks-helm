## What changed

<!-- One or two sentences. What does this do that the previous code did not? -->

## Why

<!-- The problem being solved. Link an issue if there is one. -->

## How it was verified

- [ ] `make ci-local` passes
- [ ] New or updated tests cover the change
- [ ] Verified against a live cluster (`make status`, `make zero-downtime-check`)

## Deployment impact

<!-- Delete the rows that do not apply. -->

| Area | Changed? | Notes |
|---|---|---|
| Application code | no | |
| Helm chart / values | no | |
| Terraform | no | if yes, attach the plan |
| Workflows / permissions | no | |
| New dependencies | no | |

## Risk

<!--
Anything a reviewer should look at closely. In particular:
  * changes to probes, rollout strategy or terminationGracePeriodSeconds
  * changes to RBAC, NetworkPolicy or federated credentials
  * anything added to .trivyignore (must carry a reason and an expiry)
-->

## Rollback

<!-- Usually `helm rollback`. Say so if it is anything else. -->
