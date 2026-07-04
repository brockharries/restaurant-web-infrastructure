# Runbook: "The site is down and it's 6:45 on a Friday"

A short, honest operational runbook. The value of running production infrastructure
for a real business is having thought through failure *before* it happens, on the
clock, with orders on the line. This is the sanitized version of how I did.

## Priorities, in order

1. **Restore the ability to take orders.** Not the perfect fix, the *fastest safe path* back to a working storefront and ordering flow.
2. **Preserve data.** Never let a hurried fix destroy the database or the last good backup.
3. **Then** root-cause it, once orders are flowing again.

## Triage: where is it broken?

| Symptom | Likely layer | First check |
|---|---|---|
| Whole site unreachable, edge shows error | Edge/CDN or origin down | Is the origin reachable from the edge? Is the origin box up at all? |
| Site loads, ordering fails | App or payment processor | App logs; processor status page |
| Site slow, timeouts under load | Origin overloaded / DB | Origin CPU/mem; DB slow queries; is edge caching static assets? |
| TLS/cert warning | Edge cert or origin cert | Edge cert status; origin cert expiry |
| Order confirmation emails not arriving | Email deliverability | SPF/DKIM/DMARC; sending reputation |

## Fast recovery paths

- **Origin process crashed:** `docker compose up -d` brings the stack back; the proxy and app restart with `restart: unless-stopped` already, so this is usually automatic. Confirm `/healthz` is green.
- **Origin box unrecoverable:** stand up the stack on a fresh box from version-controlled compose + config, restore the database from the latest off-box dump, restore assets from the latest snapshot. This is the path the **tested restore** exists to make fast. The timed test is your real RTO.
- **App is up but the database is corrupt:** stop writes, restore the DB from the last good dump to a *new* volume (never overwrite the live volume until the restore is verified), repoint the app, verify a test order.
- **Edge outage:** static/cached pages may still serve from the CDN. If the whole edge is down, the fallback is a direct-to-origin DNS change (kept documented), accepting temporarily reduced protection to keep orders flowing. Because the origin firewall normally restricts 443 to the edge provider's IP ranges, this failover also means temporarily opening 443 beyond those ranges, and re-tightening it once traffic is back behind the edge.

## The rules I don't break under pressure

- **Never** run a destructive command against the live database to "fix" it before the current state is backed up.
- **Never** overwrite the last known-good backup with a restore-in-progress.
- **Verify with a real test order** before declaring it fixed. A page that loads is not the same as a system that can take money.
- Write down what happened afterward. Every incident is a future runbook entry.

## What this taught me

Owning uptime for a business that makes its money in a few hours each evening is a
very concrete teacher. It's where I learned that the tested restore is the real
deliverable, that the fastest safe path beats the elegant fix, and that "it loads"
and "it works" are different claims. Those instincts transfer directly to helping a
customer reason about their own availability and recovery.
