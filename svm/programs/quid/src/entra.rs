use anchor_lang::prelude::*;
use anchor_spl::associated_token::get_associated_token_address;
use anchor_spl::token_interface::{
    self, Mint, TokenAccount,
    TokenInterface, TransferChecked
};
use crate::stay::*;
use crate::state::*;
use crate::LZ::{OAppStore,
        OAPP_STORE_SEED};

use crate::etc::{ get_hex, MAX_LEN, PithyQuip,
    TickerRisk, is_stablecoin_pyth_account,
    SECONDS_PER_HOUR, SECONDS_PER_DAY,
    update_price_accumulator, get_twap_price, get_price_deviation };

#[derive(Accounts)]
#[instruction(amount: u64, ticker: String)]
pub struct Stockup<'info> {
    #[account(mut)]
    pub signer: Signer<'info>,
    pub mint: InterfaceAccount<'info, Mint>,

    #[account(init_if_needed, space = 8 + Depository::INIT_SPACE,
        payer = signer, seeds = [b"depository"], bump)]
    pub bank: Account<'info, Depository>,

    #[account(init_if_needed, token::mint = mint,
        token::authority = program_vault,
        payer = signer, seeds = [b"vault",
        mint.key().as_ref()], bump)]
    pub program_vault: InterfaceAccount<'info, TokenAccount>,

    #[account(init_if_needed, payer = signer,
        space = 8 + Depositor::INIT_SPACE,
        seeds = [signer.key().as_ref()], bump)]
    pub depositor: Account<'info, Depositor>,

    #[account(init_if_needed, payer = signer,
        space = 8 + TickerRisk::INIT_SPACE,
        seeds = [b"risk", ticker.as_bytes()], bump)]
        pub ticker_risk: Option<Account<'info, TickerRisk>>,

    #[account(seeds = [OAPP_STORE_SEED], bump = store.bump)]
    pub store: Account<'info, OAppStore>,

    #[account(mut)]
    pub quid: InterfaceAccount<'info, TokenAccount>,
    pub token_program: Interface<'info, TokenInterface>,
    pub system_program: Program<'info, System>,
}

pub fn handle_in(ctx: Context<Stockup>,
    amount: u64, ticker: String) -> Result<()> {
    // require!(ctx.accounts.store.is_basket_mint(
    // &ctx.accounts.mint.key()), PithyQuip::InvalidMint);
    // TODO uncomment the requires before mainnet deployment
    let ata = get_associated_token_address(
        &ctx.accounts.signer.key(), &ctx.accounts.mint.key());
    require!(amount >= 100_000_000, PithyQuip::InvalidAmount);

    let Banks = &mut ctx.accounts.bank;
    // require_keys_eq!(ctx.accounts.quid.key(),
    //                ata, PithyQuip::ForOhfour);

    let clock = Clock::get()?;
    let right_now = clock.unix_timestamp;
    let customer = &mut ctx.accounts.depositor;
    let transfer_cpi_accounts = TransferChecked {
        from: ctx.accounts.quid.to_account_info(),
        mint: ctx.accounts.mint.to_account_info(),
        to: ctx.accounts.program_vault.to_account_info(),
        authority: ctx.accounts.signer.to_account_info(),
    };
    let decimals = ctx.accounts.mint.decimals;
    let cpi_program = ctx.accounts.token_program.to_account_info();
    let cpi_ctx = CpiContext::new(cpi_program, transfer_cpi_accounts);
    token_interface::transfer_checked(cpi_ctx, amount, decimals)?;

    if customer.owner == Pubkey::default() {
        customer.owner = ctx.accounts.signer.key();
    } else {
        let mut delta = right_now - customer.last_updated;
        customer.deposit_seconds += (customer.deposited_quid
                                    * delta as u64) as u128;

        delta = right_now - Banks.last_updated;
        Banks.total_deposit_seconds += (Banks.total_deposits
                                    * delta as u64) as u128;
    }
    if ticker.is_empty() {
        customer.deposited_quid += amount;
        Banks.total_deposits += amount;
    } else {
        // Deposit collateral to specific
        // ticker position (pledged
        // only, no exposure change)
        let t: &str = ticker.as_str();
        if get_hex(t).is_none() {
            return Err(PithyQuip::UnknownSymbol.into());
        }
        // Initialize TickerRisk PDA if first deposit to ticker
        if let Some(risk) = ctx.accounts.ticker_risk.as_mut() {
            if risk.actuary.last_price == 0 {
                risk.ticker = Depositor::pad_ticker(t);
                risk.bump = ctx.bumps.ticker_risk.unwrap();
            }
        } customer.renege(Some(t),
        amount as i64, None, right_now)?;
    } customer.last_updated = right_now;
    Banks.last_updated = right_now; Ok(())
}

