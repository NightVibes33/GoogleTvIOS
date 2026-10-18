import { createHash } from "node:crypto";

const VALID_CODES = new Set([
  "remote.connection.lost", "remote.handshake.failed",
  "remote.pairing.failed", "remote.ime.failed", "remote.voice.failed",
  "discovery.bonjour.failed", "cast.offer.failed", "cast.codec.rejected",
  "cast.rtp.timeout", "cast.crypto.failed", "cast.network.failed",
  "cast.capture.failed", "cast.session.failed",
  "legacy.cast.media.missing"
]);

function json(res, status, body) {
  res.setHeader("Content-Type", "application/json; charset=utf-8");
  res.setHeader("Cache-Control", "no-store");
  return res.status(status).json(body);
}

export function sanitizeLogLine(value) {
  let line=String(value).slice(0,400);
  if (/\b(pass(word|code)?|pin|authorization|bearer|token|secret|credential|cookie|private[\s_-]*key|keyboard[\s_-]*text|text[\s_-]*value|clipboard|typed[\s_-]*text|session[\s_-]*id)\b/i.test(line)) {
    return "[private diagnostic event omitted]";
  }
  line=line.replace(/https?:\/\/[^\s"'<>]+/gi,"[url]")
    .replace(/\b(?:\d{1,3}\.){3}\d{1,3}\b/g,"[ip]")
    .replace(/\b(?:[a-f0-9]{0,4}:){2,}[a-f0-9:]{2,}\b/gi,"[ipv6]")
    .replace(/\b[a-z0-9._-]+\.local\b/gi,"[host]")
    .replace(/\b(?:[a-f0-9]{2}[:-]){5}[a-f0-9]{2}\b/gi,"[mac]")
    .replace(/\b(?:[a-f0-9]{2}[:-]){5}[a-f0-9]{2}\b/gi,"[mac]")
    .replace(/\b[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}\b/gi,"[email]")
    .replace(/\b[a-f0-9]{24,}\b/gi,"[identifier]")
    .replace(/\b\d{6,10}\b/g,"[number]")
    .replace(/[\r\n`|]/g," ");
  return line.slice(0,300);
}

export function validate(body) {
  if (!body || typeof body !== "object" || Array.isArray(body) ||
      body.schema !== 2 || body.app !== "castdeck" || body.os !== "ios" ||
      typeof body.release !== "string" ||
      !/^\d{1,3}\.\d{1,3}\.\d{1,3}$/.test(body.release) ||
      typeof body.batchID !== "string" ||
      !/^[a-f0-9-]{36}$/i.test(body.batchID) ||
      typeof body.deviceModel !== "string" ||
      !/^[a-zA-Z0-9,_-]{2,48}$/.test(body.deviceModel) ||
      typeof body.iosVersion !== "string" ||
      !/^\d{1,3}(?:\.\d{1,3}){1,3}$/.test(body.iosVersion) ||
      typeof body.appBuild !== "string" ||
      !/^\d{1,12}$/.test(body.appBuild) ||
      typeof body.timestampUTC !== "string" ||
      Number.isNaN(Date.parse(body.timestampUTC)) ||
      !Array.isArray(body.logLines) || body.logLines.length > 80 ||
      !Array.isArray(body.events) || body.events.length < 1 ||
      body.events.length > 25) return null;
  const logs=[];
  for (const line of body.logLines) {
    if (typeof line !== "string" || line.length > 400) return null;
    logs.push(sanitizeLogLine(line));
  }
  const events=[];
  for (const event of body.events) {
    if (!event || !VALID_CODES.has(event.code) ||
        !Number.isInteger(event.count) || event.count < 1 ||
        event.count > 1000) return null;
    events.push({code:event.code,count:event.count});
  }
  return {release:body.release,batchID:body.batchID,events,
    deviceModel:body.deviceModel,iosVersion:body.iosVersion,
    appBuild:body.appBuild,timestampUTC:body.timestampUTC,
    logLines:logs};
}

const sha = input => createHash("sha256").update(input).digest("hex");

async function redis(commands) {
  const address = process.env.UPSTASH_REDIS_REST_URL;
  const secret = process.env.UPSTASH_REDIS_REST_TOKEN;
  if (!address || !secret) throw new Error("Redis is not configured");
  const response = await fetch(address.replace(/\/$/, "") + "/pipeline", {
    method: "POST",
    headers: { Authorization: "Bearer " + secret,
               "Content-Type": "application/json" },
    body: JSON.stringify(commands),
    signal: AbortSignal.timeout(5000)
  });
  if (!response.ok) throw new Error("Rate limit service unavailable");
  const payload = await response.json();
  if (!Array.isArray(payload) || payload.some(x => x.error)) {
    throw new Error("Rate limit service failed");
  }
  return payload.map(x => x.result);
}

async function github(path, init = {}) {
  const token = process.env.GITHUB_DIAGNOSTICS_TOKEN;
  const response = await fetch("https://api.github.com" + path, {
    ...init,
    headers: {
      "Accept": "application/vnd.github+json",
      "Authorization": "Bearer " + token,
      "X-GitHub-Api-Version": "2022-11-28",
      "User-Agent": "CastDeck-Telemetry-Gateway/1.0",
      ...(init.body ? { "Content-Type": "application/json" } : {})
    },
    signal: AbortSignal.timeout(8000)
  });
  if (!response.ok) throw new Error("GitHub service error " + response.status);
  return await response.json();
}

function configured() {
  return !!(
    process.env.GITHUB_DIAGNOSTICS_TOKEN &&
    /^[-\w]+\/[-\w.]+$/.test(process.env.GITHUB_DIAGNOSTICS_REPO || "") &&
    process.env.UPSTASH_REDIS_REST_URL &&
    process.env.UPSTASH_REDIS_REST_TOKEN &&
    (process.env.TELEMETRY_HASH_SALT || "").length >= 20
  );
}

export default async function handler(req, res) {
  if (req.method !== "POST") return json(res, 405, { error: "method_not_allowed" });
  if (!configured()) return json(res, 503, { error: "reporting_not_configured" });
  const size = Number(req.headers["content-length"] || 0);
  if (size > 40000 || (size < 1 && typeof req.body === "string" && req.body.length > 40000)) {
    return json(res, 413, { error: "too_large" });
  }
  let parsed = req.body;
  if (typeof parsed === "string") {
    try { parsed = JSON.parse(parsed); } catch { return json(res, 400, { error: "invalid_json" }); }
  }
  if (JSON.stringify(parsed).length > 40000) return json(res,413,{error:"too_large"});
  const report = validate(parsed);
  if (!report) return json(res, 400, { error: "invalid_event" });

  // Do not persist IPs or identifying request headers. Redis stores only a
  // daily salted digest, and GitHub issues contain only fixed event codes.
  const rawIP = String(req.headers["x-forwarded-for"] || req.socket?.remoteAddress || "")
    .split(",")[0].trim().slice(0, 80);
  const salt = process.env.TELEMETRY_HASH_SALT;
  const key = sha(salt + ":" + rawIP + ":" + new Date().toISOString().slice(0,10));
  const batchKey = "castdeck:batch:" + sha(salt + ":" + report.batchID);
  try {
    const result = await redis([
      ["INCR", "castdeck:limit:" + key],
      ["EXPIRE", "castdeck:limit:" + key, 86400]
    ]);
    if (Number(result[0]) > 24) return json(res, 429, { error: "rate_limited" });
    const previouslyProcessed = await redis([["GET", batchKey]]);
    if (previouslyProcessed[0] === "ok") return json(res, 202, { accepted: true });

    const repo = process.env.GITHUB_DIAGNOSTICS_REPO;
    const metadata = await github("/repos/" + repo);
    // GitHub issues are publicly readable in public repositories.
    if (!metadata.private) return json(res, 503, { error: "private_repository_required" });

    for (const event of report.events) {
      const issueTitle = "[CastDeck telemetry] " + event.code;
      const search = "repo:" + repo + " is:issue in:title \"" + issueTitle + "\"";
      const found = await github("/search/issues?q=" + encodeURIComponent(search) + "&per_page=10");
      let issue = found.items?.find(x => x.title === issueTitle);
      if (!issue) {
        issue = await github("/repos/" + repo + "/issues", {
          method: "POST",
          body: JSON.stringify({
            title: issueTitle,
            body: [
              "Automatically grouped CastDeck client diagnostics.",
              "",
              "**Failure code:** \`" + event.code + "\`",
              "**First reported version:** \`" + report.release + "\`",
              "**Device model:** `" + report.deviceModel + "`",
              "**iOS version:** `" + report.iosVersion + "`",
              "**App build:** `" + report.appBuild + "`",
              "**UTC timestamp:** `" + report.timestampUTC + "`",
              "",
              "**Sanitized diagnostic excerpt (up to 80 lines):**",
              "~~~text",
              ...report.logLines,
              "~~~",
              "",
              "Only allowlisted failure codes, device metadata and redacted diagnostic excerpts are collected.",
              "No raw log files, IP addresses, voice, typed text, PINs or screenshots."
            ].join("\n")
          })
        });
      }

      const aggregate = await redis([
        ["INCRBY", "castdeck:issue:" + sha(event.code), event.count],
        ["EXPIRE", "castdeck:issue:" + sha(event.code), 90*86400]
      ]);
      const total = Number(aggregate[0]);
      const prior = total - event.count;
      // At scale, update the same issue only at milestones. This avoids
      // thousands of comments and GitHub API rate exhaustion.
      if (Math.floor(total/50) > Math.floor(prior/50)) {
        await github("/repos/" + repo + "/issues/" + issue.number + "/comments", {
          method: "POST",
          body: JSON.stringify({
            body: [
              "Automated report milestone: **" + total +
                "** occurrences; newest release **" + report.release + "**.",
              "**Device model:** `" + report.deviceModel + "`",
              "**iOS version:** `" + report.iosVersion + "`",
              "**App build:** `" + report.appBuild + "`",
              "**UTC timestamp:** `" + report.timestampUTC + "`",
              "",
              "Sample of sanitized diagnostic events:",
              "~~~text",
              ...report.logLines,
              "~~~"
            ].join("\n")
          })
        });
      }
    }
    await redis([["SET", batchKey, "ok", "EX", 30*86400]]);
    return json(res, 202, { accepted: true });
  } catch (error) {
    // Never return tokens, private repository names or user data in errors.
    console.error("Diagnostic ingestion unavailable:", error?.message?.slice(0,100));
    return json(res, 503, { error: "temporarily_unavailable" });
  }
}
