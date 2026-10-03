# Aloud cloud tools API

A Hono API deployed as a Cloudflare Worker. It accepts natural-language tasks and runs Codex on your Matrix cloud computer with **YOLO mode**, automatic MCP approvals, browser access, shell access and persistent files. The iPhone routes web research through Browser Use and retains Matrix for requested computer tasks. Both providers share this authenticated Worker; see the root README for voice usage.

```mermaid
sequenceDiagram
  participant Client
  participant Worker as Cloudflare / Hono
  participant Matrix as Matrix HTTP gateway
  participant Runner as Python job runner
  participant Codex as Codex + browser MCP
  Client->>Worker: POST /v1/jobs (Bearer token, prompt)
  Worker->>Matrix: Select runtime and execute runner submit
  Matrix->>Runner: Start detached job
  Worker-->>Client: 202 + job ID
  Runner->>Codex: codex exec --dangerously-bypass-approvals-and-sandbox
  Codex->>Codex: Browser, shell, files, local servers
  Client->>Worker: GET status / events / artifact
  Worker->>Matrix: Read job state or artifact
  Matrix-->>Client: Status, result or file via Worker
```

## Browser Use research

`POST /v1/research` accepts `{prompt, timeoutSeconds?}` with a required
`Idempotency-Key` (8–128 letters, digits, underscores or hyphens).
Poll `GET /v1/research/:id`; cancel with `POST /v1/research/:id/cancel`.
These use the same bearer token and job/status format as Matrix below.
Web research uses Browser Use Cloud API V4, `gemini-3.6-flash`, low reasoning,
no browser recording, no shared login profile, and `maxCostUsd: 0.25` per run.
The API key is a **Cloudflare secret**, `BROWSER_USE_API_KEY`, never embedded in iOS.

A Durable Object per job serializes submissions and persists the provider run ID.
The provider does not document create idempotency: lost/ambiguous responses are
reconciled using a unique task marker, never retried as a new paid run. A definitive
rejection (including exhausted credits) fails immediately. A cancel arriving before
submission creates a tombstone. Alarms poll independently of the phone, enforce the
submission-time deadline, and stop owned browsers on completion/cancellation.
Cleanup retries temporary errors with backoff; `cleanupComplete` confirms cleanup.
A lost submission is reconciled for up to ten minutes beyond its deadline; an
unresolvable provider outage can prevent confirmation. Cost caps are provider
limits, not a guarantee of exact billing. No auto-recharge is configured here.

Questions, optional location snapshots, and results persist in Durable Object and
Browser Use job history; there is no automatic retention deletion in this prototype.
The app asks for short, sourced, read-only research. Browser Use receives no camera
frames, microphone audio, account cookies, or Matrix credentials. Matrix routes and
its installed browser MCP remain available separately.

Add `BROWSER_USE_API_KEY` to the ignored `.secrets.json` and `.dev.vars`, then run
`npx wrangler secret bulk .secrets.json` and `npm run deploy`. Matrix credential
renewal preserves this key. The default model must support Google's
`thinkingConfig.thinkingLevel` parameter; changing provider requires changing
that request parameter too.

`npm run smoke:browser -- https://aloud-matrix-api.max-766.workers.dev` is an **opt-in paid live check**: verifies a sourced answer,
retry identity, cancellation, browser cleanup and retained Matrix connectivity.
On 2026-10-03 the first IANA lookup completed at the provider in 13.3 seconds and
cost $0.021786. A repeat completed at the provider in 44.7 seconds (47.1 seconds
including API submission/polling). Browser Use latency varies; these are simple
single-page lookups, not a general latency promise. The live Gemini/Swift flow
returned spoken audio while allowing a second conversation turn.

