//! §DELIVER — Backed xStocks primary market, Market Flow leg.
//!
//! ⭐ **THIS IS THE ONE BACKED FLOW A PROGRAM CAN DRIVE.** Backed exposes three
//! primary-market flows and only this one is reachable from a PDA:
//!
//!   • **xChange (atomic RFQ)** — returns a base64 partially-signed
//!     `VersionedTransaction` that the client must deserialize, CO-SIGN and
//!     submit inside a ~60-90s blockhash window. A PDA cannot co-sign a
//!     transaction someone else built; PDA signing is `invoke_signed` from
//!     inside a program. So xChange needs an off-chain operator holding a hot
//!     key, which is a custody surface we do not want.
//!   • **xPort (in-kind)** — share↔token through Alpaca, entirely off-chain.
//!   • **Market Flow** — send stablecoins to a product-specific ISSUANCE
//!     address to mint; send tokens to a REDEMPTION address to redeem. That is
//!     a plain SPL transfer to a fixed address, which is exactly what a vault
//!     PDA can do with `invoke_signed`. No keypair, no signing window.
//!
//! ⚠️ **WHAT WE PAY FOR THAT IS ATOMICITY.** Market Flow is asynchronous: the
//! dollars leave now and the paper arrives later, at a price nobody locked.
//! The gap is a real cost and it is NOT the round-trip spread `facility_sim`
//! already charges — that prices the spread, not the exposure carried while
//! the order is in flight. `Cfg` has no term for it (grep: no lag, latency,
//! delay or settle field), so the sim currently cannot price the leg this
//! module implements. Treat `pending_*` below as the on-chain measurement that
//! would calibrate it.
//!
//! 🔴 **WE ONLY EVER NEED PAPER IN ONE DIRECTION.** The pool is short the NET
//! of each ticker's book. Net long means the pool owes an UNBOUNDED upside, and
//! nothing but the asset itself funds that — which is what the funding-match
//! result says. Net short means the pool owes a payout that GROWS AS PRICE
//! FALLS, and price floors at zero, so that liability is bounded at 100% of
//! notional and is fundable with cash. Buying paper against a net-short book
//! makes the exposure worse, not better. `issue_paper` enforces the direction.

use anchor_lang::prelude::*;
use anchor_spl::token_interface::{
    self, Mint, TokenAccount, TokenInterface, TransferChecked,
};

use crate::entra::{ProgramConfig, to_accounting};
use crate::etc::{deliverable_mint, PithyQuip, TickerRisk};
use crate::stay::{Depository, Depositor};

/// Backed's stated floor on a primary-market order, in accounting dollars.
///
/// ⚠️ MEASURED FROM THE LIVE PUBLIC API, NOT FROM THE DOCS. 712 of Backed's 715
/// assets carry `minOrderFiatValue: 1000` (one at 100, one at 500). The
/// `TICKET = 100_000` constant in `facility_sim` cites "Backed's primary mint
/// minimum is $100k" and is wrong by 100x; it is a sim constant and is left
/// alone here rather than silently reconciled, because changing it moves
/// measured results.
pub const MIN_ORDER_DOLLARS: u64 = 1_000_000_000; // $1,000 at 1e6

/// Per-ticker delivery wiring: where Backed's sweeping addresses are, what is
/// in flight, and what this product's order bounds are.
///
/// Seeded on the ticker rather than folded into `TickerRisk` so that enabling
/// delivery for a name never reallocs a live risk account.
#[account]
#[derive(InitSpace)]
pub struct TickerDelivery {
    pub ticker: [u8; 8],
    pub bump: u8,

    /// Backed's product-specific issuance sweeping address — a token account
    /// that accepts USDC/USDG and mints xStocks against it.
    ///
    /// ⚠️ SOURCED FROM AN AUTHENTICATED ENDPOINT, SO IT IS ADMIN-SET, NOT
    /// DERIVED. Nothing on-chain can prove this address is Backed's; the
    /// multisig asserting it is the whole of the guarantee. That is why
    /// `set_delivery` is admin-gated and why `issue_paper` refuses a zeroed
    /// address rather than treating "unset" as "send anywhere".
    pub issuance: Pubkey,
    /// Backed's redemption sweeping address — accepts `xstock_mint`.
    pub redemption: Pubkey,
    /// The xStock SPL mint, cross-checked against `XSTOCK_MINTS` on set.
    pub xstock_mint: Pubkey,

    /// Dollars sent to `issuance` whose paper has not yet landed.
    /// Solvency must count these: they have left the vault and bought nothing
    /// the pool can yet see.
    pub pending_issue: u64,
    /// Raw xStock units sent to `redemption` whose dollars have not landed.
    pub pending_redeem: u64,

    /// Raw xStock units the pool believes it holds, as of the last settle.
    /// The delta against the ATA's real balance is what `settle_issue` credits.
    pub held_raw: u64,

    /// Per-order bounds in accounting dollars, mirroring Backed's
    /// `limitsPerPeriod.market`. `max_order` of 0 means delivery is halted for
    /// this product — which is also how Backed reports a closed market
    /// (`maxOrderFiatValue: 0` in the `closed` period for 714 of 715 assets).
    pub min_order: u64,
    pub max_order: u64,

