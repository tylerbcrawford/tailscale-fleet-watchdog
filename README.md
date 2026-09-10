# Tailscale Fleet Watchdog

[![CI](https://github.com/tylerbcrawford/tailscale-fleet-watchdog/actions/workflows/ci.yml/badge.svg)](https://github.com/tylerbcrawford/tailscale-fleet-watchdog/actions/workflows/ci.yml)

**Catches the silent failure mode of a small tailnet: a node key that expires while the daemon keeps running.**

> **Built with Claude Code.** I set the requirements and the architecture, made the design decisions, and run it on every node of my tailnet. The agent wrote most of the code under my direction.

Two small Bash scripts, one shared alert state machine, a Discord webhook, and a test suite. Runs on Linux (cron) and macOS (launchd) with nothing more than `bash`, `jq`, and `curl`.

```
bin/tailscale-self-check.sh    daily, on every always-on node   →  "is MY daemon healthy, and is my key about to expire?"
bin/tailscale-fleet-audit.sh   weekly, on two+ nodes            →  "is every always-on node online, and is expiry disabled where it should be?"
```

## The incident that produced this

One morning `ssh` to the home server over Tailscale started timing out:

```
ssh: connect to host 100.x.y.z port 22: Connection timed out
```

Nothing had changed. `tailscaled` was running. The machine was up. From the rest of the fleet the node showed as `offline, last seen 2d ago`.

The cause was Tailscale's default **180-day node key expiry**. The key had lapsed. The daemon kept running, but Tailscale's coordination server no longer accepted the node, and the only warning had been an email sent weeks earlier that got missed. A laptop on the same tailnet had failed the same way, unnoticed, because "offline" is normal for a laptop.

Logging the node back in fixed it in thirty seconds. The real problem was that nothing on the machines themselves had noticed. This repo closes that gap.

## Doesn't Tailscale already do this?

Partly, and you should turn those features on first:

- **Disable key expiry** on machines that should never expire (**Machines → ⋯ → Disable key expiry**). This removes the root cause for servers.
- **Tailscale webhooks** (**Settings → Webhooks**) can post `nodeKeyExpiringInOneDay` and `nodeKeyExpired` events straight to Discord, Slack, Google Chat, or Mattermost.

What the watchdog adds on top:

| Gap | Why it matters |
|---|---|
| Warning 14 days out, not 1 day | One day is not enough if you are travelling or the message lands at 3 am. |
| Always-on node has gone **offline** | Tailscale has no webhook event for a node dropping off the network. The fleet audit checks `lastSeen` for the nodes you list. |
| Someone **re-enabled expiry** on a server | No event for this either. The audit flags it before the key ever gets close to expiring. |
| Checks run on the nodes themselves | The self-check does not depend on Tailscale's coordination server being reachable, and alerts are deduplicated so you get one message per problem, not one per day. |

If you only care about the expiry warning, a webhook plus disabled expiry is enough. The watchdog is for the "server quietly fell off the tailnet" case.

## What it watches

| Check | Where it runs | Alert key | Fires when |
|---|---|---|---|
| Daemon state | self-check | `<node>:backend-not-running` | `tailscale status --json` reports anything but `Running` (e.g. `NeedsLogin`) |
| CLI health | self-check | `<node>:cli-failed` | The CLI exits non-zero or returns malformed JSON |
| Own key expiring | self-check | `<node>:key-expiring-soon` | `Self.KeyExpiry` is within 14 days |
| Own key expired | self-check | `<node>:key-expired` | `Self.KeyExpiry` is in the past |
| Node offline | fleet-audit | `<node>:offline-6h`, `:offline-24h` | An always-on node's `lastSeen` is older than 6 h / 24 h |
| Expiry config drift | fleet-audit | `<node>:expiry-config-drifted` | An always-on node has `keyExpiryDisabled: false` (someone re-enabled expiry) |
| Fleet key expiring | fleet-audit | `<node>:fleet-key-expiring-soon` | Any always-on node's `expires` is within 14 days |
| API health | fleet-audit | `audit:api-failed` | OAuth token or `/devices` call fails, times out, or returns non-JSON |
| State corruption | both | `meta:state-reset` | The JSON state file was unreadable and has been reset |

Laptops and phones are left out of the fleet checks by leaving them off the `ALWAYS_ON_NODES` list. Their keys should keep expiring; that is the security feature working as intended.

## Design

### Alerts fire on transitions, not on schedule

Each condition has a key. The first time a condition is seen, one alert is posted and the key is recorded as open in a JSON state file. Later runs that see the same condition only update `last_fired_at`; nothing is posted. When the condition goes away, the key is marked cleared without a message, and the next time it happens it fires again. There is no daily nag and no "all green" heartbeat.

```json
{
  "schema_version": 1,
  "alerts": {
    "media-server:key-expiring-soon": {
      "first_fired_at": "2026-05-06T08:00:00Z",
      "last_fired_at":  "2026-05-09T08:00:00Z",
      "cleared": false,
      "cleared_at": null,
      "context": {}
    }
  }
}
```

### It has to survive the node it monitors

If the fleet audit only ran on the main server and *that* server's daemon was the broken one, the audit could not reach the Tailscale API, the webhook, or anything else. So:

- the **self-check** runs independently on every always-on node and needs no network beyond the webhook, and
- the **fleet-audit** runs on at least two nodes, offset by 30 minutes, so one dead node cannot silence the fleet view.

### Fleet view comes from the REST API, not from peers

`tailscale status` on one node only shows what *that* node knows about its peers. The fleet audit instead uses an OAuth client (`devices:read` scope) to get a short-lived access token and reads `GET /api/v2/tailnet/-/devices`. That is the coordination server's own view of every device: `lastSeen`, `expires`, and `keyExpiryDisabled`.

### Same script on Linux and macOS

- **bash 3.2** on macOS: no associative arrays, no `mapfile`.
- **No `flock` on macOS**: the lock is used when available and skipped otherwise. A daily job cannot overlap with itself.
- **GNU vs BSD `date`**: detected once at startup; ISO-8601 → epoch math uses the right flavour.
- **CLI location**: on macOS the binary lives inside `Tailscale.app`; set `TAILSCALE_BIN`.
- **Scheduling**: crontab on Linux, a `launchd` plist on macOS (`launchd/`).

## Install

```bash
git clone https://github.com/tylerbcrawford/tailscale-fleet-watchdog.git
cd tailscale-fleet-watchdog
cp config.env.example config.env        # set WEBHOOK_URL and ALWAYS_ON_NODES
bash tests/run.sh                        # 22 tests, needs only bash + jq
bin/tailscale-self-check.sh --dry-run    # prints what WOULD alert on this node
```

For the fleet audit, create an OAuth client at **Admin console → Settings → OAuth clients** with the `devices:read` scope and save it:

```bash
mkdir -p ~/.config/tailscale-fleet-watchdog
cp credentials.env.example ~/.config/tailscale-fleet-watchdog/credentials.env
chmod 600 ~/.config/tailscale-fleet-watchdog/credentials.env   # then fill in the ID and secret
bin/tailscale-fleet-audit.sh --dry-run
```

### Schedule

Linux (`crontab -e`), every always-on node:

```cron
0 8  * * *   /path/to/tailscale-fleet-watchdog/bin/tailscale-self-check.sh  >> ~/.local/share/tailscale-fleet-watchdog/cron.log 2>&1
30 8 * * 0   /path/to/tailscale-fleet-watchdog/bin/tailscale-fleet-audit.sh >> ~/.local/share/tailscale-fleet-watchdog/cron.log 2>&1
```

macOS:

```bash
sed "s|/Users/YOU|$HOME|g" launchd/com.example.tailscale-self-check.plist > ~/Library/LaunchAgents/com.example.tailscale-self-check.plist
launchctl load -w ~/Library/LaunchAgents/com.example.tailscale-self-check.plist
```

### And fix the root cause

For nodes that should never expire, disable key expiry in the admin console (see above). The watchdog's `expiry-config-drifted` check then tells you if that setting is ever flipped back.

## Testing

`tests/run.sh` runs 22 assertions in CI on both Ubuntu and macOS (bash 3.2, BSD `date`), plus shellcheck. The test fixtures use placeholder timestamps that are filled in at run time, so "expires in 7 days" is always 7 days from *now*. Both scripts accept `--status-from-file` / `--devices-from-file`, which turns on dry-run mode and skips the CLI and API entirely.

## Two bugs the tests did not catch

Both slipped past the test suite because the fixture path skips the real CLI and API code. Recorded here because they are the interesting part.

**1. A `while read` loop that never finished.** The device loop was originally `echo "$json" | jq -c '.devices[]' | while read -r dev; do … done`. A pipe runs the loop body in a *subshell*. The parent shell already held a `flock` on file descriptor 9 (from clearing `audit:api-failed`) and never released it. The subshell inherited that lock and then waited on it forever. The cron job hung until `timeout` killed it. Fix: process substitution (`done < <(…)`) keeps the loop in the main shell.

**2. Matching on the wrong name.** `ALWAYS_ON_NODES` was compared against each device's `.hostname`. That field is the OS hostname, which is `Media-SERVER` on one box, `M2 Mini` on another, and literally `localhost` on an iPhone. Two of three always-on nodes never matched, so the audit was watching one machine and reporting success. Fix: match the first part of `.name`, the MagicDNS name, which is always lowercase and always what you typed into the config.

## Requirements

`bash` ≥ 3.2, `jq`, `curl`, the `tailscale` CLI on self-check nodes. No Python, no Docker.

## License

MIT