#[derive(Accounts)]
#[instruction(params: OrderParams)]
pub struct PlaceOrder<'info> {
    #[account(mut, seeds = [b"market",
    &market.market_id.to_le_bytes()[..6]],
    bump = market.bump)]
    pub market: Box<Account<'info, Market>>,

    #[account(init_if_needed,
        payer = user, space = Position::SPACE,
        seeds = [b"position", market.key().as_ref(),
        user.key().as_ref(), &[params.side]], bump)]
    pub position: Box<Account<'info, Position>>,

    pub mint: InterfaceAccount<'info, Mint>,

    #[account(mut, seeds = [b"vault",
        mint.key().as_ref()], bump)]
    pub program_vault: InterfaceAccount<'info, TokenAccount>,

    #[account(mut)]
    pub user: Signer<'info>,

    #[account(mut, seeds = [b"depository"], bump)]
    pub bank: Box<Account<'info, Depository>>,

    #[account(init_if_needed, payer = user,
        space = 8 + Depositor::INIT_SPACE,
        seeds = [user.key().as_ref()], bump)]
    pub depositor: Box<Account<'info, Depositor>>,

    #[account(seeds = [OAPP_STORE_SEED], bump = store.bump)]
    pub store: Account<'info, OAppStore>,

    #[account(mut)]
    pub quid: InterfaceAccount<'info, TokenAccount>,
    pub token_program: Interface<'info, TokenInterface>,
    pub system_program: Program<'info, System>,
}

