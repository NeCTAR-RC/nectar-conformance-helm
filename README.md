# nectar-conformance-web Helm chart

Read-only conformance dashboard for Nectar. Deploy one release per tier (prod, test).
A CronJob evaluates every site over PuppetDB and writes reports to a shared
ReadWriteMany (RWX) volume, and a web Deployment serves them.

## Conformance check data

The check definitions and conformance changelog are **not** baked into the image. They live
in the [`nectar-conformance-checks`](https://review.rc.nectar.org.au) repository and are
git-synced into a shared `emptyDir` that both pods mount, so the conformance schedule can be
updated by pushing to that repo, with no image rebuild or chart bump.

- The CronJob runs a git-sync **init container** that clones the repo fresh on every run.
- The web Deployment runs the same init clone plus a git-sync **sidecar** that pulls
  periodically, so the dashboard's version and changes views stay current without a restart.
- Both pods read `<checks.mountPath>/current` through the `NECTAR_CONFORMANCE_CHECKS_DIR`
  environment variable, which the chart sets for them.

Configure it under `checks.git` in `values.yaml`: `repo` (required), `ref`, `period`,
`image`, and `secretName` (an SSH deploy key under the key `ssh`; leave empty for anonymous
HTTPS). When `networkPolicy.enabled` is true, set `networkPolicy.checksGit.cidrs` (and
`ports`, default 443) to the git host so the clone is allowed. Setting `checks.git.enabled`
to false drops all of this; you must then supply the checks another way, as the tool has no
packaged fallback and will not start without a checks directory.

## Sites evaluated

Set `sites` to the list of site ids this release should check. The chart nests the list
under the deployment's `tier` when it writes `config.yaml`, so you list each site once:

```yaml
tier: prod
sites:
  - adelaide
  - ardc
  - melbourne
```

The per-tier lists ship in `values-prod.yaml` and `values-test.yaml`. Leave `sites` empty
(`[]`) to evaluate every environment PuppetDB knows about instead of a fixed list. The
tool no longer carries the real site ids as a built-in default, so a real deployment must
either set this list or rely on PuppetDB discovery.

## Pod Security Standard

The chart's defaults satisfy the **Restricted** Pod Security Standard, so it deploys
into a namespace labelled `pod-security.kubernetes.io/enforce=restricted`. Both pods run
as non-root (uid/gid 10001) with `seccompProfile: RuntimeDefault`, all capabilities
dropped, `allowPrivilegeEscalation: false`, and a read-only root filesystem (a writable
`/tmp` `emptyDir` is mounted). The security contexts are overridable through
`podSecurityContext` and `securityContext` in `values.yaml`.

See https://kubernetes.io/docs/concepts/security/pod-security-standards/.

## Deployment

The chart is published to the registry and deployed one release per tier (prod, test).
Per-tier values (tier, PuppetDB endpoint, HTTPRoute, StorageClass) are supplied at install
time, not baked into the chart. The target namespace must be labelled with the Restricted
Pod Security Standard (see above).

`values.yaml` holds only the tier-neutral defaults (security contexts, resources, schedule).

For a local test render:

```bash
helm template t . \
  --set puppetdb.baseUrl=http://puppetdb.example.com:8080
```

After the first deploy, trigger the initial refresh instead of waiting for the schedule (the
install notes print the exact namespaced command).
