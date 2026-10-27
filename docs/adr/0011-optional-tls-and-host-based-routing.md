# 0011 — TLS and host-based routing, gated on a domain

- **Status:** Accepted
- **Date:** 2026-09-20

## Context

ADR 0003 settled on port-based routing because path rewriting is not something
an ALB does and host-based routing needs a domain. 'No TLS' and ':8080' are
the two most visible weaknesses in the project, and both have the same single
prerequisite: a domain name.

The temptation is to either leave it unbuilt and keep explaining it, or build
it and require a domain from everyone who reads the repository.

## Decision

Build it, gated. Setting `domain_name` and `route53_zone_id` switches the
ALB module to an ACM certificate with DNS validation, an HTTPS listener on
`:443` with host-header rules per service, `:80` as a permanent redirect,
and ALIAS records per service. Leaving them empty produces exactly the previous
behaviour.

## Consequences

**Good.** The weakness becomes a configuration value. The `:8080` oddity
disappears with the per-port listeners, because host-based routing makes them
redundant. Certificate renewal is ACM's problem, and
`create_before_destroy` on the certificate makes a rotation a non-event.

**Bad.** Two code paths through the ALB module, and only one of them is
exercised by default — so the TLS path is validated and policy-checked but not
smoke-tested here. The `:443` listener's default action is a 404 rather than
a forward, on the grounds that an unmatched Host header is a request for a
service this load balancer does not run, and silently handing it to whichever
service sorts first would make a typo look like a working deployment.
