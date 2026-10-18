# CastDeck automatic diagnostics gateway

A private GitHub Issues destination for opt-in, aggregated CastDeck diagnostics.
**Never point this service at the public `NightVibes33/GoogleTvIOS` repository.**

### Deployment
Create a **separate private** GitHub repository for diagnostics (e.g.
`NightVibes33/CastDeck-Diagnostics-Private`), restrict access to maintainers,
and configure a Vercel Function deployment of this `telemetry-server/` folder.

Set these encrypted environment variables **only on Vercel**:
- `GITHUB_DIAGNOSTICS_REPO`: `owner/private-repository`.
- `GITHUB_DIAGNOSTICS_TOKEN`: a fine-grained GitHub token with Issues:
  Read and write on **only** the private diagnostics repo. Do not add
  Contents, Actions, Workflows, repository administration, or organization scopes.
- `UPSTASH_REDIS_REST_URL`, `UPSTASH_REDIS_REST_TOKEN`: server-side Redis
  used for rate limiting, deduplication and event aggregation. If absent,
  this gateway rejects all submissions.
- `TELEMETRY_HASH_SALT`: at least 20 random characters, generated server-side.
  Used to hash IP addresses for daily rate limiting; **never** sent to GitHub.

No credentials may be in the GitHub source repository or iOS app. The endpoint
refuses to submit any reports if the destination GitHub repo is public.

Once the endpoint returns HTTP 202 for a valid privacy-filtered test report,
set `CastDeckTelemetryEndpoint` in the **generated iOS Info.plist** through
`project.yml` to your real `https://.../api/report` URL and rebuild the IPA.
The toggle in CastDeck Settings remains disabled while both the diagnostics
gateway and optional Sentry DSN are unconfigured.

### Privacy + scaling
- Client-side allowlist: fixed technical failure codes and bounded counters.
  No raw Files logs, screenshots, video/audio, text fields, PINs, IP addresses,
  device names, access tokens, hostnames, or unique install IDs.
- Disabled by default until the customer opts in.
- Offline queue kept in UserDefaults with bounded counts; retries automatically.
- Gateway re-validates every event. Rate limited to 24 daily requests per
  daily salted network hash and deduplicated by random one-time batch IDs.
- **Private** GitHub issues group all reports by error code. A new comment is
  generated only at 50-occurrence milestones. Individual users are not named.
- Configure an appropriate retention policy for private issues and Upstash data.
  API source code alone does not satisfy your app's privacy-policy requirements.
- Never attach full raw logs or diagnostic archive files to GitHub issues.

### Production validation
Run `npm test`. Verify responses: 405 wrong method; 503 unconfigured
credentials, rate limiting or a public GitHub destination; 400 invalid code;
202 accepted; 429 rate limited. Check the issue appears only in a private repo.
