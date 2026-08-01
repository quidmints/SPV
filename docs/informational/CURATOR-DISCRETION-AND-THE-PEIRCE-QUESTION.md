# Curator discretion and the Peirce question

**Purpose.** This is the commentary drafted to fill the `[[[ TODO insert commentary about this ]]]`
block in the legal analysis, at the point where Howey prong three is being argued. That file was not
found in either repository, so the text lives here until it is placed. It is written to be inserted
verbatim after the prong-three discussion and before the *SEC v. Barry* citation.

> **Sourcing caveat, load-bearing.** The Peirce statement (SEC newsroom, 22 July 2026, on crypto vaults
> and lending strategies) postdates the training data of the model that drafted this. Everything below
> works from a second-hand characterisation, namely that the SEC is examining the economic function of
> vaults and curators, that a curator deciding how other people's assets are deployed may be acting as
> a fund manager or investment adviser even when everything happens through smart contracts, that
> custodial versus non-custodial is not the axis of concern, and that what matters is whether a strategy
> is credibly rules-based or whether users are relying on the judgment of an identifiable manager.
> **Read the statement before relying on any of this.**

---

## The commentary

The Peirce statement is the best thing that could have happened to this section, because it replaces a
subjective prong-three argument with an objective question about code, and QU!D can answer that one.

If the operative test is whether a strategy is credibly rules-based or whether depositors rely on the
continuing judgment of an identifiable manager, the question becomes: after launch, what function can
any person call that changes where depositor assets are deployed? The answer is none, and it is
enforced rather than promised.

`Aux.finalize()` calls `renounceOwnership()`. Every discretionary lever in the reserve sits behind
`onlyOwner`, so all of them die at that call: `evacuate`, `setVault`, `setStableFeed`, `setAssetFeed`,
`setEthVenue`, `setBTCChannels`, `setQuid`. `Vogue.setup()` renounces the same way. The basket's
constituent set is fixed at deployment and cannot be added to. The leverage venue allowlist is pin-once
then frozen behind a `venuesFrozen` flag, described in the source itself as matching the
renounce-everything posture. The contracts are not upgradeable and have no administrator, so changing
allocation logic would require a new deployment and a voluntary migration by depositors.

**This is the distinction against a curated vault.** A Morpho or Euler curator holds *continuing*
discretion: they can reallocate tomorrow, into markets nobody has seen yet, and depositors are relying
on that judgment prospectively. QU!D's allocation decision was exercised once, at deployment, and is now
unreachable by anyone including the deployer. The Howey argument already turns on *ongoing* managerial
effort, following the Ninth Circuit's 2025 reasoning in *SEC v. Barry*, and the Peirce framing converges
on the same axis from the adviser side rather than the security side.

**Two design decisions were made specifically to remove discretion, and they read as evidence of
intent.** `pokeVaultHealth` is permissionless and reads only ERC-4626 ground truth, comparing
`convertToAssets` against `maxWithdraw`. It can tighten and never loosen and it cannot re-quote anyone's
value. It replaced a graded `haircutBps` lever that was removed *because* it was owner-only. A system
that deletes its own discretionary levers before anyone asks is making the rules-based case in the
strongest available form. Separately, the yield venue is chosen per deposit by the depositor and there
is no setter, so what allocation discretion exists belongs to the depositor.

**A further argument runs from the entity rather than the code.** The Investment Advisers Act definition
at §202(a)(11) requires acting as an adviser **for compensation**. A memberless Cayman foundation whose
only extraction is a tranche sized to recover a documented accumulated deficit under ASC 958, and which
terminates at breakeven, has a weak compensation element. Code facts and entity facts point the same
way, which neither does alone.

**What survives, and should be disclosed rather than discovered.** `Vault` retains three owner setters
(`setRover`, `setLevManager`, `setLevManagerBTC`) and no renounce was found on that contract; if the
intent is the renounce-everything posture the rest of the system takes, **this is the gap to close
before launch.** The multisig over the enclave measurement whitelist governs which code may operate the
Bitcoin hop and moves no funds, which is a governance surface and not an investment-discretion one. The
off-chain keeper managing leveraged positions is protocol-operated, and its defence is that it executes
a closed-form target, `1 − √(entry/now)`, on opt-in positions isolated to the depositor's own external
account, so it selects nothing.

**Summary for counsel:** composition and allocation logic are frozen at deployment, the surviving
automated paths are permissionless and read objective on-chain state, and the discretion that remains
is over infrastructure rather than over where depositor money goes. Closing the `Vault` setters would
make that claim complete.

---

## Verification trail

Every code fact above was read from source on 2026-08-01, not recalled:

| claim | location |
|---|---|
| Aux renounces at finalize | `evm/src/Aux.sol:598-604` |
| Vogue renounces at setup | `evm/src/Vogue.sol:309-313` |
| evacuate / setVault / setStableFeed / setAssetFeed are onlyOwner | `evm/src/Aux.sol:487`, `:497`, `:167`, `:191` |
| basket constituents fixed at deploy, no permissionless binder | `evm/src/Aux.sol:177` |
| lev venue allowlist pin-once then frozen | `evm/src/LevManager.sol:146`, `:208-210` |
| pokeVaultHealth permissionless, ERC-4626 ground truth only | `docs/informational/VAULT-WATCHER.md`; `Aux.pokeVaultHealth` |
| graded haircutBps removed because owner-only | `docs/informational/VAULT-WATCHER.md` |
| depositor picks venue, no setter | `docs/informational/ETH-VENUES.md`; `Vogue.sol:1277-1281` |
| Safe governs MRENCLAVE whitelist only, moves no funds | `evm/src/AttestedHopRegistry.sol:47-53` |
| **Vault setters with no renounce found** | `evm/src/Vault.sol:355`, `:362`, `:372` |
| IL target closed-form, zero at or below entry | `evm/src/imports/LevMath.sol:109-125` |

## Open

1. Read the actual Peirce statement and confirm the characterisation above.
2. Close the three `Vault` owner setters, or record why they must survive launch.
3. Place this text into the legal document at the TODO block and delete this file's preamble.
