use anchor_lang::prelude::*;

pub mod stay;
pub mod etc;
pub mod LZ;
use LZ::*;

pub mod entra;
use entra::*;

pub mod state;
use state::*;

pub mod clutch;
use clutch::*;

pub mod out;
use out::*;
use etc::*;

declare_id!("CpCe1dCqRJ231arzyanw9H2cBeCwCR8LDvALWyNzS5DE");
// declare_id!("2CeNnTZ7Efr6cDLha2LAtKRHTLzBEN11Tk9irQv6UQct"); // vaio

#[program]
pub mod quid {
    use super::*;

    pub fn zai_batsu(ctx: Context<CreateMarket>,
        params: CreateMarketParams) -> Result<()> {
        create_market(ctx, params)
    }

    pub fn bid_up_bediuk(ctx: Context<PlaceOrder>,
        params: OrderParams) -> Result<()> {
        place_order(ctx, params)
    }

    pub fn deposit(ctx: Context<Stockup>, amount: u64,
        ticker: String) -> Result<()> { handle_in(ctx, amount, ticker) }

    // if you're obtaining short leverage, flip the signs respectively for amount; otherwise (long):
    // positive amount = increase exposure; negative = withdraw QUID (or) redeem exposure for QUID
    pub fn withdraw<'info>(ctx: Context<'_, '_, 'info, 'info, Withdraw<'info>>,
                        amount: i64, ticker: String, exposure: bool) -> Result<()> {
        handle_out(ctx, amount, ticker, exposure) // no ticker = withdraw collateral from all positions;
        // at least one Pyth key must be passed into remaining_accounts (all keys if empty string ticker)
    } // this sort of cross-margining is also re-used in the liquidation process (a means of protection)
    // as such, need to pass in all Pyth keys into liquidate (first one should be the one to liquidate)
    pub fn liquidate(ctx: Context<Liquidate>, ticker: String) -> Result<()> { // amorè ties unsurmised
        amortise(ctx, ticker) // "when grace is close to home
        // shadows turn to grey...a slave for four days,
        // cowered beyond reckless tracks of impulse...
        // made to stay around rough collars"
    }

    pub fn sell(ctx: Context<SellPosition>,
        tokens_to_sell: u64, max_deviation_bps: Option<u64>) -> Result<()> {
        sell_position(ctx, tokens_to_sell, max_deviation_bps)
    }

    pub fn reveal<'info>(ctx: Context<'_, '_, '_, 'info,
        BatchReveal<'info>>, reveals: Vec<Vec<RevealEntry>>) -> Result<()> {
                                                batch_reveal(ctx, reveals) }

    pub fn weigh<'info>(ctx: Context<'_, '_, '_, 'info,
        CalculateAllWeights<'info>>) -> Result<()> { rank(ctx) }

    pub fn payout<'info>(ctx: Context<'_, '_, '_, 'info,
        PushPayouts<'info>>) -> Result<()> { push_payouts(ctx) }

    pub fn init_oapp_store(mut ctx: Context<InitOAppStore>,
        params: InitOAppStoreParams) -> Result<()> {
        init_oapp_store_handler(&mut ctx, &params)
    }

    pub fn register_chain(ctx: Context<RegisterChain>,
        params: RegisterChainParams) -> Result<()> {
        register_chain_handler(ctx, params)
    }

    pub fn lz_receive_types(ctx: Context<LzReceiveTypes>,
        params: LzReceiveParams) -> Result<Vec<LzAccount>> {
        lz_receive_types_handler(ctx, &params)
    }

    pub fn resolve(ctx: Context<SendResolutionRequest>) -> Result<()> { send_resolution_request(ctx) }
    pub fn tip(ctx: Context<SendJuryCompensation>) -> Result<()> { send_jury_compensation(ctx) }
    pub fn lz_receive(ctx: Context<LzReceive>, params: LzReceiveParams) -> Result<()> {
        require!(params.message.len() > 0, PithyQuip::InvalidMessageType);
        require!(!ctx.remaining_accounts.is_empty(), PithyQuip::InsufficientAccounts);
        let chain_config_info = &ctx.remaining_accounts[0];
        let chain_data = chain_config_info.try_borrow_data()?;
        let chain_config = ChainConfig::try_deserialize(&mut chain_data.as_ref())
            .map_err(|_| PithyQuip::InvalidPeer)?;
        drop(chain_data);

        require!(chain_config.active, PithyQuip::InvalidPeer);
        require!(chain_config.eid == params.src_eid, PithyQuip::InvalidPeer);
        require!(chain_config.peer_address == params.sender, PithyQuip::UnauthorizedPeer);

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
        let seeds: &[&[&[u8]]] = &[&[OAPP_STORE_SEED, &[ctx.accounts.store.bump]]];
        cpi_clear(ctx.accounts.store.endpoint_program, ctx.accounts.store.key(),
            &clear_accounts, seeds, clear_params)?;

        let msg_type = params.message[0];
        match msg_type {
            FINAL_RULING => {
                let ruling = FinalRuling::decode(&params.message)?;
                let (market_pda, _) = Pubkey::find_program_address(
                    &[b"market", &ruling.market_id.to_le_bytes()[..6]],
                    ctx.program_id,
                );
                // Skip chain_config at [0], market should be at [1]
                let market_info = ctx.remaining_accounts.iter().skip(1)
                    .find(|acc| acc.key() == market_pda)
                    .ok_or(PithyQuip::InvalidMarketAccount)?;

                require!(market_info.owner == ctx.program_id, PithyQuip::InvalidAccountOwner);
                let market_key = market_info.key();
                let mut market_data = market_info.try_borrow_mut_data()?;
                let mut market = Market::try_deserialize(&mut market_data.as_ref())?;

                let clock = Clock::get()?;
                let total_slashed = process_final_ruling(&ruling, &mut market,
                    &market_key, clock.unix_timestamp, &ctx.remaining_accounts[2..],
                    ctx.program_id,
                )?;
                if total_slashed > 0 {
                    market.total_capital = market.total_capital
                        .checked_sub(total_slashed)
                        .ok_or(PithyQuip::Underflow)?;
                    market.resolution_fee_pool = calculate_resolution_fee(market.total_capital)
                                        .checked_add(total_slashed).ok_or(PithyQuip::Overflow)?;
                }
                market.try_serialize(&mut market_data.as_mut())?;
            },
            _ => {
                return Err(PithyQuip::InvalidMessageType.into());
            }
        } Ok(())
    }

    #[cfg(feature = "testing")]
    pub fn test_receive_ruling<'info>(ctx: Context<'_, '_, '_, 'info, TestReceiveRuling<'info>>,
        winning_sides: Vec<u8>, force_majeure: bool, is_extension: bool,
        slashing_addresses: Vec<Pubkey>, slashing_sides: Vec<u8>) -> Result<()> {
        let market_key = ctx.accounts.market.key();
        let market = &mut ctx.accounts.market;
        let clock = Clock::get()?;
        let ruling = if force_majeure {
            FinalRuling::new(market.market_id, Vec::new(),
                                slashing_addresses, slashing_sides)?
        } else if is_extension {
            FinalRuling::new(market.market_id, vec![EXTENSION_MARKER],
                slashing_addresses, slashing_sides)?
        } else {
            FinalRuling::new(market.market_id, winning_sides,
                slashing_addresses, slashing_sides)?
        };
        let total_slashed = process_final_ruling(&ruling,
            &mut **market, &market_key, clock.unix_timestamp,
            ctx.remaining_accounts, ctx.program_id,
        )?;
        if total_slashed > 0 {
            market.total_capital = market.total_capital.checked_sub(total_slashed).ok_or(PithyQuip::Underflow)?;
            market.resolution_fee_pool = market.resolution_fee_pool.checked_add(total_slashed).ok_or(PithyQuip::Overflow)?;
        }
        Ok(())
    }

    #[cfg(feature = "testing")]
    #[derive(Accounts)]
    pub struct TestReceiveRuling<'info> {
        #[account(mut)]
        pub authority: Signer<'info>,

        #[account(mut, seeds = [b"market", &market.market_id.to_le_bytes()[..6]], bump = market.bump)]
        pub market: Account<'info, Market>,
    }
}