pub fn place_order(ctx: Context<PlaceOrder>,
    params: OrderParams) -> Result<()> {
    // require!(ctx.accounts.store.is_basket_mint(
    // &ctx.accounts.mint.key()), PithyQuip::InvalidMint);
    // TODO uncomment the requires before mainnet deployment
    let market = &mut ctx.accounts.market;
    let position = &mut ctx.accounts.position;
    let depositor = &mut ctx.accounts.depositor;
    let bank = &mut ctx.accounts.bank;

    let side = params.side;
    let clock = Clock::get()?;
    let mut capital = params.capital;
    let right_now = clock.unix_timestamp;
    let commitment_hash = params.commitment_hash;
    require!(!market.resolution_requested &&
             !market.resolution_received, PithyQuip::TradingFrozen);
    require!(capital >= 1000, PithyQuip::OrderTooSmall);

    // No trading after extension - preserves confidence-weighted payout integrity
    require!(market.extensions_count == 0, PithyQuip::TradingClosedAfterExtension);

    // Update TWAP accumulator BEFORE reading price
    update_price_accumulator(market, right_now)?;

    // Check for manipulation - reject if spot deviates too much from TWAP
    let max_deviation_bps = params.max_deviation_bps.unwrap_or(300); // Default 3%
    let deviation = get_price_deviation(market, side, right_now);
    require!(deviation <= max_deviation_bps, PithyQuip::PriceManipulated);

    // Initialize depositor if newly created
    if depositor.owner == Pubkey::default() {
        depositor.owner = ctx.accounts.user.key();
        depositor.last_updated = right_now;
        depositor.deposited_quid = 0;
        depositor.deposit_seconds = 0;
        depositor.balances = Vec::new();
    } else {
        // Update deposit_seconds for existing depositor
        let td = right_now - depositor.last_updated;
        depositor.deposit_seconds += (td as u128) *
        (depositor.deposited_quid as u128);
        depositor.last_updated = right_now;
    }
    let mut proposal_cost = 0;
    let side_exists = (side as usize) < market.sides.len();
    if !side_exists {
        proposal_cost = market.side_proposal_cost;
        require!(proposal_cost > 0, PithyQuip::InvalidSide);
        require!(market.sides.len() < market.max_sides as usize,
                                    PithyQuip::InsufficientSides);

        require!(side == market.sides.len() as u8, PithyQuip::InvalidSide);
        require!(params.side_title.is_some(), PithyQuip::InvalidParameters);

        let side_title = params.side_title.as_ref().unwrap();
        require!(side_title.len() > 0 &&
                side_title.len() <= 100, PithyQuip::InvalidParameters);
        require!(capital > proposal_cost, PithyQuip::OrderTooSmall);
        capital -= proposal_cost;
        market.sides.push(Side {
            title: side_title.clone(),
            address: params.side_beneficiary,
        });
    }
    let total_needed = params.capital;  // Full amount including proposal cost
    let from_depositor = depositor.deposited_quid.min(total_needed);
    let from_cpi = total_needed.saturating_sub(from_depositor);
    // Deduct from depositor's pool balance (funds already in vault)
    if from_depositor > 0 {
        depositor.deposited_quid -= from_depositor;
        // Update bank accounting - these funds are leaving the pool
        let td = right_now - bank.last_updated;
        bank.total_deposit_seconds += (bank.total_deposits as u128) * (td as u128);
        bank.total_deposits -= from_depositor;
        bank.last_updated = right_now;
    }
    if from_cpi > 0 {
        let decimals = ctx.accounts.mint.decimals;
        let transfer_ctx = CpiContext::new(
            ctx.accounts.token_program.to_account_info(),
            TransferChecked {
                from: ctx.accounts.quid.to_account_info(),
                mint: ctx.accounts.mint.to_account_info(),
                to: ctx.accounts.program_vault.to_account_info(),
                authority: ctx.accounts.user.to_account_info(),
            },
        );
        token_interface::transfer_checked(transfer_ctx, from_cpi, decimals)?;
    }
    // Creator fee only - resolution fee is calculated dynamically at resolution time
    // based on final market size (see state.rs calculate_resolution_fee)
    let creator_fee = (capital as u128 * market.creator_fee_bps as u128) / 10_000;
    let net_capital = capital - creator_fee as u64;

    market.liquidity = calculate_adaptive_liquidity(market, clock.unix_timestamp);

    // Use TWAP price for the buy (float throughout, like stay.rs)
    let current_price = get_twap_price(market, side, right_now);
    let tokens_bought = (net_capital as f64 / current_price) as u64;
    let price_fixed = (current_price * 1_000_000.0) as u64;

    require!(tokens_bought > 0, PithyQuip::OrderTooSmall);
    if position.market == Pubkey::default() {
        position.market = market.key();
        position.user = ctx.accounts.user.key();
        position.side = side;
        position.total_capital = 0;
        position.total_tokens = 0;
        position.total_capital_seconds = 0;
        position.entries = Vec::new();
        position.auto_rollover = params.auto_rollover;
        position.commitment_hash = commitment_hash;
        position.revealed = false;
        position.revealed_confidence = 0;
        position.accuracy_percentile = 0;
        position.weight = 0;
        position.payout = 0;
        position.payout_pushed = false;
        position.eth_signer = params.eth_signer;
        position.reveal_delegate = params.reveal_delegate;
        position.bump = ctx.bumps.position;
        market.positions_total += 1;
    }
    require!(position.entries.len() < Position::MAX_ENTRIES,
                                PithyQuip::TooManyEntries);
    position.entries.push(PositionEntry {
        capital: net_capital,
        tokens: tokens_bought,
        price_at_entry: price_fixed,
        timestamp: clock.unix_timestamp,
        capital_seconds: 0,
        last_updated: clock.unix_timestamp,
        commitment_hash, confidence: None,
    });
    position.total_capital += net_capital;
    position.total_tokens += tokens_bought;
    market.tokens_sold_per_side[side as usize] += tokens_bought;
    market.total_capital += net_capital;
    market.total_capital_per_side[side as usize] += net_capital;
    market.fees_collected += creator_fee as u64;
    // resolution_fee_pool is set at resolution request time, not here
    Ok(())
}

#[derive(Accounts)]
#[instruction(params: CreateMarketParams)]
pub struct CreateMarket<'info> {
    #[account(mut)]
    pub authority: Signer<'info>,
    pub mint: InterfaceAccount<'info, Mint>,

    #[account(init_if_needed,
        space = 8 + Depository::INIT_SPACE,
        payer = authority, seeds = [b"depository"],
        bump)] pub bank: Box<Account<'info, Depository>>,

    #[account(init_if_needed,
        token::mint = mint, token::authority = program_vault,
        payer = authority, seeds = [b"vault", mint.key().as_ref()],
        bump)] pub program_vault: InterfaceAccount<'info, TokenAccount>,

    #[account(init, payer = authority, space = Market::SPACE,
      seeds = [b"market", &bank.market_count.to_le_bytes()[..6]],
      bump)] pub market: Box<Account<'info, Market>>,

    #[account(init, payer = authority, space = AccuracyBuckets::SPACE,
      seeds = [b"accuracy_buckets", &bank.market_count.to_le_bytes()[..6]],
      bump)] pub accuracy_buckets: Box<Account<'info, AccuracyBuckets>>,

    // Creator's depositor for using existing balance
    #[account(init_if_needed, payer = authority,
        space = 8 + Depositor::INIT_SPACE,
        seeds = [authority.key().as_ref()], bump)]
    pub depositor: Box<Account<'info, Depositor>>,

    #[account(seeds = [OAPP_STORE_SEED], bump = store.bump)]
    pub store: Account<'info, OAppStore>,

    #[account(mut)]
    pub creator_token_account: InterfaceAccount<'info, TokenAccount>,
    pub token_program: Interface<'info, TokenInterface>,
    pub system_program: Program<'info, System>,
}

