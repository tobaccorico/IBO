
use anchor_spl::associated_token::AssociatedToken;
use anchor_spl::token_interface::{ self, Mint,
    TokenAccount, TokenInterface, TransferChecked
};
use crate::state::transfer_from_vaults;
use crate::LZ::{OAppStore, OAPP_STORE_SEED};
use crate::etc::{ get_account,
    get_asset_class, PithyQuip,
    fetch_multiple_prices,
    fetch_price, TickerRisk,
fee_bps }; use crate::stay::*;
use anchor_lang::prelude::*;

#[derive(Accounts)]
#[instruction(ticker: String)]
pub struct Liquidate<'info> {
    /// CHECK: raw account only to validate ownership
    pub liquidating: AccountInfo<'info>,

    #[account(mut)]
    pub liquidator: Signer<'info>,
    pub mint: InterfaceAccount<'info, Mint>,

    #[account(mut, seeds = [b"depository"], bump)]
    pub bank: Account<'info, Depository>,

    #[account(mut, seeds = [b"vault", mint.key().as_ref()], bump)]
    pub bank_token_account: InterfaceAccount<'info, TokenAccount>,

    #[account(mut, seeds = [liquidating.key().as_ref()], bump)]
    pub customer_account: Account<'info, Depositor>,

    #[account(init_if_needed, payer = liquidator,
        space = 8 + Depositor::INIT_SPACE,
        seeds = [liquidator.key().as_ref()], bump)]
    pub liquidator_depositor: Account<'info, Depositor>,

    #[account(mut, seeds = [b"risk",
    ticker.as_bytes()], bump = ticker_risk.bump)]
    pub ticker_risk: Account<'info, TickerRisk>,

    #[account(seeds = [OAPP_STORE_SEED], bump = store.bump)]
    pub store: Account<'info, OAppStore>,

    pub token_program: Interface<'info, TokenInterface>,
    pub associated_token_program: Program<'info, AssociatedToken>,
    pub system_program: Program<'info, System>,
}

// "It's like inch by inch...step by step...closin' in on your position
//  in small doses...when things have gotten closer to the sun," she said,
// "don't think I'm pushing you away as âš¡ï¸ strikes...court lights get dim"
pub fn amortise(ctx: Context<Liquidate>, ticker: String) -> Result<()> {
    // require!(ctx.accounts.store.is_basket_mint(&ctx.accounts.mint.key()), PithyQuip::InvalidMint);
    // TODO uncomment before deployment
    let Banks = &mut ctx.accounts.bank;
    // "Me and my money attached emotionally
    // I get to clutchin' if you get too close to me"
    let customer = &mut ctx.accounts.customer_account;
    let risk = &mut ctx.accounts.ticker_risk;
    require_keys_eq!(customer.owner,
        ctx.accounts.liquidating.key(),
        PithyQuip::InvalidUser);

    let clock = Clock::get()?;
    let slot = clock.slot as i64;
    let t: &str = ticker.as_str();
    let asset_class = get_asset_class(t);
    let right_now = clock.unix_timestamp;

    let key: &str = get_account(t).ok_or(PithyQuip::UnknownSymbol)?;
    let first = ctx.remaining_accounts.first().ok_or(PithyQuip::NoPrice)?;
    let first_key = first.key.to_string();
    if first_key != key {
        return Err(PithyQuip::UnknownSymbol.into());
    }
    let adjusted_price = fetch_price(t, Some(first))?;
    risk.actuary.update_price(adjusted_price as i64,
                                slot, asset_class);

    risk.actuary.check_twap_deviation(adjusted_price as i64)?;
    let mut time_delta = right_now - customer.last_updated;
    customer.deposit_seconds += (customer.deposited_quid as u128)
                                           * (time_delta as u128);

    time_delta = right_now - Banks.last_updated;
    Banks.total_deposit_seconds += (Banks.total_deposits as u128)
                                           * (time_delta as u128);
    Banks.last_updated = right_now;
    let (mut delta, mut interest) = customer.repo(t, 0, adjusted_price,
                        right_now, &risk.actuary, Banks, asset_class)?;

    require!(delta != 0, PithyQuip::NotUndercollateralised);
    Banks.total_deposits += interest;

    interest = (delta.abs() as u64 / 250) as u64;
    let pos = customer.balances.iter().find(|p|
        std::str::from_utf8(&p.ticker).unwrap()
                  .trim_end_matches('\0') == t);

    let (prior_exposure, leverage) = if let Some(p) = pos {
        let l = if p.pledged > 0 {
            ((p.exposure.abs() as u128) *
               (adjusted_price as u128) * 100 /
                    (p.pledged as u128)) as i64
        } else { 100 };
        (p.exposure, l)
    } else { (0, 100) };
    if delta < 0 { delta *= -1;
        delta -= interest as i64;
        // ^ pay liquidator's commission...
         // Take profit on behalf of all the
         // depositors, at the expense of one
        Banks.total_deposits += delta as u64;
        risk.actuary.record_activity(prior_exposure, -delta,
        leverage, slot, delta, Banks.total_deposits as i64);
    } else if delta > 0 {
        // Position was saved from liquidation
        // before we try to deduct from depository
        // attempt to salvage amount from depositor
        let prices = fetch_multiple_prices(&customer.balances,
                                    ctx.remaining_accounts)?;

        let remainder = customer.renege(None, -delta as i64,
                          Some(&prices), right_now)? as i64;
        customer.deposited_quid += (delta - remainder) as u64;

        Banks.total_deposits -= remainder as u64;
        risk.actuary.record_activity(prior_exposure, delta,
        leverage, slot, delta, Banks.total_deposits as i64);
    }
    let liquidator_dep = &mut ctx.accounts.liquidator_depositor;
    if liquidator_dep.owner == Pubkey::default() {
        liquidator_dep.owner = ctx.accounts.liquidator.key();
        liquidator_dep.last_updated = right_now;
    } else { // Update deposit_seconds before adding comission funds
        let liq_time_delta = right_now - liquidator_dep.last_updated;
        liquidator_dep.deposit_seconds += (liquidator_dep.deposited_quid as u128)
                                                       * (liq_time_delta as u128);
        liquidator_dep.last_updated = right_now;
    }   liquidator_dep.deposited_quid += interest;
    Ok(())
}

