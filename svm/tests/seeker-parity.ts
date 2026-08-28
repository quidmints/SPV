/**
 * seeker-parity.ts
 *
 * The Seeker app builds its instructions with `accountsStrict`, which means a
 * single renamed or reordered account is a runtime failure on a user's phone
 * rather than a compile error. This suite pins the app's account shapes to the
 * program's own IDL so that drift is caught here instead of there.
 *
 * It is deliberately static: it needs no validator, no wallet and no React
 * runtime, so it runs in the same pass as the on-chain suite and cannot be
 * skipped by an environment that lacks the mobile toolchain.
 */
import { expect } from "chai";
import * as fs from "fs";
import * as path from "path";

const ROOT = path.join(__dirname, "..");
const PROGRAM_IDL = path.join(ROOT, "target/idl/quid.json");

/**
 * The app lives beside this package in the monorepo (`seeker/` at the repo
 * root, next to the SPA) but this package is also checked out on its own, so
 * both layouts are accepted. The sibling is only believed when its parent
 * really is this monorepo — walking up looking for any directory called
 * "seeker" will happily find an unrelated one in a home directory and compare
 * against the wrong program.
 *
 * 🔴 THE APP IS IN THIS REPO NOW (`app/`, the ibiza merge), SO "ABSENT" IS NO LONGER A
 * LEGITIMATE STATE AND THIS NO LONGER SKIPS. The old doc said absence meant "nothing is
 * wrong with the program because the client is not in the tree" — true while the client
 * lived in `/home/rico/projects/seeker-main`, and it is exactly what let this file pass
 * green through an entire session of program changes. A guard that reports success when it
 * cannot see either side is worse than one that fails, because only the failing one gets fixed.
 */
function findSeeker(): string {
  const override = process.env.QUID_SEEKER_DIR;
  if (override) return override;

  const isApp = (d: string) => fs.existsSync(path.join(d, "hooks/useStockExposure.ts"));
  // `app/` — seeker + identity-wallet, a sibling of `svm/` in the SPV repo.
  const repo = path.dirname(ROOT);
  const merged = path.join(repo, "app");
  if (isApp(merged)) return merged;

  // Legacy layouts, kept so a checkout that predates the merge still resolves rather
  // than failing for the wrong reason.
  const here = path.join(ROOT, "seeker");
  if (isApp(here)) return here;
  const sibling = path.join(repo, "seeker");
  if (fs.existsSync(path.join(repo, "svm/Anchor.toml")) && isApp(sibling)) return sibling;

  throw new Error(
    "Seeker app not found. It lives at `app/` in this repo since the ibiza merge, and the " +
    "probe is `app/hooks/useStockExposure.ts`. Set QUID_SEEKER_DIR to override. This THROWS " +
    "rather than skipping on purpose — see the note above."
  );
}
const SEEKER = findSeeker();
// 🔴 THIS GUARD WAS INERT FOR AN ENTIRE SESSION OF PROGRAM CHANGES AND PASSED WHILE INERT.
//    BOTH SIDES OF THE COMPARISON WERE MISSING: `findSeeker` searched `svm/seeker` and
//    `<repo>/seeker` while the app lived outside the repo, and `target/idl/quid.json` only
//    exists after an `anchor build` nobody had run. Two absent files, every assertion
//    skipped, and a green suite reporting parity it had never checked.
// ✅ HALF OF THAT IS NOW STRUCTURALLY CLOSED: the app is `app/` in this repo (the ibiza
//    merge) and `findSeeker` THROWS rather than returning null, so the client side can no
//    longer go quietly missing.
// ⚠️ THE OTHER HALF IS NOT, AND CANNOT BE FROM HERE: `target/idl/quid.json` is a BUILD
//    ARTIFACT. Run `anchor build` first — the `readFileSync` below throws without it, which
//    is the intended failure and not a bug to route around with an existsSync check.

const camel = (s: string) => s.replace(/_([a-z])/g, (_, c) => c.toUpperCase());

/** Account keys passed to the `accountsStrict({...})` that follows `.method(` */
function accountsFor(src: string, method: string): string[] {
  const at = src.indexOf(`.${method}(`);
  expect(at, `${method} is never called by the app`).to.be.greaterThan(-1);
  const open = src.indexOf("accountsStrict({", at);
  expect(open, `${method} does not use accountsStrict`).to.be.greaterThan(-1);

  let depth = 0, i = src.indexOf("{", open), end = i;
  for (; i < src.length; i++) {
    if (src[i] === "{") depth++;
    else if (src[i] === "}" && --depth === 0) { end = i; break; }
  }
  return src.slice(open, end)
    .split("\n").slice(1)
    .map(l => l.trim())
    // Object literals here mix `name: value` with `name,` shorthand.
    .filter(l => /^[A-Za-z][A-Za-z0-9]*\s*[:,]/.test(l))
    .map(l => l.split(/[:,]/)[0].trim());
}

describe("Seeker ↔ program parity", function () {
  const program = JSON.parse(fs.readFileSync(PROGRAM_IDL, "utf8"));
  const seeker  = JSON.parse(fs.readFileSync(path.join(SEEKER, "constants/quid.json"), "utf8"));
  const hook    = fs.readFileSync(path.join(SEEKER, "hooks/useStockExposure.ts"), "utf8");

  it("P.1 The app ships the program's own IDL, not a stale copy", () => {
    expect(seeker.address).to.equal(program.address);
    expect(JSON.stringify(seeker)).to.equal(JSON.stringify(program));
    console.log("  ✓ IDL identical, program", program.address);
  });

  it("P.2 The app calls only instructions the program still exposes", () => {
    const exposed = new Set(program.instructions.map((i: any) => camel(i.name)));
    const called = [...hook.matchAll(/program\.methods\s*\n?\s*\.([a-zA-Z0-9]+)\(/g)]
      .map(m => m[1]);
    expect(called.length, "app calls no instructions at all").to.be.greaterThan(0);
    for (const c of called) expect(exposed.has(c), `app calls removed instruction ${c}`).to.be.true;
    console.log("  ✓ App calls:", [...new Set(called)].join(", "));
  });

  it("P.3 Every accountsStrict block names exactly the IDL's accounts", () => {
    for (const name of ["deposit", "withdraw"]) {
      const want = program.instructions
        .find((i: any) => i.name === name).accounts.map((a: any) => camel(a.name));
      const got = accountsFor(hook, camel(name));
      // Anchor resolves `accountsStrict` by name, so the set is what has to
      // match; ordering is only house style and is not asserted here.
      expect([...got].sort(), `${name} account set drifted`)
        .to.deep.equal([...want].sort());
      console.log(`  ✓ ${name}: all ${got.length} accounts present, none extra`);
    }
  });

  it("P.4 The app does not reach for instructions that are not a user's to send", () => {
    // Liquidation is permissionless keeper work, flash loans are a settlement
    // concern, and config is admin-only. None of them belong behind a tap.
    // `setKestrel` was dropped from this list when it was folded into `update_config`. It is NOT
    // an omission: an absent instruction cannot be called, so asserting it is absent is vacuous.
    for (const forbidden of ["liquidate", "sweep", "flashBorrow", "flashRepay",
                             "initConfig", "updateConfig"]) {
      expect(hook.includes(`.${forbidden}(`), `app should not call ${forbidden}`).to.be.false;
    }
    console.log("  ✓ No keeper, settlement or admin instructions in the app");
  });
});
