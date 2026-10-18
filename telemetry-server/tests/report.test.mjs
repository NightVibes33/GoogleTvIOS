import assert from "node:assert/strict";
import {test} from "node:test";
import {validate,sanitizeLogLine} from "../api/report.mjs";

const good = {
  schema: 2, app: "castdeck", release: "2.3.0", os: "ios",
  batchID: "aaaaaaaa-aaaa-4aaa-aaaa-aaaaaaaaaaaa",
  events: [{code: "cast.rtp.timeout", count:12}],
  deviceModel:"iPhone17,3", iosVersion:"27.0.1", appBuild:"14",
  timestampUTC:"2026-10-18T14:20:00Z",
  logLines:["2026-10-18 [cast-realtime] RTP stream timeout on 192.168.4.43"]
};
test("accept model, iOS, version/build and sanitized excerpts",()=>{
  const result=validate(good);
  assert.equal(result.deviceModel,"iPhone17,3");
  assert.equal(result.iosVersion,"27.0.1");
  assert.equal(result.appBuild,"14");
  assert.equal(result.logLines.length,1);
  assert.equal(result.logLines[0].includes("192.168.4.43"),false);
});
test("redact passwords, pairing PINs, network addresses, emails and URLs",()=>{
  assert.equal(sanitizeLogLine("PIN 123456"),"[private diagnostic event omitted]");
  assert.equal(sanitizeLogLine("password=test"),"[private diagnostic event omitted]");
  assert.equal(sanitizeLogLine("host 192.168.4.43, Android.remote.local").includes("192.168."),false);
  assert.equal(sanitizeLogLine("Contact me@example.com or https://service.example.com/key"),"Contact [email] or [url]");
});
test("reject payloads without a valid model or OS",()=>{
  assert.equal(validate({...good,deviceModel:"my personal iPhone"}),null);
  assert.equal(validate({...good,iosVersion:"evil"}),null);
});
test("reject invented event types and invalid counts",()=>{
  assert.equal(validate({...good,events:[{code:"PIN 1234",count:1}]}),null);
  assert.equal(validate({...good,events:[{code:"cast.rtp.timeout",count:2001}]}),null);
});
test("reject oversized diagnostic excerpts and invalid batch ID",()=>{
  assert.equal(validate({...good,logLines:["x".repeat(401)]}),null);
  assert.equal(validate({...good,logLines:Array.from({length:81},()=>"[remote] failed")}),null);
  assert.equal(validate({...good,batchID:"my-device-id"}),null);
});