/// Slashing mechanics:
/// 1. For frivolous requests/appeals: Slash the requester/appellant
/// 2. For force majeure: Slash the market creator
/// 3. In every other case, bad evidence providers get slashed
/// 3. Slashed funds go to the resolution fee pool to compensate jurors
/// Slash positions for bad actors
/// Returns total amount slashed
pub fn _handle_slashing(market_key: &Pubkey,
    slashing_addresses: &[Pubkey],
    slashing_sides: &[u8],
    position_accounts: &[AccountInfo],
    program_id: &Pubkey) -> Result<u64> {
    let mut total_slashed = 0u64;
    for (i, address) in slashing_addresses.iter().enumerate() {
        let side = slashing_sides[i];
        let (expected_pda, _) = Pubkey::find_program_address(
            &[b"position", market_key.as_ref(), address.as_ref(), &[side]],
            program_id,
        );
        let position_info = position_accounts.iter().find(|acc| acc.key() == expected_pda);
        let Some(position_info) = position_info else { continue; };
        if position_info.owner != program_id { continue; }

        let mut position_data = match position_info.try_borrow_mut_data() {
            Ok(data) => data, Err(_) => continue,
        };
        let mut position = match Position::try_deserialize(&mut position_data.as_ref()) {
            Ok(pos) => pos, Err(_) => continue,
        };
        if position.market != *market_key { continue; }
        let slash_amount = position.total_capital;
        if slash_amount > 0 {
            position.total_capital = 0;
            position.total_tokens = 0;
            position.total_capital_seconds = 0;
            position.entries.clear();

            total_slashed = total_slashed.saturating_add(slash_amount);
            position.try_serialize(&mut position_data.as_mut())?;
        }
    }
    Ok(total_slashed)
}