// withdrawing is either what we liquidate (TP),
// or minting what is liable to get liquidated

#[derive(Accounts)]
#[instruction(amount: i64, ticker: String, exposure: bool)]
pub struct Withdraw<'info> {
    #[account(mut)]
    pub signer: Signer<'info>,
    pub mint: InterfaceAccount<'info, Mint>,

    #[account(mut, seeds = [b"depository"], bump)]
    pub bank: Account<'info, Depository>,

    #[account(mut, seeds = [b"vault", mint.key().as_ref()], bump)]
    pub bank_token_account: InterfaceAccount<'info, TokenAccount>,

    #[account(mut, seeds = [signer.key().as_ref()], bump)]
    pub customer_account: Account<'info, Depositor>,

    #[account(mut, associated_token::mint = mint, associated_token::authority = signer,
        associated_token::token_program = token_program,
        constraint = customer_token_account.owner == signer.key()
    )]
    pub customer_token_account: InterfaceAccount<'info, TokenAccount>,

    #[account(mut, seeds = [b"risk", ticker.as_bytes()], bump = ticker_risk.bump)]
    pub ticker_risk: Option<Account<'info, TickerRisk>>,

    #[account(seeds = [OAPP_STORE_SEED], bump = store.bump)]
    pub store: Account<'info, OAppStore>,

    pub token_program: Interface<'info, TokenInterface>,
    pub associated_token_program: Program<'info, AssociatedToken>,
    pub system_program: Program<'info, System>,
}