References: [V4 runs](https://docs.browser-use.com/cloud/api-v4/runs/create-run),
[reasoning controls](https://docs.browser-use.com/cloud/agent/thinking-levels),
[browser lifecycle](https://docs.browser-use.com/cloud/browser/quickstart).

## Try the deployed API

Base URL: `https://aloud-matrix-api.max-766.workers.dev`

Gmail reading uses the same durable `/v1/research` lifecycle with `mode: "gmail"`.
The default `mode: "web"` remains public research without a login profile. Gmail
runs alone receive the server-side `BROWSER_USE_GMAIL_PROFILE_ID` secret as
`browserSettings.profileId`. The client cannot supply an arbitrary profile ID.
The Gmail agent is instructed to use browser computer use on mail.google.com,
read only requested information, treat messages as untrusted content, and never
send, reply, forward, delete, archive or modify mail. These are agent instructions,
not a Gmail OAuth read-only scope: the signed-in browser itself retains account
permissions, and opening an unread message may cause Gmail to mark it read.
If the profile expires, the user must sign in again in Browser Use. Profile data
stays with Browser Use; requested answers pass through the Worker and Gemini for
speech. Job prompts/results use the existing durable storage lifecycle.

Validated on October 3, 2026: the deployed Gmail mode reported that the inbox was
visible using the saved profile, without opening individual messages or returning
mail contents. Browser cleanup completed. A live Gemini session selected
`read_gmail` for an email-access request; routing/isolation tests and the signed
iPhone build passed, and the app was installed and launched on the phone.

The API token is in the ignored `backend/.secrets.json` (`API_TOKEN`) and `.dev.vars`. It is also configured as a Cloudflare secret. The example client reads it without printing it:

```sh
cd ~/projects/aloud/backend
export ALOUD_API_URL=https://aloud-matrix-api.max-766.workers.dev
node --input-type=module <<'JS'
import { client } from './scripts/client.mjs';
const api = await client();
const response = await api('/v1/jobs', {
  method: 'POST',
  headers: { 'Idempotency-Key': 'my-first-research-001' },
  body: JSON.stringify({
    prompt: 'Use the browser to visit example.com and follow Learn more. Save a short summary and screenshot in artifacts/.',
    timeoutSeconds: 180
  })
});
console.log(await response.json());
JS
```

Poll `/v1/jobs/<id>` with the same client to get the result. Change the idempotency key for each new task. Repeat the same key and body to retry a dispatch; reusing it with different input returns `409`.

For a complete browser/files/network test:

```sh
npm run smoke -- "$ALOUD_API_URL"
```

This test creates a CSV, computes its sum, creates and serves a local website, clicks a button using browser MCP, navigates a public website, and downloads proof and screenshots into ignored `.smoke/`. It also verifies authentication, idempotency and cancellation.

## HTTP interface

Every `/v1/` endpoint requires `Authorization: Bearer <API_TOKEN>`. `GET /health` is public and only checks Worker availability.

| Method | Path | Purpose |
| --- | --- | --- |
| GET | `/v1/computer` | Check Matrix runner connectivity and configured mode |
| POST | `/v1/jobs` | Submit `{prompt, timeoutSeconds?}`; returns 202 and Location |
| GET | `/v1/jobs/:id` | State, final response and artifact list |
| POST | `/v1/jobs/:id/cancel` | Cancel queued job or request termination of active job |
| GET | `/v1/jobs/:id/events?cursor=0` | Read progress metadata and next byte cursor |
| GET | `/v1/jobs/:id/artifact?path=proof.json` | Download a file from the job's artifacts directory |

Statuses: `queued`, `running`, `succeeded`, `failed`, `timed_out`, `cancelled`. Cancellation of an active job is asynchronous: poll until terminal. A successful process exit means Codex completed its turn; applications must still inspect its answer and validate task-specific outcomes.

Prompts: 1–20,000 characters. Timeout: 10–600 seconds (default 180), starting when execution begins. One job runs at a time on the shared computer. Artifact downloads are limited to 700,000 bytes per file to fit Matrix's 1 MiB terminal response limit; larger files remain on Matrix. Results return at most 100,000 characters and up to 100 artifact entries. Progress exposes tool/status metadata; full Codex JSONL and stderr stay on Matrix.

If submission returns a gateway error, the response includes `jobId` and `statusUrl`: the detached job may already exist. Poll or retry with the **same** idempotency key. No key means each request creates a new job.

## Setup and redeploy

Prerequisites: Node 22+, Python 3.11+, authenticated Matrix CLI cloud profile, and a Cloudflare account. On Matrix, Codex must be installed and logged in and the browser MCP configured. The installation script only installs this project's job runner; it preserves your Codex login and MCP configuration.

```sh
npm ci
npm run configure          # reads ~/.matrixos/profiles/cloud/auth.json
npm run install:matrix     # uploads Python runner, checks its health
npx wrangler login
npm run deploy
npx wrangler secret bulk .secrets.json
```

`npm run configure` creates local ignored credentials with mode 0600, preserving the existing API token and other provider secrets. It does not print secrets. Use `MATRIX_PROFILE` to select another local profile. Worker runtime origins, slot and runner path are in `wrangler.jsonc`; the installer defaults to the same primary Matrix computer and path.

Matrix principal tokens expire. The initial deployment's token expires **2026-10-04 11:28 UTC**. After renewing Matrix CLI authentication, run `npm run configure` and `npx wrangler secret bulk .secrets.json` again. This example does **not** refresh credentials automatically; expired/revoked access returns `503 matrix_auth_required`. Codex uses the existing ChatGPT login on Matrix and its account limits.

For local Worker development, run `npm run dev`. It still executes jobs on the real Matrix computer.

## Remote execution

Runner: `/home/matrix/home/projects/aloud-research/api/runner.py`

Job data: `api/jobs/job_<id>/` beneath the same project. Each directory contains `request.json`, `status.json`, `events.jsonl`, `stderr.log`, `result.txt` and `work/artifacts/`. Jobs persist after HTTP disconnection. If the supervisor disappears, polling marks the job failed; jobs are not automatically restarted after a VM reboot. There is no automatic retention cleanup yet.

Codex starts with `--dangerously-bypass-approvals-and-sandbox`, uses the computer's configured default model, and automatically approves tools on enabled MCP servers for that invocation. Existing per-tool approval overrides are also set to approve. Browser output is redirected to the current job's artifacts directory. These per-run overrides do not rewrite global Codex settings. Existing enabled/disabled tool selections remain in effect.

This is a single-owner hackathon API. A valid API token grants agent execution with the Matrix user's full permissions, including its existing passwordless sudo. Jobs share the computer and are not isolated from one another. Keep the token in trusted server-side clients. Cancellation terminates Codex and its process group; it cannot undo completed actions or guarantee removal of deliberately detached descendants. Chromium's own browser sandbox remains enabled; that is separate from the disabled Codex execution sandbox.

The adapter uses the gateway endpoints used by Matrix CLI 0.3.21: computer inventory, runtime selection, terminal execution and file upload. These may change with Matrix releases. The hosted Matrix MCP endpoint is not required.

## Validation

```sh
npm run typecheck
npm test
npm run test:runner
npx wrangler deploy --dry-run
```

TypeScript tests cover authentication, validation, safe dispatch arguments, token exchange, idempotency IDs, transport errors and artifact paths. Python tests exercise detached execution, persistent results, idempotency conflicts, running/queued cancellation, deadlines, artifacts, sanitized events and unattended MCP settings. The deployed smoke test exercises the real Worker, Matrix gateway, Codex and browser.

Verified on **2026-10-03** against the deployed Worker: job
`job_a308338f0e7e390a9c29b20b78d64b10` completed in 103.7 seconds without approvals.
It wrote and read a CSV (sum 17), created a local website, clicked its button,
followed example.com's link to IANA and downloaded both browser screenshots.
The downloaded CSV and PNG files were independently checked. Unauthenticated
requests were rejected, repeated submissions returned the same job, and a queued
job was cancelled. All six API tests and four runner tests also passed.
