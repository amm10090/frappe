# Frappe overlay deployment

This deployment path publishes a **minimal, immutable derived image** over the
current production image. It is intended for code-only Frappe changes and does
not run migrations or modify business data.

## What it optimizes

- **No full source copy:** `prepare-patch.sh` copies only added or modified
  paths below `frappe/` into the Docker context. Deletions, renames, and copies
  fail closed and require a full release process.
- **No build for Desk doctype JS:** Frappe loads doctype JavaScript through
  Desk metadata. Changes such as `frappe/**/doctype/**/*.js` use
  `BUILD_ASSETS=0`; the image only adds the source overlay.
- **Cached bundle builds:** when a changed path needs a bundle
  (`frappe/public/**` or `esbuild/**`), `BUILD_ASSETS=1` runs
  `bench build --app frappe`. BuildKit's persistent local cache at
  `/home/ubuntu/gitops/.build-cache/frappe` is reused across releases.
- **Persistent staging:** the deployment host must keep the staging Compose
  project and its `erp.amoze.net` site running. Releases assert that it exists;
  they never create or initialize a site.
- **Small smoke suite:** after staging and production promotion, the script
  verifies Compose configuration, starts services with `--wait`, clears Frappe
  metadata cache, calls `/api/method/ping`, and checks that `/desk` responds.
- **Automatic rollback:** a failed staging smoke test restores staging only;
  a failed production smoke test restores the copied production Compose file
  and starts the original image again. Each release stores both Compose backups
  and old/new image IDs in `deployment-record.txt`.

## GitHub Actions setup

The manual workflow is [`.github/workflows/erpnext-production-deploy.yml`](../../.github/workflows/erpnext-production-deploy.yml).
Protect the repository's `production` GitHub Environment with a required
reviewer before enabling it. Configure these Environment secrets:

| Secret | Purpose |
| --- | --- |
| `DEPLOY_HOST` | Deployment server hostname or IP. |
| `DEPLOY_USER` | Restricted SSH deployment user. |
| `DEPLOY_SSH_PORT` | SSH port; leave empty for `22`. |
| `DEPLOY_SSH_PRIVATE_KEY` | Dedicated deploy key, not a personal key. |
| `DEPLOY_KNOWN_HOSTS` | Pinned `known_hosts` entry for the server. Do not use `ssh-keyscan` in CI. |

The user must be restricted to the GitOps commands required by this workflow;
it needs Docker Compose access but no interactive password prompt. The workflow
uploads a release overlay to `/home/ubuntu/gitops/releases/<tag>/` and invokes
`deploy.sh` there.

When dispatching the workflow:

1. Set `base_ref` to the Frappe commit represented by the **current production
   image**. It must be an ancestor of the commit being deployed.
2. Optionally set an immutable `release_tag`; otherwise the workflow derives
   one from the commit and workflow run.
3. Review the GitHub Environment approval and watch the staging/promotion logs.

## Current platform limitation

The current production Compose project runs one replica per service. Compose
therefore performs a guarded **recreate**, not a zero-downtime rolling update.
The staging gate, `--wait`, smoke checks, and automatic Compose rollback reduce
risk but do not make it a rolling deployment. True rolling updates require
multiple replicas behind a load balancer or an orchestrator such as Swarm or
Kubernetes.

Similarly, Desk doctype JS can skip `bench build`, but it still lives inside the
application image and must be promoted by recreating the affected services.
Independent static-asset deployment requires an asset registry/CDN plus an
asset-only frontend image, which is not present in the current architecture.