pub fn create_market(ctx: Context<CreateMarket>,
    params: CreateMarketParams) -> Result<()> { // TODO uncomment later
    // require!(ctx.accounts.store.is_basket_mint(
    // &ctx.accounts.mint.key()), PithyQuip::InvalidMint);

    let clock = Clock::get()?;
    let bank = &mut ctx.accounts.bank;
    let market = &mut ctx.accounts.market;
    let depositor = &mut ctx.accounts.depositor;
    let right_now = clock.unix_timestamp;
    let question = params.question.clone();
    // What is it you're after?
    // I don't have your answer
    // You can't run forever
    // With me on a tether
    let sides = params.sides.clone();
    let num_sides = sides.len() as u8;
    let resolution_time = params.resolution_time;
    let creator_fee_bps = params.creator_fee_bps;

    let max_sides = if params.max_sides > 0 { params.max_sides }
                    else { num_sides.max(2) };

    let min_sides_for_resolution = if params.min_sides_for_resolution > 0 {
                                        params.min_sides_for_resolution
                                    } else { num_sides };

    require!(max_sides >= 2 && max_sides <= 100, PithyQuip::InvalidParameters);
    require!(min_sides_for_resolution >= 2 && min_sides_for_resolution <= max_sides,
                                                PithyQuip::InvalidParameters);

    require!(params.num_winners < min_sides_for_resolution,
                            PithyQuip::InvalidParameters);
    require!(params.minimum_proceeds >= 2000_000_000,
                            PithyQuip::InvalidMarket);
    require!(question.len() > 0 && question.len() <= 280,
                            PithyQuip::InvalidParameters);

    require!(creator_fee_bps <= 2000,
        PithyQuip::InvalidParameters);
    if params.side_proposal_cost > 0 {
        require!(num_sides <= max_sides, PithyQuip::InvalidParameters);
        if params.resolve_whenever {
            require!(min_sides_for_resolution >= 2, PithyQuip::InvalidParameters);
        }
    } else {
        require!(num_sides >= 2, PithyQuip::InvalidParameters);
        require!(num_sides == max_sides, PithyQuip::InvalidParameters);
    }
    if !params.winning_splits.is_empty() {
        require!(params.winning_splits.len() == params.sides.len(), PithyQuip::SplitCountMismatch);
        let mut total_split = 0u64;
        for (i, split) in params.winning_splits.iter().enumerate() {
            total_split += split;
            require!(params.sides[i].address.is_some(), PithyQuip::MissingBeneficiaryAddress);
        }
        require!(total_split >= 5_000 && total_split <= 10_000, PithyQuip::InvalidSplit);
    }
    let mut duration = 30 * SECONDS_PER_DAY;
    if resolution_time == 0 {
        require!(params.resolve_whenever, PithyQuip::InvalidParameters);
       // Depeg markets: 2 sides, resolve_whenever=true, sides[0].address is stablecoin Pyth
       let is_depeg = max_sides == 2 && params.sides.len() >= 1 && params.sides[0].address
               .map(|addr| is_stablecoin_pyth_account(&addr)).unwrap_or(false);
       // Allow extensions for depeg markets (needed for hung jury recovery)
       // Non-depeg resolve_whenever markets still cannot have extensions
       if !is_depeg {
           require!(!params.allows_extensions, PithyQuip::InvalidParameters);
       }
    } else {
        duration = params.resolution_time - clock.unix_timestamp;
        require!(duration >= 24 * SECONDS_PER_HOUR
              && duration <= 365 * SECONDS_PER_DAY, PithyQuip::InvalidParameters);
    }
    let lambda_f64 = calculate_adaptive_lambda(duration, max_sides as usize);
    let lambda = (lambda_f64 * 100.0).clamp(10.0, 1000.0) as u64;

    const CREATOR_BOND: u64 = 200_000_000;
    require!(params.appeal_cost >= CREATOR_BOND, PithyQuip::InvalidParameters);
    require!(params.initial_liquidity >= CREATOR_BOND, PithyQuip::InvalidParameters);

    // Initialize depositor if newly created
    if depositor.owner == Pubkey::default() {
        depositor.owner = ctx.accounts.authority.key();
        depositor.last_updated = right_now;
        depositor.deposited_quid = 0;
        depositor.deposit_seconds = 0;
        depositor.balances = Vec::new();
    } else {
        // Update deposit_seconds for existing depositor
        let td = right_now - depositor.last_updated;
        depositor.deposit_seconds += (td as u128) *
        (depositor.deposited_quid as u128);
        depositor.last_updated = right_now;
    }
    let total_needed = params.initial_liquidity;
    let from_depositor = depositor.deposited_quid.min(total_needed);
    let from_cpi = total_needed.saturating_sub(from_depositor);
    if from_depositor > 0 {
        depositor.deposited_quid -= from_depositor;
        // Update bank accounting - these funds are leaving the pool
        // Deduct from depositor's pool balance (funds already in vault)
        let td = right_now - bank.last_updated;
        bank.total_deposit_seconds += (bank.total_deposits as u128) * (td as u128);
        bank.total_deposits -= from_depositor;
        bank.last_updated = right_now;
    }
    if from_cpi > 0 { // CPI transfer for any remainder
        let decimals = ctx.accounts.mint.decimals;
        let transfer_ctx = CpiContext::new(
            ctx.accounts.token_program.to_account_info(),
            TransferChecked {
                from: ctx.accounts.creator_token_account.to_account_info(),
                mint: ctx.accounts.mint.to_account_info(),
                to: ctx.accounts.program_vault.to_account_info(),
                authority: ctx.accounts.authority.to_account_info(),
            },
        ); token_interface::transfer_checked(
            transfer_ctx, from_cpi, decimals)?;
    }
    let buckets = &mut ctx.accounts.accuracy_buckets;
    buckets.market = market.key();
    buckets.buckets = vec![0u64; AccuracyBuckets::NUM_BUCKETS];
    buckets.bump = ctx.bumps.accuracy_buckets;
    market.market_id = bank.market_count;
    market.creator = ctx.accounts.authority.key();
    market.creator_bond = params.initial_liquidity;
    market.question = question;
    market.num_sides = max_sides;
    market.num_winners = params.num_winners;
    market.sides = sides;
    market.start_time = clock.unix_timestamp;
    market.resolution_time = resolution_time;
    market.side_proposal_cost = params.side_proposal_cost;
    market.min_sides_for_resolution = min_sides_for_resolution;
    market.max_sides = max_sides;
    market.requires_app_signature = params.requires_app_signature;
    market.tokens_sold_per_side = vec![0u64; max_sides as usize];
    market.total_capital = 0;
    market.total_capital_per_side = vec![0u64; max_sides as usize];
    market.confidence_sum_per_side = vec![0u128; max_sides as usize];
    market.fees_collected = 0;
    market.resolution_received = false;
    market.minimum_proceeds = params.minimum_proceeds;
    market.resolution_requested = false;
    market.resolution_requested_time = None;
    market.resolution_requester = None;
    market.resolution_finalized = 0;
    market.requires_unanimous = params.requires_unanimous;
    market.resolve_whenever = params.resolve_whenever;
    market.allows_rollovers = params.allows_rollovers;
    market.allows_extensions = params.allows_extensions;
    market.extensions_count = 0;
    market.appeal_cost = params.appeal_cost;
    market.winning_splits = params.winning_splits;
    market.winning_sides = Vec::new();
    market.force_majeure = false;
    market.positions_revealed = 0;
    market.positions_total = 0;
    market.total_winner_weight_revealed = 0;
    market.total_loser_weight_revealed = 0;
    market.total_winner_capital_revealed = 0;
    market.total_loser_capital_revealed = 0;
    market.weights_complete = false;
    market.payouts_complete = false;
    market.creator_fee_bps = creator_fee_bps;
    market.resolution_fee_pool = 0;
    market.time_decay_lambda = lambda;
    market.liquidity = params.initial_liquidity;
    // Initialize TWAP accumulator fields
    market.price_cumulative_per_side = vec![0u128; max_sides as usize];
    market.price_checkpoint_per_side = vec![0u128; max_sides as usize];
    market.last_price_update = right_now;
    market.checkpoint_timestamp = right_now;
    market.bump = ctx.bumps.market;
    bank.market_count += 1;
    Ok(())
}
