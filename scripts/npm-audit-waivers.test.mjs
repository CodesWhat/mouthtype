import assert from "node:assert/strict";
import test from "node:test";
import { evaluate, levelFromArgs, parseUpperBound } from "./npm-audit-waivers.mjs";

const ID = "GHSA-fc5q-39xc-vjpf";
const waivers = [{ id: ID, package: "picomatch", expires: "2026-12-17", reason: "test" }];
const adv = (over = {}) => ({
  source: 1,
  name: "picomatch",
  title: "ReDoS",
  url: `https://github.com/advisories/${ID}`,
  severity: "high",
  range: "<=4.0.7",
  ...over,
});
const report = (over = {}) => ({
  vulnerabilities: {
    picomatch: { name: "picomatch", severity: "high", via: [adv()] },
    fdir: { name: "fdir", severity: "high", via: ["picomatch"] },
    tinyglobby: { name: "tinyglobby", severity: "high", via: ["fdir", "picomatch"] },
    vite: { name: "vite", severity: "high", via: ["tinyglobby", "fdir", "picomatch"] },
    ...over,
  },
});
const base = {
  report: report(),
  waivers,
  today: "2026-11-17",
  level: "high",
  npmView: () => ["4.0.6", "4.0.7"],
};

test("waived and unexpired passes with a waived advisory", () => {
  const r = evaluate(base);
  assert.equal(r.ok, true);
  assert.deepEqual(r.waived.map((w) => w.id), [ID]);
});

test("last valid day still passes, day after fails", () => {
  assert.equal(evaluate({ ...base, today: "2026-12-17" }).ok, true);
  const r = evaluate({ ...base, today: "2026-12-18" });
  assert.equal(r.ok, false);
  assert.ok(r.warnings.some((w) => w.includes("expired")));
});

test("a published fix voids the waiver", () => {
  const r = evaluate({ ...base, npmView: () => ["4.0.7", "4.0.8"] });
  assert.equal(r.ok, false);
  assert.ok(r.warnings.some((w) => w.includes("void")));
});

test("prerelease above the range is not a fix; strict < bound treats the bound as fixed", () => {
  assert.equal(evaluate({ ...base, npmView: () => ["4.0.7", "5.0.0-beta.1"] }).ok, true);
  const strict = report({ picomatch: { name: "picomatch", severity: "high", via: [adv({ range: "<4.0.7" })] } });
  assert.equal(evaluate({ ...base, report: strict, npmView: () => ["4.0.7"] }).ok, false);
});

test("npm view failure fails closed", () => {
  const r = evaluate({
    ...base,
    npmView: () => {
      throw new Error("offline");
    },
  });
  assert.equal(r.ok, false);
});

test("an unrelated high advisory still fails", () => {
  const other = adv({ name: "lodash", url: "https://github.com/advisories/GHSA-aaaa-bbbb-cccc", range: "<=4.17.20" });
  const r = evaluate({
    ...base,
    report: report({ lodash: { name: "lodash", severity: "high", via: [other] } }),
  });
  assert.equal(r.ok, false);
  assert.deepEqual(r.remaining.map((x) => x.name), ["lodash"]);
});

test("entry mixing a waived and an unwaived advisory is not waived", () => {
  const other = adv({ name: "x", url: "https://github.com/advisories/GHSA-aaaa-bbbb-cccc" });
  const r = evaluate({
    ...base,
    report: report({ vite: { name: "vite", severity: "high", via: ["picomatch", other] } }),
  });
  assert.deepEqual(r.remaining.map((x) => x.name), ["vite"]);
});

test("string via chain resolves transitively", () => {
  const r = evaluate({ ...base, report: { vulnerabilities: { vite: report().vulnerabilities.vite, tinyglobby: report().vulnerabilities.tinyglobby, fdir: report().vulnerabilities.fdir, picomatch: report().vulnerabilities.picomatch } } });
  assert.equal(r.ok, true);
});

test("via string pointing at a missing entry fails closed", () => {
  const r = evaluate({
    ...base,
    report: { vulnerabilities: { vite: { name: "vite", severity: "high", via: ["ghost"] } } },
  });
  assert.equal(r.ok, false);
});

test("unparseable ranges fail closed", () => {
  for (const range of ["*", ">=1.0.0", "<=4.0.7 || >=5.0.0 <5.1.0", "<=4.0", "^4.0.0", ""]) {
    const rep = report({ picomatch: { name: "picomatch", severity: "high", via: [adv({ range })] } });
    const r = evaluate({ ...base, report: rep });
    assert.equal(r.ok, false, `range ${JSON.stringify(range)}`);
    assert.ok(r.warnings.some((w) => w.includes("unparseable")));
  }
});

test("range parsing accepts only supported forms", () => {
  assert.deepEqual(parseUpperBound("<=4.0.7"), { op: "<=", bound: [4, 0, 7] });
  assert.deepEqual(parseUpperBound(">=4.0.0 <4.0.7"), { op: "<", bound: [4, 0, 7] });
  assert.equal(parseUpperBound("<4"), null);
});

test("audit level is respected", () => {
  const rep = { vulnerabilities: { lodash: { name: "lodash", severity: "moderate", via: [adv({ name: "lodash", url: "u/GHSA-zzzz" })] } } };
  assert.equal(evaluate({ ...base, report: rep, level: "high" }).ok, true);
  assert.equal(evaluate({ ...base, report: rep, level: "moderate" }).ok, false);
  assert.equal(evaluate({ ...base, report: rep, level: undefined }).ok, false);
});

test("levelFromArgs", () => {
  assert.equal(levelFromArgs(["--package-lock-only", "--audit-level=high"]), "high");
  assert.equal(levelFromArgs(["--audit-level", "critical"]), "critical");
  assert.equal(levelFromArgs([]), "low");
});
