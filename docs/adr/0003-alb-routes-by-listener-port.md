# 0003 — ALB routes by listener port, not path

- **Status:** Superseded in part by ADR 0011
- **Date:** 2026-08-22

## Context

Two services behind one ALB. The options are path prefixes
(`/finsight/*`), host headers (`finsight.example.com`), or separate
listener ports.

Both frontends are single-page apps served from the root of their origin, and
**an ALB can redirect but cannot rewrite a path prefix**. Path-based routing
would mean rebuilding each frontend with a Vite `base` and re-pointing every
asset URL — a change inside repositories this project does not own.

Host-based routing is the correct answer and needs a domain.

## Decision

`:80` serves the first service, `:8080` the second. One ALB, one listener
per service.

Extra listeners are free: ALB pricing is per-load-balancer-hour plus LCUs, so
two services behind one ALB cost the same as one.

## Consequences

**Good.** No change to either frontend. No second load balancer.

**Bad.** `:8080` in a URL looks like a staging environment. It is the most
visible oddity in the whole project and the first thing a reader asks about.

**Resolved conditionally.** ADR 0011 adds host-based routing on `:443`, gated
on a domain being configured. The port-based shape remains the default,
because the prerequisite is a domain and not everybody reading this has one.