pub fn process_final_ruling(ruling: &FinalRuling,
    market: &mut Market, market_key: &Pubkey,
    current_time: i64,
    remaining_accounts: &[AccountInfo],
    program_id: &Pubkey) -> Result<u64> {
    require!(!market.resolution_received,
        PithyQuip::AlreadyResolved);
    let mut total_slashed = 0u64;
    if ruling.is_force_majeure() {
        let requester_slashed = if let Some(req) = market.resolution_requester {
            ruling.slashing_addresses.contains(&req)
        } else { false };

        if requester_slashed && ruling.slashing_addresses.len() == 1 {
            // Frivolous request - only reset if safe to do so
            // Check: resolution_finalized == 0 means we haven't started jury compensation
            if market.resolution_finalized == 0 {
                market.resolution_requested = false;
                market.resolution_received = false;
                market.force_majeure = false;
                market.resolution_requester = None;
                market.resolution_requested_time = None;
            } else {
                // Already in finalization process, treat as full force majeure
                market.force_majeure = true;
                market.resolution_received = true;
                market.winning_sides = Vec::new();
                market.winning_splits = Vec::new();
            }
        } else {
            let creator_slashed = market.creator_bond;
            market.creator_bond = 0;
            market.resolution_fee_pool = market.resolution_fee_pool
                .saturating_add(creator_slashed);

            market.force_majeure = true;
            market.resolution_received = true;
            market.resolution_finalized = current_time;
            market.winning_sides = Vec::new();
            market.winning_splits = Vec::new();
        }
    } else if ruling.is_extension() {
        let can_extend = market.resolve_whenever && market.allows_extensions
            && (market.resolution_time == 0 || current_time < market.resolution_time);

        if can_extend {
            // Extension granted - increment counter and reset for new resolution request
            market.extensions_count += 1;
            market.resolution_requested = false;
            market.resolution_received = false;
            market.resolution_requester = None;
            market.resolution_requested_time = None;
            market.positions_revealed = 0;
            market.positions_processed = 0;
        } else {
            // Extension denied - treat as force majeure
            // This happens when:
            // - !market.resolve_whenever (fixed resolution time market)
            // - !market.allows_extensions (extensions explicitly disabled)
            // - current_time >= market.resolution_time (deadline passed)
            market.force_majeure = true;
            market.resolution_received = true;
            market.resolution_finalized = current_time;
            market.winning_sides = Vec::new();
            market.winning_splits = Vec::new();
            // Users can now withdraw their capital via force majeure flow
        }
    } else {
        require!(!ruling.winning_sides.is_empty(),
                    PithyQuip::InvalidResolution);

        for &side in ruling.winning_sides.iter() {
            require!(side < market.num_sides, PithyQuip::InvalidSide);
        }

        market.force_majeure = false;
        market.winning_sides = ruling.winning_sides.clone();
        // If winning_splits is empty, creator keeps fees (no auto equal splits)
        market.resolution_finalized = current_time;
        market.resolution_received = true;
        let mut has_potential_winners = false;
        for side in 0..market.num_sides {
            if market.total_capital_per_side[side as usize] > 0
            && market.winning_sides.contains(&side) {
                has_potential_winners = true; break;
            }
        } if !has_potential_winners {
            market.weights_complete = true;
        }
    }
    if !ruling.slashing_addresses.is_empty() {
        total_slashed += _handle_slashing(market_key,
            &ruling.slashing_addresses,
            &ruling.slashing_sides,
            remaining_accounts,
            program_id)?;
    }   Ok(total_slashed)
}
