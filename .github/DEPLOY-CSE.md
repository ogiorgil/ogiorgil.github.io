# Deploying to UW CSE homes

`.github/scripts/deploy-cse.sh` rsyncs the built `_site/` to `/cse/web/homes/$CSE_USERNAME/`
over SSH. It must run from inside the UW/CSE network: locally, or on a self-hosted runner.

## Why GitHub-hosted runners fail

The CSE SSH server drops connections from GitHub-hosted runners before authentication
(`kex_exchange_identification: Connection reset by peer`). Keys and rsync flags can't fix
this. The workflow therefore builds on `ubuntu-latest` and deploys on a self-hosted runner.
Until one is online, the deploy job stays queued.

## Deploy manually

Run one line at a time from the UW network, replacing `your-cse-login`:

```bash
export CSE_USERNAME=your-cse-login
bundle install && bundle exec jekyll build
.github/scripts/deploy-cse.sh --check
.github/scripts/deploy-cse.sh --dry-run
.github/scripts/deploy-cse.sh
```

`--check` tests DNS, TCP, and SSH only. `--dry-run` previews changes. See `--help` for options.

## Repository settings

| Name | Kind | Purpose |
|---|---|---|
| `CSE_USERNAME` | variable | CSE login (required) |
| `CSE_SSH_PRIVATE_KEY` | secret | Passphrase-less deploy key authorized on CSE (required) |
| `CSE_SSH_KNOWN_HOSTS` | variable | Pinned host key (recommended) |
| `CSE_DEPLOY_RUNNER` | variable | JSON runner labels; default `["self-hosted","cse-deploy"]` |
| `CSE_HOST` | variable | SSH host override |

To pin the host key, verify the fingerprint, then save it:

```bash
ssh-keyscan -t ed25519 recycle.cs.washington.edu > /tmp/cse_known_hosts
ssh-keygen -lf /tmp/cse_known_hosts
gh variable set CSE_SSH_KNOWN_HOSTS < /tmp/cse_known_hosts
```

## Self-hosted runner

1. Use an always-on machine on the UW network. `deploy-cse.sh --check` must pass there.
2. Settings → Actions → Runners → New self-hosted runner. Install it as an unprivileged
   user and add the label `cse-deploy`. It needs `ssh`, `rsync`, and `bash`.
3. This repo is public, so require approval for fork pull request workflows
   (Settings → Actions → General).
4. Optional: move `CSE_SSH_PRIVATE_KEY` into the `cse-homes` environment, limited to `master`.

## Troubleshooting

- `Connection reset` / `Connection closed`: blocked network, or brief throttling. Retry
  in a minute, or move to the UW network.
- `Permission denied`: the key isn't in `~/.ssh/authorized_keys` on CSE.
- `Host key verification failed`: the host key changed. Verify it before re-pinning.
