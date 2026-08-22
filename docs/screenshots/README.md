# Pipeline execution screenshots

All images are captures of real pipeline runs against this repository — no mockups.

## Jenkins

| # | File | What it shows |
| --- | --- | --- |
| 01 | [`jenkins-01-multibranch-overview.png`](jenkins-01-multibranch-overview.png) | The `flask-practice-ci-cd` multibranch pipeline with the `main` and `staging` branches discovered automatically from GitHub. |
| 02 | [`jenkins-02-main-branch-job.png`](jenkins-02-main-branch-job.png) | **Stage View for `main`** — Checkout, Build, Test, Deploy to Staging and Staging Smoke Test, green across builds #1–#3. |
| 03 | [`jenkins-03-pipeline-stages.png`](jenkins-03-pipeline-stages.png) | Build #3 detail: archived `junit.xml` and `pytest-report.html`, the commit under test, and the test summary. |
| 04 | [`jenkins-04-console-output.png`](jenkins-04-console-output.png) | Full console log for build #3, including the dependency install, pytest run and the gunicorn staging deployment. |
| 05 | [`jenkins-05-notification-emails.png`](jenkins-05-notification-emails.png) | Build notification emails captured by Mailpit — both **SUCCESS** and **FAILURE**, the latter with the console log attached. |
| 06 | [`jenkins-06-staging-app-live.png`](jenkins-06-staging-app-live.png) | The application actually serving on the staging port after the pipeline deployed it. |
| 07 | [`jenkins-07-test-results.png`](jenkins-07-test-results.png) | JUnit test report published to Jenkins: 4 passed, 0 failed. |
| 08 | [`jenkins-08-staging-branch-deploy-skipped.png`](jenkins-08-staging-branch-deploy-skipped.png) | The `staging` branch: build #1 failing, then #2/#3 green with the deploy stages correctly skipped by `when { branch 'main' }`. |

### About the failure in screenshot 08

Build #1 of the `staging` branch is a genuine failure, kept deliberately as evidence
that the pipeline fails loudly and notifies on failure. `main` and `staging` were
building concurrently against a single shared test database, and because
`test_app.py` seeds a record with a hardcoded `_id`, the two runs collided with a
`DuplicateKeyError`. The fix — a per-branch test database plus
`disableConcurrentBuilds()` — is visible in builds #2 and #3.

### A note on how these were captured

Jenkins normally requires a login, and the headless browser used for capture cannot
supply credentials. Anonymous **read-only** access was enabled temporarily on the
local container purely to take these screenshots, then reverted. The committed
`jenkins/casc.yaml` keeps `allowAnonymousRead: false`, which is why the captures show
a "Sign in" button in the corner.

## GitHub Actions

| # | File | What it shows |
| --- | --- | --- |
| 01 | [`gha-01-workflow-runs.png`](gha-01-workflow-runs.png) | All workflow runs green across `main`, `staging` and the `v1.0.0` tag. |
| 02 | [`gha-02-main-run.png`](gha-02-main-run.png) | Push to `main`: Install Dependencies → Run Tests → Build → Notify, with both deploy jobs correctly skipped. |
| 03 | [`gha-03-staging-deploy-run.png`](gha-03-staging-deploy-run.png) | Push to `staging`: the same chain plus **Deploy to Staging**, which boots the packaged app and smoke-tests it. |
| 04 | [`gha-04-production-release-run.png`](gha-04-production-release-run.png) | The `v1.0.0` tag: **Deploy to Production** runs, Deploy to Staging is skipped, and both build artifacts are published. |
