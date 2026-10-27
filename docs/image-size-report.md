# Image size report

**These numbers are measured, on this machine, from these images.** They were
produced by `scripts/measure-image-size.sh`, which builds each service repo's
own `backend/Dockerfile` and this project's `docker/Dockerfile.api` from the
same source tree.

## Read the two numbers carefully

Every row below reports the size twice, because "image size" means two things:

- **on disk** — what the layer cache occupies, what `docker images` prints
- **compressed** — what `docker pull` transfers and what ECR bills for

They differ by roughly 4–5× on these images, and **which one
`docker image inspect --format '{{.Size}}'` returns depends on the storage
driver.** With the classic image store it is uncompressed; with the containerd
snapshotter — default from Docker 25, unconditional by 29 — it is compressed.

That bit an earlier version of this script. The same image reported 342 MB from
`docker images` and 71 MB from `inspect`, with no error from either. A number
that looks measured, is measured, and measures something other than its label
is exactly the failure this document was written to avoid — so the script now
reports both and says which store produced them.

Quote the compressed figure for pull time and registry cost, the uncompressed
one for disk. Say which you mean.

---

The optimisation in `docker/Dockerfile.api` — multi-stage build, `pip install
--user` into a throwaway builder stage, no `curl` in the runtime image,
dependency layer before source, a `.dockerignore` that excludes tests and VCS
metadata — is worth a specific number on a resume only if that number was
measured on your machine, against your images.

Estimating it and writing it down here would produce exactly the kind of
metric an interviewer can dismantle in one question. A placeholder metric is
worse than no metric.

## Fill it in

```bash
./scripts/measure-image-size.sh ../FinSight-360 finsight
./scripts/measure-image-size.sh ../StrategySphere-AI strategysphere
```

The script builds the service repo's **own** `backend/Dockerfile` (single
stage — the baseline) and this project's `docker/Dockerfile.api` (multi-stage)
from the same source tree, prints both, and appends a table below.

Every CI build also prints the sizes into the GitHub Actions job summary, so
the numbers stay current without anyone remembering to re-measure.

## What to expect, and how to talk about it

Be careful about the shape of the claim. These images install
`psycopg2-binary`, `pydantic` and `uvicorn[standard]` — all of which ship
prebuilt wheels, so there is no compiler toolchain in the baseline image to
throw away. The dramatic "1.2 GB → 180 MB" numbers come from images that
compiled something; this one does not.

What multi-stage actually removes here is `pip`, `setuptools`, `wheel` and
their metadata, plus the `curl` package and its TLS dependency chain. Real, and
smaller than a headline number.

**The measurement confirms it.** The API image drops 9.6% on disk and 11.3%
compressed — not 85%. The frontend does better (18.3% / 16.0%) because the
Node build stage genuinely is enormous and genuinely is discarded.

The stronger claim from this work is **build time**, not size: dependencies are
copied and installed before application source, so a source-only commit reuses
the cached dependency layer, and the GitHub Actions cache is scoped per service
per container with `mode=max` so intermediate stages are cached too.

The more defensible claim from this work is about **build time**, not size:
ordering the dependency layer before the source, plus the BuildKit GitHub
Actions cache, means a source-only commit reuses the dependency layer. Measure
that too — the pipeline's own run history gives it to you for free.

If the size reduction turns out to be modest, say so. "Multi-stage removed the
build toolchain and cut ~25%; the bigger win was build time, from N minutes to
M seconds on a source-only change" is a stronger answer than an impressive
number you cannot reproduce on the spot.

---

<!-- measure-image-size.sh appends below this line -->
## finsight — measured 2026-09-20

Docker image store: `containerd snapshotter`. Both numbers below are real and they
measure different things — see the note at the top of this file.

| image | | baseline | optimised | reduction |
|---|---|---|---|---|
| api | on disk | 342 MB | 309 MB | 9.6% |
| api | compressed | 71 MB | 63 MB | 11.3% |
| web | on disk | 93 MB | 76 MB | 18.3% |
| web | compressed | 25 MB | 21 MB | 16.0% |

Layer count (api): 20 -> 23