pub fn handle_out<'info>(ctx: Context<'_, '_, 'info, 'info, Withdraw<'info>>, mut amount: i64,
    ticker: String, exposure: bool) -> Result<()> {
    require!(amount != 0, PithyQuip::InvalidAmount); // TODO uncomment for deployment
    // require!(ctx.accounts.store.is_basket_mint(
    //     &ctx.accounts.mint.key()),
    //     PithyQuip::InvalidMint);

    let Banks = &mut ctx.accounts.bank;
    let customer = &mut ctx.accounts.customer_account;
    require_keys_eq!(customer.owner,
        ctx.accounts.signer.key(),
        PithyQuip::InvalidUser);

    let clock = Clock::get()?;
    let slot = clock.slot as i64;
    let right_now = clock.unix_timestamp;

    // time-weighted metrics for interest rate calculation
    let mut time_delta = right_now - Banks.last_updated;
    Banks.total_deposit_seconds += (time_delta as u128) *
    (Banks.total_deposits as u128);
    Banks.last_updated = right_now;
    let mut amt: u64 = 0;
    if ticker.is_empty() { // withdrawal of $ deposits...
        // returns your pro-rata share of the pool, plus your
        // accrued yield, net of any losses for honoring TPs
        require!(amount < 0, PithyQuip::InvalidAmount);
        if exposure { // first empty credit accounts,
        // prior to withdrawing from Depository...
            let prices = fetch_multiple_prices(&customer.balances,
                ctx.remaining_accounts)?; amt = amount.abs() as u64;
            // amount gets passed into renege as a negative number,
            // but if a remainder is returned it will be positive
            amount = customer.renege(None, amount as i64,
                       Some(&prices), right_now)? as i64;

            amt -= amount as u64;
            // used to keep track of how much we know
            // (so far) that we'll be transferring...
        } // whether we entered exposure's if clause or not (amount gets reused in there)
        if amount.abs() > 0 { // if there's a remainder (returned by renege), or otherwise:
            time_delta = right_now - customer.last_updated;
            customer.deposit_seconds += (time_delta as u128) * (customer.deposited_quid as u128);

            let max_value = customer.deposit_seconds.saturating_mul(Banks.total_deposits as u128)
                .checked_div(Banks.total_deposit_seconds).unwrap_or(0).min(u64::MAX as u128) as u64;

            let value = max_value.min(amount.abs() as u64);
            amt += value; Banks.total_deposits -= value;

            let old_deposited = customer.deposited_quid;
            customer.deposited_quid -= customer.deposited_quid.min(value);

            if old_deposited > 0 && value > 0 {
                customer.adjust_deposit_seconds(value, right_now);
            }
            customer.last_updated = right_now;
        }
        let pyth_accounts_count = customer.balances.len().max(1);
        let vault_accounts = if ctx.remaining_accounts.len() > pyth_accounts_count {
                               &ctx.remaining_accounts[pyth_accounts_count..]} else { &[] };

        let actual_transferred = transfer_from_vaults(&ctx.accounts.bank_token_account,
            &ctx.accounts.mint, &ctx.accounts.customer_token_account,
            ctx.bumps.bank_token_account, vault_accounts,
            &ctx.accounts.token_program, ctx.program_id,
            &ctx.accounts.store.registered_mints, amt)?;
    } else { // < ticker was not ""
        let t: &str = ticker.as_str();
        let asset_class = get_asset_class(t);
        if !exposure { // < withdraw pledged from specific ticker (no exposure change)
            require!(amount < 0, PithyQuip::InvalidAmount);
            customer.renege(Some(t), amount, None, right_now)?;
            let asset_class = get_asset_class(t);
            let vault_accounts = if ctx.remaining_accounts.len() > 1 {
                                   &ctx.remaining_accounts[1..]} else { &[] };

            let actual_transferred = transfer_from_vaults(&ctx.accounts.bank_token_account,
                &ctx.accounts.mint, &ctx.accounts.customer_token_account,
                ctx.bumps.bank_token_account, vault_accounts,
                &ctx.accounts.token_program, ctx.program_id,
                &ctx.accounts.store.registered_mints,
                -amount as u64,
            )?;
        } else {
            let risk = ctx.accounts.ticker_risk.as_mut().ok_or(PithyQuip::UnknownSymbol)?;
            let key: &str = get_account(t).ok_or(PithyQuip::UnknownSymbol)?;
            let first: &AccountInfo = &ctx.remaining_accounts[0];
            let first_key = first.key.to_string();
            if first_key != key {
                return Err(PithyQuip::UnknownSymbol.into());
            }
            let adjusted_price = fetch_price(t, Some(first))?;
            risk.actuary.update_price(adjusted_price as i64, slot, asset_class);
            risk.actuary.check_twap_deviation(adjusted_price as i64)?;
            let pos = customer.balances.iter().find(|p|
                std::str::from_utf8(&p.ticker).unwrap()
                .trim_end_matches('\0') == t)
                .ok_or(PithyQuip::DepositFirst)?;

            let prior_exposure = pos.exposure;
            let leverage = if pos.pledged > 0 { (pos.exposure.abs() as u64
                              * adjusted_price * 100 / pos.pledged) as i64
            } else { 100 };
            let fee = fee_bps(Banks.concentration(), prior_exposure,
                            amount, &risk.actuary, leverage, asset_class);

            let (mut delta, mut interest) = customer.repo(t, amount,
            adjusted_price, right_now, &risk.actuary, Banks, asset_class)?;

            if delta != 0 { // Take Profit:
                if delta < 0 { delta *= -1; // // < first, remove control flow meaning
                    let fee_amount = (interest as u128 * fee as u128 / 10_000) as u64;
                    let payout = interest.saturating_sub(fee_amount);
                    let vault_accounts = if ctx.remaining_accounts.len() > 1 {
                                           &ctx.remaining_accounts[1..]} else { &[] };

                    let actual_transferred = transfer_from_vaults(&ctx.accounts.bank_token_account,
                        &ctx.accounts.mint, &ctx.accounts.customer_token_account,
                        ctx.bumps.bank_token_account, vault_accounts,
                        &ctx.accounts.token_program, ctx.program_id,
                        &ctx.accounts.store.registered_mints, payout,
                    )?;
                    // interest includes (partially) the pod.pledged
                    // (delta was obtained from total_deposits)...
                    Banks.total_deposits += fee_amount as u64; interest = 0;
                    // so we don't add it back to the total_deposits later ^
                } else { // was auto-protected against liquidation
                    time_delta = right_now - customer.last_updated;
                    customer.deposit_seconds += (time_delta as u128) *
                    ((customer.deposited_quid + delta as u64) as u128);
                    customer.last_updated = right_now;
                } Banks.total_deposits -= delta as u64;
            }     Banks.total_deposits += interest;
            risk.actuary.record_activity(prior_exposure,
                amount, leverage, slot, amount.abs(),
                Banks.total_deposits as i64);
        }
    } Ok(())
}
