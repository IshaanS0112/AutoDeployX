// k6 load profile for an AutoDeployX-deployed service.
//
// This exists to replace a sentence. "Not load tested" was a listed weakness
// in docs/architecture.md; the honest version of that sentence is a number,
// and the number also turns the p95 latency alarm threshold from a guess into
// a measurement.
//
// Deliberately modest. This is one Fargate task with 512 CPU units behind one
// ALB, talking to a db.t3.micro. The goal is to find where it degrades, not to
// prove it scales — it does not, and that is a documented consequence of the
// architecture, not a bug to hide.
//
//   k6 run -e BASE_URL=http://<alb>:80 load/smoke.js
//   k6 run -e BASE_URL=... -e PROFILE=soak load/smoke.js

import http from "k6/http";
import { check, sleep } from "k6";
import { Rate, Trend } from "k6/metrics";

const BASE_URL = __ENV.BASE_URL;
if (!BASE_URL) {
  throw new Error("BASE_URL is required: k6 run -e BASE_URL=http://<alb>:<port> load/smoke.js");
}

const PROFILE = __ENV.PROFILE || "ramp";

const healthFailures = new Rate("health_failures");
const staticLatency = new Trend("static_asset_latency", true);

// Three profiles, three questions.
const profiles = {
  // "What does it do under a load it should handle?" ~2 minutes.
  ramp: {
    stages: [
      { duration: "30s", target: 5 },
      { duration: "60s", target: 20 },
      { duration: "30s", target: 0 },
    ],
  },
  // "Where does it fall over?" Push until something gives.
  stress: {
    stages: [
      { duration: "30s", target: 20 },
      { duration: "60s", target: 60 },
      { duration: "60s", target: 120 },
      { duration: "30s", target: 0 },
    ],
  },
  // "Does it degrade over time?" This is the one that finds a connection-pool
  // leak, which a two-minute ramp never will.
  soak: {
    stages: [
      { duration: "1m", target: 10 },
      { duration: "20m", target: 10 },
      { duration: "1m", target: 0 },
    ],
  },
};

export const options = {
  stages: profiles[PROFILE].stages,

  // Thresholds, not just measurements. A load test that reports numbers and
  // always exits 0 is a report; one that fails the run is a gate.
  thresholds: {
    // The SLO the CloudWatch burn-rate alarms are built on is 99%
    // availability. Under a load this stack is meant to handle, the error rate
    // should be nowhere near the budget.
    http_req_failed: ["rate<0.01"],
    // p95 under 2s is the same threshold as the CloudWatch latency alarm, so
    // a passing load test and a quiet alarm mean the same thing.
    http_req_duration: ["p(95)<2000"],
    health_failures: ["rate<0.01"],
    // Static assets are served by nginx off local disk. If these are slow,
    // the problem is not the database.
    static_asset_latency: ["p(95)<300"],
  },

  // The ALB idle timeout is 30s; nothing should be waiting longer than that.
  noConnectionReuse: false,
  userAgent: "autodeployx-k6/1.0",
};

export default function () {
  // The deep health check: nginx -> uvicorn -> Postgres. This is the request
  // that exercises the whole task, and the one whose failure takes the target
  // out of the load balancer.
  const health = http.get(`${BASE_URL}/api/health`, { tags: { name: "health" } });
  const healthOk = check(health, {
    "health is 200": (r) => r.status === 200,
    "health reports a database check": (r) => {
      try {
        return r.json("checks.database") === "ok";
      } catch {
        return false;
      }
    },
  });
  healthFailures.add(!healthOk);

  // The SPA shell. Served from disk, should be fast and should never touch
  // the API.
  const index = http.get(`${BASE_URL}/`, { tags: { name: "index" } });
  check(index, { "index is 200": (r) => r.status === 200 });
  staticLatency.add(index.timings.duration);

  // A deep link. Exercises the try_files fallback, which is the thing that
  // breaks silently and only shows up when a user refreshes on a sub-route.
  const deep = http.get(`${BASE_URL}/some/client/route`, { tags: { name: "spa-fallback" } });
  check(deep, { "deep link falls back to the shell": (r) => r.status === 200 });

  sleep(1);
}

export function handleSummary(data) {
  // Written to a file as well as stdout, so docs/load-test-report.md can be
  // built from a real run rather than from memory.
  return {
    stdout: textSummary(data),
    "load-results.json": JSON.stringify(data, null, 2),
  };
}

function textSummary(data) {
  const m = data.metrics;
  const get = (name, field) => {
    const v = m[name] && m[name].values;
    return v && v[field] !== undefined ? v[field] : NaN;
  };
  const ms = (n) => (Number.isNaN(n) ? "n/a" : `${n.toFixed(0)}ms`);
  const pct = (n) => (Number.isNaN(n) ? "n/a" : `${(n * 100).toFixed(2)}%`);

  return [
    "",
    `profile:        ${PROFILE}`,
    `target:         ${BASE_URL}`,
    `requests:       ${get("http_reqs", "count")}`,
    `rps:            ${get("http_reqs", "rate").toFixed(1)}`,
    `error rate:     ${pct(get("http_req_failed", "rate"))}`,
    `latency p50:    ${ms(get("http_req_duration", "med"))}`,
    `latency p95:    ${ms(get("http_req_duration", "p(95)"))}`,
    `latency p99:    ${ms(get("http_req_duration", "p(99)"))}`,
    `latency max:    ${ms(get("http_req_duration", "max"))}`,
    "",
  ].join("\n");
}
