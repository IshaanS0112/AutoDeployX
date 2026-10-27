# 0002 — nginx and uvicorn in one ECS task, not two services

- **Status:** Accepted
- **Date:** 2026-08-22

## Context

Each deployed service is a React SPA served by nginx plus a FastAPI backend
served by uvicorn. The conventional answer is two ECS services, two target
groups, and service discovery or an internal load balancer between them.

## Decision

Both containers run in the **same** ECS task definition. Under `awsvpc`
networking every container in a task shares one network namespace, so nginx
reaches the API on `127.0.0.1:8000`.

## Consequences

**Good.** The API port is never exposed — there is no security group rule for
8000 anywhere in this repository, because nothing outside the task can address
it. The browser only ever talks to nginx, so CORS is not in the request path
and neither frontend needs a build-time API URL. One target group, one Fargate
task, half the compute bill.

**Bad, and stated plainly:** web and api cannot scale independently. At
`desired_count = 1` that is not a real constraint. At real traffic it would
be, and the fix is a task-definition change rather than a rewrite — but it is
a cost, not a free lunch, and presenting this as a microservice architecture
would be dishonest.

**Also bad.** The local compose file has to reproduce the shared namespace with
`network_mode: "service:api"`, or the nginx config drifts between local and
production and local stops catching production bugs.