    pub last_flow: i64,
}

impl TickerDelivery {
    pub const SEED: &'static [u8] = b"deliver";
}

/// Admin wiring. Separate from `update_config` because it is per-ticker and
/// `ProgramConfig` is a single account — 464 deliverable names cannot live in
/// one config, and `update_config` is documented as THE ONLY config
/// instruction for the pool-wide settings, which these are not.
#[derive(Accounts)]
#[instruction(ticker: String)]
pub struct SetDelivery<'info> {
    #[account(mut, address = config.admin @ PithyQuip::Unauthorized)]
    pub admin: Signer<'info>,

    #[account(seeds = [b"program_config"], bump = config.bump)]
    pub config: Box<Account<'info, ProgramConfig>>,

    #[account(init_if_needed, payer = admin,
        space = 8 + TickerDelivery::INIT_SPACE,
        seeds = [TickerDelivery::SEED, ticker.as_bytes()], bump)]
    pub delivery: Box<Account<'info, TickerDelivery>>,

    pub system_program: Program<'info, System>,
}

pub fn set_delivery(ctx: Context<SetDelivery>, ticker: String,
    issuance: Pubkey, redemption: Pubkey, xstock_mint: Pubkey,
    min_order: u64, max_order: u64) -> Result<()> {
    // The mint is not taken on the admin's word: it has to be the one this
    // build ships for that ticker. A delivery account pointing at a mint the
    // program cannot price is a position nobody can value.
    let expect = deliverable_mint(ticker.as_str())
        .ok_or(PithyQuip::NotDeliverable)?;
    require!(xstock_mint.to_string() == expect, PithyQuip::InvalidMint);
    require!(issuance != Pubkey::default()
          && redemption != Pubkey::default(), PithyQuip::InvalidParameters);
    // A floor below Backed's own refuses at their end after we have already
    // moved the money, so it is checked here instead.
    require!(min_order >= MIN_ORDER_DOLLARS, PithyQuip::InvalidParameters);
    require!(max_order >= min_order || max_order == 0, PithyQuip::InvalidParameters);

    let d = &mut ctx.accounts.delivery;
    d.ticker = Depositor::pad_ticker(ticker.as_str());
    d.bump = ctx.bumps.delivery;
    d.issuance = issuance;
    d.redemption = redemption;
    d.xstock_mint = xstock_mint;
    d.min_order = min_order;
    d.max_order = max_order;
    Ok(())
}

#[derive(Accounts)]
#[instruction(ticker: String)]
pub struct MarketFlow<'info> {
    /// Permissioned: moving pool dollars to an off-protocol address is not a
    /// crank. `flash_authority` is deliberately NOT reused — that gate is
    /// documented as venue-agnostic and satisfiable by a plain keypair.
    #[account(mut, address = config.admin @ PithyQuip::Unauthorized)]
    pub authority: Signer<'info>,

    #[account(seeds = [b"program_config"], bump = config.bump)]
    pub config: Box<Account<'info, ProgramConfig>>,

    #[account(mut, seeds = [b"depository"], bump)]
    pub bank: Box<Account<'info, Depository>>,

    #[account(mut, seeds = [TickerDelivery::SEED, ticker.as_bytes()],
        bump = delivery.bump)]
    pub delivery: Box<Account<'info, TickerDelivery>>,

    #[account(seeds = [b"risk", ticker.as_bytes()], bump = ticker_risk.bump)]
    pub ticker_risk: Box<Account<'info, TickerRisk>>,

    /// The stablecoin leaving the pool, or arriving back.
    #[account(constraint = config.registered_mints.contains(&stable_mint.key())
        @ PithyQuip::InvalidMint)]
    pub stable_mint: Box<InterfaceAccount<'info, Mint>>,

    #[account(mut, seeds = [b"vault", stable_mint.key().as_ref()], bump)]
    pub stable_vault: Box<InterfaceAccount<'info, TokenAccount>>,

    /// Backed's sweeping address for this leg. Checked against the delivery
    /// account in the handler, because which one is correct depends on
    /// direction and Anchor cannot express that in a constraint here.
    /// CHECK: validated against `delivery.issuance` / `delivery.redemption`.
    #[account(mut)]
    pub sweep_destination: AccountInfo<'info>,

    pub token_program: Interface<'info, TokenInterface>,
}

