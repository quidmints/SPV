
use anchor_lang::prelude::*;

pub mod stay;

pub mod entra;
use entra::*;

pub mod clutch;
use clutch::*;

pub mod etc;

#[cfg(test)]
mod returns;
#[cfg(test)]
mod facility_sim;
#[cfg(test)]
mod facility_sim_report;

/// The ticker tables ship trimmed to what can actually be delivered. The full
/// set is four times the binary and roughly four times the rent to deploy, and
/// a ticker nobody can settle against is not worth either; `all-tickers`
/// builds it for tests that want the whole surface. Widening what is *live*
/// is a program upgrade, which is the multisig's decision to make.
use etc::*;


pub mod LZ;
use LZ::*;

declare_id!("QDgHUZjtccRjKZ63MBvW8uzKR7qcqjpRfGhNSEGfDu9");

#[program]
pub mod quid {
    use super::*;
    /// Deposit. Two legs, one entrypoint: pass `mint` + `quid` for an SPL
    /// deposit, or `sol_pool` with ticker "SOL" for native lamports. Exactly
    /// one leg must be supplied.
    pub fn deposit<'info>(ctx: Context<'_, '_, 'info, 'info, Stockup<'info>>,
        amount: u64, ticker: String) -> Result<()> { entra::handle_in(ctx, amount, ticker) }
    // if you're obtaining short leverage, flip the signs respectively for amount; otherwise (long):
    // positive amount = increase exposure; negative = withdraw QUID (or) redeem exposure for QUID

    pub fn withdraw<'info>(ctx: Context<'_, '_,
        'info, 'info, Withdraw<'info>>, amount: i64, ticker: String, exposure: bool,
        max_haircut_bps: u16) -> Result<()> {
        // `max_haircut_bps` — the caller's ceiling on a forced Kestrel unpark. 0 = never
        // unpark; make the withdrawal WAIT for the buffer rather than paying ~0.4% nobody
        // asked for. Ignored entirely when the withdrawal fits in the hot buffer.
        clutch::handle_out(ctx, amount, ticker, exposure, max_haircut_bps) // no ticker = withdraw collateral from all positions;
        // at least one Pyth key must be passed into remaining_accounts (all keys if empty string ticker)
    } // this sort of cross-margining is also re-used in the liquidation process (a means of protection)
    // as such, need to pass in all Pyth keys into liquidate (first one should be the one to liquidate)
    pub fn liquidate(ctx: Context<Liquidate>, ticker: String) -> Result<()> { // amorè ties unsurmised
        clutch::amortise(ctx, ticker) // "when grace is close to home
        // shadows turn to grey...a slave for four days,
        // cowered beyond reckless tracks of impulse...
        // made to stay.rs around rough collars"
    }

    pub fn init_config(ctx: Context<InitConfig>,
        token_mint: Pubkey) -> Result<()> {
        entra::init_config(ctx, token_mint)
    }

    /// THE ONLY CONFIG INSTRUCTION. Rotate the admin, the flash authority, or the
    /// SOL*/Kestrel parking settings.
    /// `None` leaves a field unchanged. `set_kestrel` was folded in here — it was
    /// a second entrypoint onto this same `ProgramConfig`, with its own accounts
    /// struct and its own spelling of the admin gate.
    pub fn update_config(ctx: Context<UpdateConfig>,
        new_admin: Option<Pubkey>,
        set_flash_authority: Option<Pubkey>,
        kestrel: Option<KestrelCfg>) -> Result<()> {
        entra::update_config(ctx, new_admin, set_flash_authority, kestrel)
    }


    pub fn flash_borrow<'info>(ctx: Context<'_, '_, '_, 'info, FlashBorrow<'info>>,
        lamports: u64, token_amount: u64, vault_bump: u8) -> Result<()> {
        entra::handle_flash_borrow(ctx, lamports, token_amount, vault_bump)
    }

    pub fn flash_repay<'info>(ctx: Context<'_, '_, '_, 'info, FlashRepay<'info>>,
        tip_lamports: u64, tip_token_amount: u64, vault_bump: u8) -> Result<()> {
        clutch::handle_flash_repay(ctx, tip_lamports, tip_token_amount, vault_bump)
    }

    /// Permissionless batch amortisation. Supply the Pyth account for `ticker`
    /// then any number of Depositor PDAs; healthy or too-fresh positions are
    /// skipped rather than reverting the batch, and the cranker is paid a cut
    /// of what it marks.
    pub fn sweep<'info>(ctx: Context<'_, '_, 'info, 'info, Sweep<'info>>,
        ticker: String) -> Result<()> {
        clutch::handle_sweep(ctx, ticker)
    }

    pub fn refresh_sol_collateral(ctx: Context<RefreshSolCollateral>) -> Result<()> {
        clutch::handle_refresh_sol_collateral(ctx)
    }




    pub fn init_oapp_store(mut ctx: Context<InitOAppStore>,
        params: InitOAppStoreParams) -> Result<()> {
        LZ::init_oapp_store_handler(&mut ctx, &params)
    }

    /// LayerZero receive handler. The only inbound message is the OFT bridge
    /// transfer that mints QD on Solana against supply locked by Basket.sol on
    /// L1 — the maturity is copied across, never issued twice.
    pub fn lz_receive<'info>(ctx: Context<'_, '_, 'info, 'info, LzReceive<'info>>,
        params: LzReceiveParams) -> Result<()> {
        // OFT bridge message: toAddress[32] + amountSD[8], no leading type byte.
        // It is the only message type this OApp accepts.
        require!(params.message.len() == LZ::OFT_BRIDGE_MSG_LEN,
                 PithyQuip::InvalidMessageFormat);

        require!(ctx.remaining_accounts.len() >= 3,
                 PithyQuip::InsufficientAccounts);

        // The peer lives on the store, which Anchor has already verified by
        // seeds — so there is no caller-supplied account to spoof here. The
        // previous shape took a ChainConfig through remaining_accounts and had
        // to prove ownership, discriminator and liveness by hand before it
        // could trust a single field.
        require!(params.src_eid == LZ::ETHEREUM_EID,
                 PithyQuip::InvalidParameters);
        require!(ctx.accounts.store.peer_address == params.sender,
                 PithyQuip::InvalidParameters);

        // Clear the LZ nonce...
        let clear_accounts = vec![
            ctx.accounts.store.to_account_info(),
            ctx.accounts.oapp_registry.to_account_info(),
            ctx.accounts.nonce.to_account_info(),
            ctx.accounts.payload_hash.to_account_info(),
            ctx.accounts.endpoint.to_account_info(),
        ];
        let clear_params = ClearParams {
            receiver: ctx.accounts.store.key(),
            src_eid: params.src_eid,
            sender: params.sender,
            nonce: params.nonce,
            guid: params.guid,
            message: params.message.clone(),
        };
        let seeds: &[&[&[u8]]] = &[&[
            OAPP_STORE_SEED,
            &[ctx.accounts.store.bump],
        ]];
        cpi_clear(LZ::LZ_ENDPOINT_PROGRAM,
            &clear_accounts, seeds, clear_params )?;

        LZ::handle_oft_receive(&ctx.accounts.store.to_account_info(),
            ctx.accounts.store.bump, ctx.accounts.store.mint, &params.message,
            &ctx.remaining_accounts[0], &ctx.remaining_accounts[1],
            &ctx.remaining_accounts[2])
    }

    /// LZ receive types handler — tells LayerZero which accounts
    /// to include for a given incoming message.
    /// Send QD home: burn here, release on Ethereum. The mirror of
    /// `lz_receive`, and permissionless for the same reason it is — a holder
    /// moving their own balance between chains creates nothing.
    ///
    /// `to` is an Ethereum address. The maturity is not a parameter: it is
    /// derived on arrival, so a returning holder cannot name an already-vested
    /// month and shorten their own lock by bridging twice.
    pub fn bridge_home<'info>(ctx: Context<'_, '_, 'info, 'info, BridgeHome<'info>>,
        amount: u64, to: [u8; 20], native_fee: u64) -> Result<()> {
        LZ::bridge_home(ctx, amount, to, native_fee)
    }

    pub fn lz_receive_types(ctx: Context<LzReceiveTypes>,
        params: LzReceiveParams) -> Result<Vec<LzAccount>> {
        lz_receive_types_handler(ctx, &params)
    }
}
