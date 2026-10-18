import assert from "node:assert/strict";
import { test } from "node:test";
import { validate } from "../api/report.mjs";

const good = {
  schema: 1, app: "castdeck", release: "2.2.0", os: "ios",
  batchID: "aaaaaaaa-aaaa-4aaa-aaaa-aaaaaaaaaaaa",
  events: [{ code: "cast.rtp.timeout", count: 12 }]
};

test("accept fixed diagnostic counts", () => {
  assert.deepEqual(validate(good)?.events, good.events);
});
test("reject raw log text and unauthorized keys", () => {
  assert.equal(validate({...good, events:[{code: "TV 192.168.4.43 PIN 1234", count:1}]}), null);
});
test("reject oversized or invalid event counts", () => {
  assert.equal(validate({...good, events:[{code:"cast.rtp.timeout", count:2001}]}), null);
});
test("reject malformed session identifiers", () => {
  assert.equal(validate({...good, batchID:"my-iphone-123"}), null);
});
