// Narrow, expiring waivers for `npm audit --json` reports.
// Used by scripts/npm-audit-retry.sh; kept separate so it can be tested with
// injected npm-view output and dates.
//
// A waiver applies to an advisory only when all of these hold:
//   - the advisory url ends with the waived id and the package name matches
//   - today (UTC) <= expires
//   - the advisory range is `[>=A ]<=X.Y.Z` or `[>=A ]<X.Y.Z` (anything else fails closed)
//   - no stable version above that range is published (a fix exists, so the waiver is void)
// A package entry whose `via` names another package is waived only when every
// advisory reachable through it is waived.
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

const LEVELS = ["info", "low", "moderate", "high", "critical"];
const RANGE_RE = /^(?:>=\s*\S+\s+)?(<=|<)\s*(\d+)\.(\d+)\.(\d+)$/;

function parseVersion(v) {
  const m = /^(\d+)\.(\d+)\.(\d+)$/.exec(v);
  return m ? [Number(m[1]), Number(m[2]), Number(m[3])] : null;
}

function cmp(a, b) {
  for (let i = 0; i < 3; i++) if (a[i] !== b[i]) return a[i] - b[i];
  return 0;
}

// Returns {op, bound} or null when the range isn't a simple upper bound.
export function parseUpperBound(range) {
  const m = RANGE_RE.exec(String(range ?? "").trim());
  return m ? { op: m[1], bound: [Number(m[2]), Number(m[3]), Number(m[4])] } : null;
}

export function npmViewVersions(pkg) {
  const raw = execFileSync("npm", ["view", pkg, "versions", "--json"], {
    encoding: "utf8",
    timeout: 60000,
  });
  const parsed = JSON.parse(raw);
  return Array.isArray(parsed) ? parsed : [parsed];
}

export function levelFromArgs(args) {
  for (let i = 0; i < args.length; i++) {
    if (args[i].startsWith("--audit-level=")) return args[i].slice("--audit-level=".length);
    if (args[i] === "--audit-level" && args[i + 1]) return args[i + 1];
  }
  return "low";
}

/**
 * @param {object} o
 * @param {object} o.report parsed `npm audit --json` output
 * @param {Array} o.waivers parsed waiver file
 * @param {string} o.today UTC date, YYYY-MM-DD
 * @param {string} [o.level] npm --audit-level, default low
 * @param {(pkg: string) => string[]} o.npmView published versions for a package
 */
export function evaluate({ report, waivers, today, level = "low", npmView }) {
  const vulns = report.vulnerabilities || {};
  const threshold = LEVELS.indexOf(level);
  const min = threshold === -1 ? 0 : threshold;
  const warnings = [];
  const waived = new Map(); // id -> waiver
  const warned = new Set();
  const viewCache = new Map();

  const warnOnce = (msg) => {
    if (!warned.has(msg)) {
      warned.add(msg);
      warnings.push(msg);
    }
  };

  const versionsOf = (pkg) => {
    if (!viewCache.has(pkg)) {
      try {
        viewCache.set(pkg, npmView(pkg));
      } catch {
        viewCache.set(pkg, null);
      }
    }
    return viewCache.get(pkg);
  };

  // Returns the waiver that covers this advisory, or null.
  const waiverFor = (adv) => {
    const url = String(adv.url || "");
    const w = waivers.find((x) => adv.name === x.package && url.endsWith(x.id));
    if (!w) return null;
    if (!(today <= w.expires)) {
      warnOnce(`npm audit waiver for ${w.id} (${w.package}) expired ${w.expires}; not applied`);
      return null;
    }
    const bound = parseUpperBound(adv.range);
    if (!bound) {
      warnOnce(`npm audit waiver for ${w.id} not applied: unparseable advisory range "${adv.range}"`);
      return null;
    }
    const versions = versionsOf(w.package);
    if (!versions) {
      warnOnce(`npm audit waiver for ${w.id} not applied: could not list published ${w.package} versions`);
      return null;
    }
    const fixed = versions
      .map(parseVersion)
      .filter(Boolean)
      .some((v) => (bound.op === "<=" ? cmp(v, bound.bound) > 0 : cmp(v, bound.bound) >= 0));
    if (fixed) {
      warnOnce(`npm audit waiver for ${w.id} is void: a ${w.package} version above the vulnerable range is published; upgrade instead`);
      return null;
    }
    waived.set(w.id, w);
    return w;
  };

  // True when every advisory reachable from this package entry is waived.
  const entryWaived = (name, seen) => {
    const entry = vulns[name];
    if (!entry || seen.has(name)) return !!entry;
    seen.add(name);
    const via = entry.via || [];
    if (via.length === 0) return false;
    return via.every((v) => (typeof v === "string" ? entryWaived(v, seen) : !!waiverFor(v)));
  };

  const remaining = [];
  for (const [name, entry] of Object.entries(vulns)) {
    if (LEVELS.indexOf(entry.severity) < min) continue;
    if (!entryWaived(name, new Set())) remaining.push({ name, severity: entry.severity });
  }

  return {
    ok: remaining.length === 0,
    remaining,
    waived: [...waived.values()],
    warnings,
  };
}

function main(argv) {
  const [reportPath, waiverPath, ...npmArgs] = argv;
  const report = JSON.parse(readFileSync(reportPath, "utf8"));
  const waivers = JSON.parse(readFileSync(waiverPath, "utf8"));
  const result = evaluate({
    report,
    waivers,
    today: new Date().toISOString().slice(0, 10),
    level: levelFromArgs(npmArgs),
    npmView: npmViewVersions,
  });
  for (const w of result.warnings) console.log(`::warning::${w}`);
  if (result.ok) {
    for (const w of result.waived)
      console.log(`::warning::npm audit advisory ${w.id} (${w.package}) waived until ${w.expires}: ${w.reason}`);
    return 0;
  }
  for (const r of result.remaining) console.log(`${r.severity.padEnd(9)} ${r.name} (not waived)`);
  return 1;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) process.exit(main(process.argv.slice(2)));
