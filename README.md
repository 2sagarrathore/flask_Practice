# Flask Practice — CI/CD with Jenkins and GitHub Actions

A Flask + MongoDB student-records CRUD application, wired up with two independent
CI/CD pipelines:

| Pipeline | Definition | What it does |
| --- | --- | --- |
| **Jenkins** | [`Jenkinsfile`](Jenkinsfile) | Build → Test → Deploy to staging, with email notifications |
| **GitHub Actions** | [`.github/workflows/ci-cd.yml`](.github/workflows/ci-cd.yml) | Install → Test → Build → Deploy to staging → Deploy to production |

---

## Table of contents

- [Application overview](#application-overview)
- [Running locally](#running-locally)
- [Part 1 — Jenkins pipeline](#part-1--jenkins-pipeline)
  - [Prerequisites](#prerequisites)
  - [One-command Jenkins setup](#one-command-jenkins-setup)
  - [Pipeline stages](#pipeline-stages)
  - [Build triggers](#build-triggers)
  - [Email notifications](#email-notifications)
  - [Manual Jenkins setup (alternative)](#manual-jenkins-setup-alternative)
- [Part 2 — GitHub Actions workflow](#part-2--github-actions-workflow)
  - [Trigger matrix](#trigger-matrix)
  - [Jobs](#jobs)
  - [Configuring secrets](#configuring-secrets)
  - [Environments](#environments)
- [Changes made to the upstream project](#changes-made-to-the-upstream-project)
- [Troubleshooting](#troubleshooting)

---

## Application overview

| Route | Method | Purpose |
| --- | --- | --- |
| `/` | GET | List all students |
| `/add` | GET, POST | Add a student |
| `/update/<id>` | GET, POST | Update a student |
| `/delete/<id>` | GET | Delete a student |

Configuration comes from environment variables (see [`.env.example`](.env.example)):

| Variable | Required | Description |
| --- | --- | --- |
| `MONGO_URI` | yes | MongoDB connection string. Defaults to `mongodb://localhost:27017/studentDB`. |
| `SECRET_KEY` | yes | Flask session signing key. |
| `PORT` | no | Port for `start_flask.sh`. Defaults to `5000`. |

> **Note on TLS:** `app.py` only passes certifi's CA bundle when the URI actually
> negotiates TLS (`mongodb+srv://`, or `tls=true` / `ssl=true`). Supplying it to a
> plain `mongodb://` URI makes the driver attempt a TLS handshake that a local or CI
> MongoDB rejects. This is why the original code could not be tested in CI.

### Test suite

`test_app.py` contains four pytest cases covering the home page, add, update and
delete flows. They require a **live MongoDB**, and because `app.py` binds Mongo at
import time, `MONGO_URI` must be exported *before* pytest starts.

---

## Running locally

```bash
docker run -d --name mongo -p 27017:27017 mongo:7
```

```bash
cp .env.example .env
```

```bash
python3 -m venv .venv && ./.venv/bin/pip install -r requirements.txt
```

```bash
MONGO_URI="mongodb://localhost:27017/test_student_db" SECRET_KEY="dev" ./.venv/bin/python -m pytest -v
```

To run the app itself:

```bash
./start_flask.sh
```

---

## Part 1 — Jenkins pipeline

### Prerequisites

- Docker and Docker Compose (the supplied stack builds everything else)
- Ports `8080`, `8081`, `8025`, `1025`, `27017` free on the host

If you prefer a VM or an existing Jenkins controller, see
[Manual Jenkins setup](#manual-jenkins-setup-alternative) — the `Jenkinsfile` is
identical either way.

### One-command Jenkins setup

The [`jenkins/`](jenkins) directory contains a fully reproducible,
configuration-as-code Jenkins environment:

| File | Purpose |
| --- | --- |
| [`jenkins/Dockerfile`](jenkins/Dockerfile) | Jenkins LTS + Python 3, venv, curl, git |
| [`jenkins/plugins.txt`](jenkins/plugins.txt) | Pipeline, Git, GitHub, Email Extension, JUnit, JCasC, Job DSL |
| [`jenkins/casc.yaml`](jenkins/casc.yaml) | Admin user, credentials, SMTP, and the pipeline job itself |
| [`jenkins/docker-compose.yml`](jenkins/docker-compose.yml) | Jenkins + MongoDB + Mailpit |

Start it:

```bash
cd jenkins && FLASK_SECRET_KEY="$(openssl rand -hex 32)" docker compose up -d --build
```

| Service | URL | Credentials |
| --- | --- | --- |
| Jenkins | http://localhost:8080 | `admin` / `admin` (override with `JENKINS_ADMIN_PASSWORD`) |
| Staging app (deployed by the pipeline) | http://localhost:8081 | — |
| Mailpit (build notification emails) | http://localhost:8025 | — |

The `flask-practice-ci-cd` multibranch pipeline job is created automatically by
Job DSL — no manual job configuration is needed. Trigger a scan from the job page,
or wait for the 2-minute periodic scan.

### Pipeline stages

Defined in [`Jenkinsfile`](Jenkinsfile):

| Stage | What happens |
| --- | --- |
| **Checkout** | Clones the branch being built and logs the commit under test. |
| **Build** | Creates a virtualenv, upgrades pip, installs `requirements.txt`, runs `pip check`. |
| **Test** | Runs pytest against the `mongo` service, emitting JUnit XML and an HTML report. Results are published to Jenkins and archived as build artifacts. |
| **Deploy to Staging** | *Only on `main`, and only if tests passed.* Stops the previous instance, publishes the code to a release directory, installs dependencies into a dedicated venv, and starts gunicorn (2 workers) as a daemon. |
| **Staging Smoke Test** | Polls the staged app for up to 30s and fails the build unless it returns HTTP 200. Dumps the gunicorn error log on failure. |

The `Deploy to Staging` stage is gated by `when { branch 'main' }`, and Declarative
Pipeline stops at the first failing stage — so a failing test can never reach
deployment. Only `main` deploys, because the staging host and port are a single
shared resource that two branches cannot own at once.

Databases are kept isolated per environment **and per branch**:

| Environment | Database |
| --- | --- |
| Test | `mongodb://mongo:27017/test_student_db_<branch>` |
| Staging | `mongodb://mongo:27017/staging_student_db` |

The per-branch suffix matters: multibranch jobs build in parallel on separate
executors, and `test_app.py` seeds a record with a hardcoded `_id`. Pointing every
branch at one test database makes concurrent builds fail with a `DuplicateKeyError`.
`disableConcurrentBuilds()` covers the same race between two builds of one branch.

The Flask `SECRET_KEY` is **not** committed — it is injected from the Jenkins
credential `flask-secret-key` via `credentials('flask-secret-key')`.

### Build triggers

The `Jenkinsfile` declares both:

```groovy
triggers {
    githubPush()             // webhook-driven, for a publicly reachable Jenkins
    pollSCM('H/2 * * * *')   // fallback polling, every 2 minutes
}
```

plus a 2-minute branch-indexing scan configured in `casc.yaml`. As a result a push
to `main` starts a build automatically.

**For webhook-driven builds** (instant, no polling), Jenkins must be reachable from
GitHub. On a cloud VM, add a webhook at
`Settings → Webhooks → Add webhook` on the repository:

- **Payload URL:** `http://<your-jenkins-host>:8080/github-webhook/`
- **Content type:** `application/json`
- **Events:** *Just the push event*

For a local Jenkins, expose it first (for example with `ngrok http 8080`) and use
the public URL. Polling covers the local case without any of this.

### Email notifications

The `post` block sends HTML email on **both** success and failure, with the console
log attached on failure:

```groovy
post {
    success { emailext(subject: "SUCCESS: ...", ...) }
    failure { emailext(subject: "FAILURE: ...", attachLog: true, ...) }
}
```

The bundled stack ships **Mailpit** as a local SMTP sink so notifications can be
demonstrated end-to-end without handing real mailbox credentials to Jenkins. Open
http://localhost:8025 to read the delivered messages.

To send through a real provider instead, change the SMTP settings in
`jenkins/casc.yaml` (or *Manage Jenkins → System → Extended E-mail Notification*):

| Setting | Gmail example |
| --- | --- |
| SMTP server | `smtp.gmail.com` |
| SMTP port | `465` |
| Use SSL | yes |
| Credentials | your address + a **Google App Password**, stored as a Jenkins credential |

Change `EMAIL_RECIPIENTS` in the `Jenkinsfile` to the address that should receive alerts.

### Manual Jenkins setup (alternative)

If you are configuring an existing Jenkins controller by hand:

1. Install a JDK 17 Jenkins LTS, plus **Python 3**, `python3-venv` and `curl` on the
   controller or agent.
2. Install the plugins listed in [`jenkins/plugins.txt`](jenkins/plugins.txt).
3. Add a **Secret text** credential with ID `flask-secret-key`.
4. Provide a MongoDB reachable at `mongo:27017`, or edit `TEST_MONGO_URI` /
   `STAGING_MONGO_URI` in the `Jenkinsfile`.
5. Create a **Multibranch Pipeline** job pointing at this repository. Jenkins
   discovers the `Jenkinsfile` automatically.
6. Configure SMTP under *Manage Jenkins → System → Extended E-mail Notification*.

---

## Part 2 — GitHub Actions workflow

Defined in [`.github/workflows/ci-cd.yml`](.github/workflows/ci-cd.yml).

### Trigger matrix

| Event | Jobs that run |
| --- | --- |
| Push to `main` | install → test → build → notify |
| Push to `staging` | install → test → build → **deploy-staging** → notify |
| Push of a `v*` tag | install → test → build → **deploy-production** → notify |
| Published release | install → test → build → **deploy-production** → notify |
| Pull request into `main` | install → test → build → notify |
| Manual dispatch | install → test → build → notify |

### Jobs

| Job | Depends on | Description |
| --- | --- | --- |
| **Install Dependencies** | — | Sets up Python 3.12 with a pip cache keyed on `requirements.txt`, installs everything, and runs `pip check` to catch conflicts early. |
| **Run Tests** | install | Starts a `mongo:7` **service container** with a health check, exports `MONGO_URI`, runs pytest with JUnit XML output, and uploads the results as an artifact. |
| **Build** | test | Byte-compiles the sources and packages `app.py`, `templates/` and `requirements.txt` into a commit-stamped tarball, uploaded as the `app-package` artifact. |
| **Deploy to Staging** | build | Runs only on pushes to `staging`. Downloads the built artifact, unpacks it, boots it under gunicorn against a MongoDB service, smoke-tests `/` for HTTP 200, then optionally publishes to a real host over SSH. Writes a deployment summary. |
| **Deploy to Production** | build | Same flow, gated on a `v*` tag or a published release, using the production secrets and environment. |
| **Notify** | test, build | Always runs; reports job outcomes and sends an email if SMTP secrets are configured. |

Because `deploy-*` jobs declare `needs: build`, and `build` declares `needs: test`,
**a failing test blocks every deployment**.

Each deploy job runs the packaged artifact for real and fails the workflow if the
app does not answer HTTP 200. The SSH publish step is skipped with a clear message
when its secrets are absent, so the pipeline is green out of the box and becomes a
real deployment the moment you add infrastructure secrets.

### Configuring secrets

Add these under **Settings → Secrets and variables → Actions → New repository secret**.
All of them are optional — the workflow degrades gracefully and reports what it skipped.

| Secret | Used by | Purpose |
| --- | --- | --- |
| `SECRET_KEY` | both deploy jobs | Flask session signing key. |
| `STAGING_MONGO_URI` | deploy-staging | Staging database connection string. |
| `PROD_MONGO_URI` | deploy-production | Production database connection string. |
| `STAGING_SSH_HOST` / `STAGING_SSH_USER` / `STAGING_SSH_KEY` | deploy-staging | Target host, login, and private key for the staging release. |
| `PROD_SSH_HOST` / `PROD_SSH_USER` / `PROD_SSH_KEY` | deploy-production | Same, for production. |
| `SMTP_SERVER` / `SMTP_USERNAME` / `SMTP_PASSWORD` / `NOTIFY_EMAIL` | notify | Email notifications on pipeline outcome. |

Using the GitHub CLI:

```bash
gh secret set SECRET_KEY --body "$(openssl rand -hex 32)"
```

```bash
gh secret set STAGING_SSH_KEY < ~/.ssh/staging_deploy_key
```

Secrets are masked in logs and are never exposed to workflows triggered by forked
pull requests.

### Environments

The deploy jobs declare `environment: staging` and `environment: production`. Creating
those environments under **Settings → Environments** lets you attach **required
reviewers** so production deployments wait for manual approval, and scope
environment-specific secrets that override repository-level ones.

---

## Changes made to the upstream project

This fork adds CI/CD on top of `mohanDevOps-arch/flask_Practice`. Beyond the pipeline
files, the following changes were necessary:

| Change | Reason |
| --- | --- |
| `app.py` — conditional `tlsCAFile` | The original passed certifi's CA bundle unconditionally, forcing a TLS handshake that any non-Atlas MongoDB rejects. The full test suite failed with `SSL handshake failed` before this fix, so no pipeline could have gone green. |
| `app.py` — default `MONGO_URI` | Previously `None` when unset, which crashed at import. |
| `start_flask.sh` — rewritten | **The upstream version hardcoded a live MongoDB Atlas username and password.** Credentials now come from `.env`; `.env.example` documents the required variables. Anyone who previously used that connection string should rotate it. |
| `requirements.txt` — added `gunicorn` | The pipelines deploy under a production WSGI server rather than the Flask development server. |
| Removed `.github/workflows/securegate*.yml` | Upstream's third-party scanning workflows require `SECUREGATE_*` secrets that do not exist in this fork, so every push would have failed. |

---

## Troubleshooting

| Symptom | Cause and fix |
| --- | --- |
| `ServerSelectionTimeoutError: SSL handshake failed` | A `mongodb://` URI reaching the unconditional certifi path. Ensure you are on this fork's `app.py`. |
| `pytest` errors with `ServerSelectionTimeoutError` and no TLS message | MongoDB is not running, or `MONGO_URI` was not exported **before** pytest started. |
| Jenkins `Deploy to Staging` is skipped | Expected on any branch other than `main` or `staging`. |
| Jenkins build never starts after a push | Local Jenkins cannot receive GitHub webhooks. Polling picks it up within ~2 minutes, or expose Jenkins publicly and add the webhook. |
| Staging smoke test fails | Check `docker compose logs mongo`, then the gunicorn error log the stage prints on failure. |
| Port 8080 already in use | Change the host-side port mapping in `jenkins/docker-compose.yml`. |