/// Send dollars to Backed's issuance address. Paper arrives later.
pub fn issue_paper(ctx: Context<MarketFlow>, _ticker: String,
    amount: u64) -> Result<()> {
    let d = &ctx.accounts.delivery;
    require!(d.issuance != Pubkey::default(), PithyQuip::InvalidParameters);
    require_keys_eq!(ctx.accounts.sweep_destination.key(), d.issuance,
        PithyQuip::InvalidParameters);

    // 🔴 DIRECTION IS THE POINT, NOT A SANITY CHECK. Paper funds an unbounded
    // upside on a net-long book. Against a net-short book the pool's liability
    // grows as price FALLS, so buying the asset deepens the loss it is meant
    // to fund — and that liability is bounded at a total loss anyway, which
    // cash covers. Refusing here is what keeps the two cases from being
    // treated as one because the barrier happens to be symmetric.
    let net = ctx.accounts.ticker_risk.actuary.get_net();
    require!(net > 0, PithyQuip::WrongDirection);

    // Backed refuses outside its own bounds AFTER the transfer lands, so the
    // bounds are enforced before it leaves. `max_order == 0` is how a halted
    // product and a closed market both present.
    require!(amount >= d.min_order, PithyQuip::BelowMinimumTicket);
    require!(d.max_order > 0, PithyQuip::DeliveryHalted);
    require!(amount <= d.max_order, PithyQuip::AboveMaximumTicket);

    // Never send more paper-dollars than the net exposure being funded.
    // Over-buying converts a hedge into a directional position of our own.
    let net_dollars = to_accounting(net.unsigned_abs(),
        ctx.accounts.stable_mint.decimals).unwrap_or(u64::MAX);
    let outstanding = d.pending_issue.saturating_add(amount);
    require!(outstanding <= net_dollars, PithyQuip::ExceedsNetExposure);

    let mint_key = ctx.accounts.stable_mint.key();
    let decimals = ctx.accounts.stable_mint.decimals;
    let raw = crate::entra::from_accounting(amount, decimals)?;
    let (_, vault_bump) = Pubkey::find_program_address(
        &[b"vault", mint_key.as_ref()], ctx.program_id);

    token_interface::transfer_checked(
        CpiContext::new_with_signer(
            ctx.accounts.token_program.to_account_info(),
            TransferChecked {
                from: ctx.accounts.stable_vault.to_account_info(),
                mint: ctx.accounts.stable_mint.to_account_info(),
                to: ctx.accounts.sweep_destination.to_account_info(),
                authority: ctx.accounts.stable_vault.to_account_info(),
            },
            &[&[b"vault", mint_key.as_ref(), &[vault_bump]]],
        ), raw, decimals)?;

    let now = Clock::get()?.unix_timestamp;
    let d = &mut ctx.accounts.delivery;
    d.pending_issue = d.pending_issue.saturating_add(amount);
    d.last_flow = now;

    // The dollars are gone and the paper is not here. Anything reading
    // `total_deposits` between now and settlement is reading a pool that is
    // short this much backing, so it is recorded rather than inferred.
    let bank = &mut ctx.accounts.bank;
    bank.total_deposits = bank.total_deposits.saturating_sub(amount);
    Ok(())
}

/// Credit paper that has arrived, clearing the matching `pending_issue`.
///
/// Permissionless, and deliberately so: it can only move the pool's own
/// recorded holding TOWARD what the chain already says the ATA contains, so a
/// caller cannot use it to conjure backing. This is the same argument that
/// makes `sweep` permissionless.
#[derive(Accounts)]
#[instruction(ticker: String)]
pub struct SettleIssue<'info> {
    pub cranker: Signer<'info>,

    #[account(mut, seeds = [b"depository"], bump)]
    pub bank: Box<Account<'info, Depository>>,

    #[account(mut, seeds = [TickerDelivery::SEED, ticker.as_bytes()],
        bump = delivery.bump)]
    pub delivery: Box<Account<'info, TickerDelivery>>,

    #[account(address = delivery.xstock_mint @ PithyQuip::InvalidMint)]
    pub xstock_mint: Box<InterfaceAccount<'info, Mint>>,

    /// The pool's own xStock holding.
    #[account(seeds = [b"paper", xstock_mint.key().as_ref()], bump)]
    pub paper_vault: Box<InterfaceAccount<'info, TokenAccount>>,
}

pub fn settle_issue(ctx: Context<SettleIssue>, _ticker: String) -> Result<()> {
    let observed = ctx.accounts.paper_vault.amount;
    let d = &mut ctx.accounts.delivery;

    // Only an INCREASE is settlement. A decrease means something moved paper
    // out by another path, and silently rebasing `held_raw` down to match
    // would erase the evidence.
    let arrived = observed.saturating_sub(d.held_raw);
    require!(arrived > 0, PithyQuip::NothingToSettle);
    d.held_raw = observed;

    // ⚠️ `arrived` IS A RAW TOKEN AMOUNT AND IS NOT A SHARE COUNT. xStocks on
    // Solana are SPL Token-2022 with the Scaled UI extension: the raw balance
    // stays constant across dividends and splits and the MULTIPLIER moves, so
    // shares = raw x multiplier. Valuing `held_raw` directly is correct only
    // while the multiplier is 1. Reading the extension is the missing piece;
    // until it exists this account is delivery accounting, not a mark.
    //
    // Nothing here converts `arrived` into dollars for exactly that reason —
    // `pending_issue` is cleared by the dollars that LEFT, not by a valuation
    // of what came back.
    d.pending_issue = 0;
    d.last_flow = Clock::get()?.unix_timestamp;
    Ok(())
}
