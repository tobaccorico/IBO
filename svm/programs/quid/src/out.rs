use anchor_lang::prelude::*;
use anchor_spl::token_interface::Mint;

use crate::state::*;
use crate::stay::*;
use crate::LZ::{OAppStore, OAPP_STORE_SEED};
use crate::etc::*;

#[derive(Accounts)]
pub struct SellPosition<'info> {
    #[account(mut, seeds = [b"market",
    &market.market_id.to_le_bytes()[..6]],
    bump = market.bump)]
    pub market: Account<'info, Market>,

    #[account(mut, seeds = [b"position",
    market.key().as_ref(), user.key().as_ref(),
    &[position.side]], bump = position.bump)]
    pub position: Account<'info, Position>,

    #[account(mut, seeds = [b"depository"], bump)]
    pub bank: Account<'info, Depository>,

    #[account(mut, seeds = [user.key().as_ref()], bump)]
    pub user_depositor: Account<'info, Depositor>,

    #[account(mut)]
    pub user: Signer<'info>,

    pub mint: InterfaceAccount<'info, Mint>,

    #[account(seeds = [OAPP_STORE_SEED], bump = store.bump)]
    pub store: Account<'info, OAppStore>,

    pub system_program: Program<'info, System>,
}

pub fn sell_position(ctx: Context<SellPosition>,
    tokens_to_sell: u64, max_deviation_bps: Option<u64>) -> Result<()> {
    let market = &mut ctx.accounts.market;
    let position = &mut ctx.accounts.position;
    let bank = &mut ctx.accounts.bank;
    let depositor = &mut ctx.accounts.user_depositor;

    require!(!market.resolution_requested
          && !market.resolution_received, PithyQuip::TradingClosed);
    require!(market.extensions_count == 0, PithyQuip::TradingClosedAfterExtension);

    let clock = Clock::get()?;
    let right_now = clock.unix_timestamp;
    require!(tokens_to_sell <= position.total_tokens, PithyQuip::InsufficientTokens);

    update_price_accumulator(market, right_now)?;
    let max_deviation = max_deviation_bps.unwrap_or(300);
    let deviation = get_price_deviation(market, position.side, right_now);
    require!(deviation <= max_deviation, PithyQuip::PriceManipulated);

    market.liquidity = calculate_adaptive_liquidity(market, right_now);
    let current_price = get_twap_price(market, position.side, right_now);
    let capital_returned = (tokens_to_sell as f64 * current_price) as u64;
    let exit_fee = (capital_returned as u128 * market.creator_fee_bps as u128) / 10_000;
    let net_capital = capital_returned.saturating_sub(exit_fee as u64);

    position.total_tokens = position.total_tokens
        .checked_sub(tokens_to_sell)
        .ok_or(PithyQuip::Underflow)?;

    let total_tokens_before = position.total_tokens + tokens_to_sell;
    let sell_fraction = if total_tokens_before > 0 {
        (tokens_to_sell as u128 * 10_000) / (total_tokens_before as u128)
    } else { 10_000 };

    for entry in position.entries.iter_mut() {
        let time_elapsed = (right_now - entry.last_updated).max(0) as u64;
        entry.capital_seconds += (entry.capital as u128).saturating_mul(time_elapsed as u128);
        entry.last_updated = right_now;
    }

    let mut total_capital_seconds = 0u128;
    for entry in position.entries.iter() {
        total_capital_seconds = total_capital_seconds.saturating_add(entry.capital_seconds);
    }
    position.total_capital_seconds = total_capital_seconds;

    let mut total_capital_seconds_removed = 0u128;
    let mut i = 0;

    while i < position.entries.len() {
        let entry_capital = position.entries[i].capital;
        let entry_tokens = position.entries[i].tokens;
        let entry_capital_seconds = position.entries[i].capital_seconds;
        let tokens_from_entry = (entry_tokens as u128 * sell_fraction) / 10_000;

        if tokens_from_entry >= entry_tokens as u128 {
            total_capital_seconds_removed = total_capital_seconds_removed
                .saturating_add(entry_capital_seconds);
            position.total_capital = position.total_capital.saturating_sub(entry_capital);
            position.entries.remove(i);
        } else {
            let entry = &mut position.entries[i];
            let capital_from_entry = (entry_capital as u128 * tokens_from_entry) / (entry_tokens as u128);
            let capital_seconds_removed = (entry_capital_seconds * tokens_from_entry) / (entry_tokens as u128);

            entry.tokens = entry.tokens.saturating_sub(tokens_from_entry as u64);
            entry.capital = entry.capital.saturating_sub(capital_from_entry as u64);
            entry.capital_seconds = entry_capital_seconds.saturating_sub(capital_seconds_removed);
            position.total_capital = position.total_capital.saturating_sub(capital_from_entry as u64);
            total_capital_seconds_removed = total_capital_seconds_removed
                .saturating_add(capital_seconds_removed);
            i += 1;
        }
    }
    position.total_capital_seconds = position.total_capital_seconds
        .saturating_sub(total_capital_seconds_removed);

    let side = position.side;
    market.tokens_sold_per_side[side as usize] = market.tokens_sold_per_side[side as usize]
        .saturating_sub(tokens_to_sell);
    market.total_capital = market.total_capital.saturating_sub(capital_returned.min(market.total_capital));
    market.total_capital_per_side[side as usize] = market.total_capital_per_side[side as usize]
        .saturating_sub(capital_returned);
    market.fees_collected = market.fees_collected.checked_add(exit_fee as u64).ok_or(PithyQuip::Overflow)?;

    if net_capital > 0 {
        let time_delta = right_now - depositor.last_updated;
        depositor.deposit_seconds += (depositor.deposited_quid as u128)
            .saturating_mul(time_delta.max(0) as u128);
        depositor.deposited_quid += net_capital;
        bank.total_deposits += net_capital;
        depositor.last_updated = right_now;
    }

    const MIN_POSITION_VALUE: u64 = 100_000_000;
    if position.entries.is_empty() || (position.total_capital > 0 && position.total_capital < MIN_POSITION_VALUE) {
        let remaining = position.total_capital;
        if remaining > 0 {
            let time_delta = right_now - depositor.last_updated;
            depositor.deposit_seconds += (depositor.deposited_quid as u128)
                .saturating_mul(time_delta.max(0) as u128);
            depositor.deposited_quid += remaining;
            bank.total_deposits += remaining;
            depositor.last_updated = right_now;

            market.total_capital = market.total_capital.saturating_sub(remaining);
            market.total_capital_per_side[side as usize] = market.total_capital_per_side[side as usize]
                .saturating_sub(remaining);
        }
        market.positions_total = market.positions_total.saturating_sub(1);
        position.total_capital = 0;
        position.total_tokens = 0;
        position.total_capital_seconds = 0;
        position.entries.clear();
    }
    Ok(())
}

#[derive(Accounts)]
pub struct BatchReveal<'info> {
    #[account(mut, seeds = [b"market",
    &market.market_id.to_le_bytes()[..6]],
    bump = market.bump)]
    pub market: Account<'info, Market>,

    #[account(mut, seeds = [b"accuracy_buckets",
    &market.market_id.to_le_bytes()[..6]],
    bump = accuracy_buckets.bump)]
    pub accuracy_buckets: Account<'info, AccuracyBuckets>,
    pub signer: Signer<'info>,
}

pub fn batch_reveal<'info>(ctx: Context<'_, '_, '_, 'info,
    BatchReveal<'info>>, reveals: Vec<Vec<RevealEntry>>) -> Result<()> {
    let accuracy_buckets = &mut ctx.accounts.accuracy_buckets;
    let signer_key = ctx.accounts.signer.key();
    let market = &mut ctx.accounts.market;

    require!(market.resolution_received, PithyQuip::NotResolved);
    require!(!market.weights_complete, PithyQuip::TooLate);

    for (i, position_info) in ctx.remaining_accounts.iter().enumerate() {
        require!(position_info.owner == &crate::ID, PithyQuip::InvalidAccountOwner);

        let mut data = position_info.try_borrow_mut_data()?;
        let mut position = Position::try_deserialize(&mut data.as_ref())?;
        require!(position.market == market.key(), PithyQuip::WrongMarket);

        let is_authorized = position.user == signer_key
            || position.reveal_delegate.map(|d| d == signer_key).unwrap_or(false);
        require!(is_authorized, PithyQuip::Unauthorized);

        if position.revealed_confidence > 0 { continue; }
        let position_reveals = reveals.get(i).ok_or(PithyQuip::InvalidRevealCount)?;
        _do_reveal(&mut position, market, accuracy_buckets, position_reveals)?;
        position.try_serialize(&mut data.as_mut())?;
    }
    Ok(())
}

fn _do_reveal(position: &mut Position, market: &mut Market,
    accuracy_buckets: &mut AccuracyBuckets, reveals: &[RevealEntry]) -> Result<()> {
    require!(position.total_capital > 0, PithyQuip::InvalidPosition);
    require!(position.revealed_confidence == 0, PithyQuip::AlreadyRevealed);

    let effective_end = if market.resolution_finalized > 0 {
        market.resolution_finalized
    } else {
        Clock::get()?.unix_timestamp
    };

    let mut total_capital_seconds = 0u128;
    for entry in position.entries.iter_mut() {
        let time_elapsed = (effective_end - entry.last_updated).max(0) as u128;
        entry.capital_seconds = entry.capital_seconds
            .saturating_add((entry.capital as u128).saturating_mul(time_elapsed));
        entry.last_updated = effective_end;
        total_capital_seconds = total_capital_seconds.saturating_add(entry.capital_seconds);
    }
    position.total_capital_seconds = total_capital_seconds;

    let mut rollover_capital: u128 = 0;
    let mut revealable_indices: Vec<usize> = Vec::new();
    for (i, entry) in position.entries.iter().enumerate() {
        if entry.commitment_hash == [0u8; 32] {
            rollover_capital += entry.capital as u128;
        } else {
            revealable_indices.push(i);
        }
    }

    require!(reveals.len() == revealable_indices.len(), PithyQuip::InvalidRevealCount);

    let mut weighted_confidence_sum: u128 = 0;
    for (reveal_idx, &entry_idx) in revealable_indices.iter().enumerate() {
        let reveal = &reveals[reveal_idx];
        let entry = &mut position.entries[entry_idx];

        let calculated_hash = hash_commitment_u64(reveal.confidence, reveal.salt);
        require!(calculated_hash == entry.commitment_hash,
                PithyQuip::CommitmentVerificationFailed);
        require!(reveal.confidence >= 500
              && reveal.confidence <= 10_000
              && reveal.confidence % 500 == 0, PithyQuip::InvalidConfidence);

        entry.confidence = Some(reveal.confidence);
        weighted_confidence_sum = weighted_confidence_sum
            .saturating_add((entry.capital as u128).saturating_mul(reveal.confidence as u128));
    }

    const NEUTRAL_CONFIDENCE: u64 = 5000;
    for entry in position.entries.iter_mut() {
        if entry.commitment_hash == [0u8; 32] && entry.confidence.is_none() {
            entry.confidence = Some(NEUTRAL_CONFIDENCE);
        }
    }

    weighted_confidence_sum = weighted_confidence_sum
        .saturating_add(rollover_capital.saturating_mul(NEUTRAL_CONFIDENCE as u128));
    let weighted_avg_confidence = (weighted_confidence_sum / position.total_capital as u128) as u64;
    position.revealed_confidence = weighted_avg_confidence;

    let side_idx = position.side as usize;
    if side_idx < market.confidence_sum_per_side.len() {
        market.confidence_sum_per_side[side_idx] = market.confidence_sum_per_side[side_idx]
            .saturating_add(weighted_confidence_sum);
    }

    let is_winner = market.winning_sides.contains(&position.side);
    position.accuracy_percentile = if is_winner {
        if market.winning_splits.is_empty() {
            weighted_avg_confidence
        } else {
            let mut acc = 0u64;
            for (idx, &winner_side) in market.winning_sides.iter().enumerate() {
                if position.side == winner_side {
                    let split = market.winning_splits.get(idx)
                        .copied()
                        .unwrap_or(10_000 / market.winning_sides.len() as u64);
                    acc += ((weighted_avg_confidence as u128).saturating_mul(split as u128) / 10_000) as u64;
                }
            }
            acc
        }
    } else {
        10_000u64.saturating_sub(weighted_avg_confidence)
    };

    accuracy_buckets.add_position(position.accuracy_percentile)?;

    if is_winner {
        market.total_winner_capital_revealed = market.total_winner_capital_revealed
            .saturating_add(position.total_capital);
    } else {
        market.total_loser_capital_revealed = market.total_loser_capital_revealed
            .saturating_add(position.total_capital);
    }
    market.positions_revealed += 1;
    Ok(())
}

#[derive(Accounts)]
pub struct CalculateAllWeights<'info> {
    #[account(mut, seeds = [b"market", &market.market_id.to_le_bytes()[..6]], bump = market.bump)]
    pub market: Account<'info, Market>,

    #[account(mut, seeds = [b"accuracy_buckets", &market.market_id.to_le_bytes()[..6]], bump = accuracy_buckets.bump)]
    pub accuracy_buckets: Account<'info, AccuracyBuckets>,

    #[account(mut, seeds = [b"depository"], bump)]
    pub bank: Account<'info, Depository>,

    #[account(init_if_needed, payer = signer, space = 8 + Depositor::INIT_SPACE,
        seeds = [signer.key().as_ref()], bump)]
    pub keeper_depositor: Account<'info, Depositor>,

    #[account(seeds = [OAPP_STORE_SEED], bump = store.bump)]
    pub store: Account<'info, OAppStore>,

    #[account(mut)]
    pub signer: Signer<'info>,

    pub system_program: Program<'info, System>,
}

pub fn rank<'info>(ctx: Context<'_, '_, '_, 'info, CalculateAllWeights<'info>>) -> Result<()> {
    let accuracy_buckets = &mut ctx.accounts.accuracy_buckets;
    let market = &mut ctx.accounts.market;
    let bank = &mut ctx.accounts.bank;
    let keeper = &mut ctx.accounts.keeper_depositor;

    require!(market.resolution_finalized > 0, PithyQuip::NotFinalized);
    require!(!market.weights_complete, PithyQuip::AlreadyComplete);

    let num_positions = ctx.remaining_accounts.len();
    require!(num_positions > 0, PithyQuip::NoPositions);

    let clock = Clock::get()?;
    let right_now = clock.unix_timestamp;

    if keeper.owner == Pubkey::default() {
        keeper.owner = ctx.accounts.signer.key();
        keeper.last_updated = right_now;
    }

    const KEEPER_FEE_PER_POSITION: u64 = 500;
    let keeper_fee = KEEPER_FEE_PER_POSITION.saturating_mul(num_positions as u64);
    if market.resolution_fee_pool >= keeper_fee {
        let time_delta = (right_now - keeper.last_updated).max(0);
        keeper.deposit_seconds += (keeper.deposited_quid as u128)
            .saturating_mul(time_delta as u128);
        keeper.deposited_quid += keeper_fee;
        bank.total_deposits += keeper_fee;
        keeper.last_updated = right_now;
        market.resolution_fee_pool -= keeper_fee;
    }

    let effective_end = market.resolution_finalized;
    let market_duration = effective_end.saturating_sub(market.start_time);
    let market_duration = if market_duration == 0 { 1 } else { market_duration };

    for position_info in ctx.remaining_accounts.iter() {
        require!(position_info.owner == &crate::ID, PithyQuip::InvalidAccountOwner);

        let mut data = position_info.try_borrow_mut_data()?;
        let mut position = Position::try_deserialize(&mut data.as_ref())?;
        require!(position.market == market.key(), PithyQuip::WrongMarket);

        if position.weight > 0 || position.revealed_confidence == 0 {
            market.positions_processed += 1;
            position.try_serialize(&mut data.as_mut())?;
            continue;
        }

        let percentile = accuracy_buckets.calculate_percentile(
            position.accuracy_percentile, market.positions_revealed);

        let mut time_weighted_total = 0u128;
        for entry in position.entries.iter() {
            let entry_duration = effective_end.saturating_sub(entry.timestamp);
            let entry_decay = calculate_time_decay(entry_duration, market_duration, market.time_decay_lambda);
            time_weighted_total = time_weighted_total.saturating_add(
                entry.capital_seconds.saturating_mul(entry_decay as u128) / 10_000
            );
        }
        position.weight = time_weighted_total.saturating_mul(percentile as u128) / 10_000;

        let is_winner = market.winning_sides.contains(&position.side);
        if is_winner {
            market.total_winner_weight_revealed = market.total_winner_weight_revealed
                .saturating_add(position.weight);
        } else {
            market.total_loser_weight_revealed = market.total_loser_weight_revealed
                .saturating_add(position.weight);
        }
        market.positions_processed += 1;
        position.try_serialize(&mut data.as_mut())?;
    }

    if market.positions_processed >= market.positions_total {
        market.weights_complete = true;
        market.positions_processed = 0;
    }
    Ok(())
}

#[derive(Accounts)]
pub struct PushPayouts<'info> {
    #[account(mut, seeds = [b"market", &market.market_id.to_le_bytes()[..6]], bump = market.bump)]
    pub market: Account<'info, Market>,

    #[account(mut, seeds = [b"depository"], bump)]
    pub bank: Account<'info, Depository>,

    #[account(mut, seeds = [market.creator.as_ref()], bump)]
    pub creator_depositor: Account<'info, Depositor>,

    #[account(init_if_needed, payer = signer, space = 8 + Depositor::INIT_SPACE,
        seeds = [signer.key().as_ref()], bump)]
    pub keeper_depositor: Account<'info, Depositor>,

    #[account(seeds = [OAPP_STORE_SEED], bump = store.bump)]
    pub store: Account<'info, OAppStore>,

    #[account(mut)]
    pub signer: Signer<'info>,

    pub system_program: Program<'info, System>,
}

pub fn push_payouts<'info>(ctx: Context<'_, '_, '_, 'info, PushPayouts<'info>>) -> Result<()> {
    let market = &mut ctx.accounts.market;
    let bank = &mut ctx.accounts.bank;
    let creator = &mut ctx.accounts.creator_depositor;
    let keeper = &mut ctx.accounts.keeper_depositor;

    require!(market.resolution_finalized > 0, PithyQuip::NotFinalized);
    require!(!market.payouts_complete, PithyQuip::AlreadyComplete);
    if !market.force_majeure {
        require!(market.weights_complete, PithyQuip::WeightsNotCalculated);
    }

    let clock = Clock::get()?;
    let right_now = clock.unix_timestamp;

    if keeper.owner == Pubkey::default() {
        keeper.owner = ctx.accounts.signer.key();
        keeper.last_updated = right_now;
    }

    let num_beneficiaries = market.winning_sides.iter()
        .filter(|&&side_idx| {
            let idx = side_idx as usize;
            idx < market.sides.len() && market.sides[idx].address.is_some()
        })
        .count();

    let total_accounts = ctx.remaining_accounts.len();
    let num_positions = (total_accounts.saturating_sub(num_beneficiaries)) / 2;

    const KEEPER_FEE_PER_POSITION: u64 = 1_000;
    let keeper_fee = KEEPER_FEE_PER_POSITION.saturating_mul(num_positions as u64);
    if market.resolution_fee_pool >= keeper_fee && num_positions > 0 {
        let time_delta = (right_now - keeper.last_updated).max(0);
        keeper.deposit_seconds += (keeper.deposited_quid as u128).saturating_mul(time_delta as u128);
        keeper.deposited_quid += keeper_fee;
        bank.total_deposits += keeper_fee;
        keeper.last_updated = right_now;
        market.resolution_fee_pool -= keeper_fee;
    }

    // Calculate payout pools
    let (winner_pot, loser_pot, total_winner_weight, total_loser_weight) =
        if market.force_majeure || market.total_winner_capital_revealed == 0 {
            (0u128, 0u128, 0u128, 0u128)
        } else {
            let unrevealed = market.total_capital
                .saturating_sub(market.total_winner_capital_revealed)
                .saturating_sub(market.total_loser_capital_revealed);

            let loser_pot_total = market.total_loser_capital_revealed.saturating_add(unrevealed);
            let w_pot = (loser_pot_total as u128 * 8_000) / 10_000;
            let l_pot = (loser_pot_total as u128).saturating_sub(w_pot);

            (w_pot, l_pot, market.total_winner_weight_revealed, market.total_loser_weight_revealed)
        };

    // Process [position, depositor] pairs
    for i in 0..num_positions {
        let pos_info = &ctx.remaining_accounts[i * 2];
        let dep_info = &ctx.remaining_accounts[i * 2 + 1];

        let mut pos_data = pos_info.try_borrow_mut_data()?;
        if pos_data.len() < 8 || pos_data[..8] == [0u8; 8] { continue; }

        let mut position = match Position::try_deserialize(&mut pos_data.as_ref()) {
            Ok(p) => p,
            Err(_) => continue,
        };
        require!(position.market == market.key(), PithyQuip::WrongMarket);

        if position.payout_pushed {
            position.try_serialize(&mut pos_data.as_mut())?;
            continue;
        }

        // Validate depositor PDA matches expected
        let (expected_dep, _) = Pubkey::find_program_address(&[position.user.as_ref()], &crate::ID);
        if dep_info.key() != expected_dep {
            msg!("Depositor mismatch for {}", position.user);
            continue;
        }

        let mut dep_data = dep_info.try_borrow_mut_data()?;
        let mut depositor = match Depositor::try_deserialize(&mut dep_data.as_ref()) {
            Ok(d) => d,
            Err(_) => continue,
        };

        // =========================================================================
        // Handle unrevealed positions properly in rollover markets
        // =========================================================================
        if position.revealed_confidence == 0 && !market.force_majeure && market.total_winner_capital_revealed > 0 {
            // Position forfeited (didn't reveal)
            let forfeited_capital = position.total_capital;

            // MUST decrement market capital for forfeited positions
            // Otherwise this capital gets double-counted in rollover round 2
            market.total_capital = market.total_capital.saturating_sub(forfeited_capital);
            market.total_capital_per_side[position.side as usize] =
                market.total_capital_per_side[position.side as usize].saturating_sub(forfeited_capital);

            // Also decrement tokens_sold_per_side
            market.tokens_sold_per_side[position.side as usize] =
                market.tokens_sold_per_side[position.side as usize].saturating_sub(position.total_tokens);

            // Clear position state for rollover markets
            if market.allows_rollovers {
                market.positions_total = market.positions_total.saturating_sub(1);
                position.entries.clear();
                position.total_capital = 0;
                position.total_tokens = 0;
                position.total_capital_seconds = 0;
                position.market = Pubkey::default();  // Allow reuse
            }

            position.payout = 0;
            position.payout_pushed = true;
            position.try_serialize(&mut pos_data.as_mut())?;
            market.positions_processed += 1;
            continue;
        }

        // Calculate payout
        let is_winner = market.winning_sides.contains(&position.side);
        let payout = if market.force_majeure {
            position.total_capital
        } else if market.total_winner_capital_revealed == 0 {
            position.total_capital
        } else if is_winner {
            if total_winner_weight > 0 {
                let share = ((position.weight as u128).saturating_mul(winner_pot)) / total_winner_weight;
                position.total_capital.saturating_add(share as u64)
            } else {
                position.total_capital
            }
        } else {
            if total_loser_weight > 0 {
                (((position.weight as u128).saturating_mul(loser_pot)) / total_loser_weight) as u64
            } else { 0 }
        };

        position.payout = payout;
        position.payout_pushed = true;

        // Rollover vs payout
        if payout > 0 && position.auto_rollover && is_winner && market.allows_rollovers && !market.force_majeure {
            let old_capital = position.total_capital;
            let old_tokens = position.total_tokens;

            // Decrement old capital and tokens
            market.total_capital = market.total_capital.saturating_sub(old_capital);
            market.total_capital_per_side[position.side as usize] =
                market.total_capital_per_side[position.side as usize].saturating_sub(old_capital);
            market.tokens_sold_per_side[position.side as usize] =
                market.tokens_sold_per_side[position.side as usize].saturating_sub(old_tokens);

            // Calculate new tokens based on current price for proper LMSR accounting
            let current_price = if market.total_capital > 0 && market.positions_total > 0 {
                let side_tokens = market.tokens_sold_per_side[position.side as usize];
                if side_tokens > 0 {
                    (market.total_capital_per_side[position.side as usize] as f64) / (side_tokens as f64)
                } else {
                    1.0 / (market.num_sides as f64)
                }
            } else {
                1.0 / (market.num_sides as f64)
            };

            let new_tokens = (payout as f64 / current_price.max(0.0001)) as u64;

            position.entries.clear();
            position.entries.push(PositionEntry {
                capital: payout,
                tokens: new_tokens,
                price_at_entry: (current_price * 1_000_000.0) as u64,
                timestamp: right_now,
                capital_seconds: 0,
                last_updated: right_now,
                commitment_hash: [0u8; 32],
                confidence: None,
            });

            position.total_capital = payout;
            position.total_tokens = new_tokens;

            market.total_capital += payout;
            market.total_capital_per_side[position.side as usize] += payout;
            market.tokens_sold_per_side[position.side as usize] += new_tokens;

            position.total_capital_seconds = 0;
            position.payout_pushed = false;
            position.payout = 0;
            position.accuracy_percentile = 0;
            position.weight = 0;
            position.revealed_confidence = 0;
            position.commitment_hash = [0u8; 32];
        } else if payout > 0 {
            // Credit depositor
            let time_delta = (right_now - depositor.last_updated).max(0);
            depositor.deposit_seconds += (depositor.deposited_quid as u128).saturating_mul(time_delta as u128);
            depositor.deposited_quid += payout;
            bank.total_deposits += payout;
            depositor.last_updated = right_now;

            // Decrement market capital
            market.total_capital = market.total_capital.saturating_sub(payout);
            market.total_capital_per_side[position.side as usize] =
                market.total_capital_per_side[position.side as usize].saturating_sub(payout);

            // For rollover markets, close this position
            if market.allows_rollovers && !market.force_majeure {
                market.positions_total = market.positions_total.saturating_sub(1);

                // Also decrement tokens
                market.tokens_sold_per_side[position.side as usize] =
                    market.tokens_sold_per_side[position.side as usize].saturating_sub(position.total_tokens);

                position.entries.clear();
                position.total_capital = 0;
                position.total_tokens = 0;
                position.total_capital_seconds = 0;
                position.revealed_confidence = 0;
                position.commitment_hash = [0u8; 32];
                position.weight = 0;
                position.accuracy_percentile = 0;
                position.payout = 0;
                position.payout_pushed = false;
                position.market = Pubkey::default();
            }
        }

        position.try_serialize(&mut pos_data.as_mut())?;
        depositor.try_serialize(&mut dep_data.as_mut())?;
        market.positions_processed += 1;
    }

    // Finalize when all positions processed
    if market.positions_processed >= market.positions_total {
        let total_fees = market.fees_collected;

        if total_fees > 0 && !market.force_majeure {
            // Beneficiary split distribution (only if winning_splits defined)
            if !market.winning_splits.is_empty() {
                let mut beneficiary_map: Vec<(usize, usize)> = Vec::new();
                let mut beneficiary_idx = 2 * num_positions;

                for &winner_side in market.winning_sides.iter() {
                    let side_idx = winner_side as usize;
                    if side_idx < market.sides.len() && market.sides[side_idx].address.is_some() {
                        beneficiary_map.push((side_idx, beneficiary_idx));
                        beneficiary_idx += 1;
                    }
                }

                let mut total_distributed = 0u64;
                let mut undefined_winners = Vec::new();

                for &winner_side in market.winning_sides.iter() {
                    let side_idx = winner_side as usize;

                    if side_idx < market.winning_splits.len() && market.winning_splits[side_idx] > 0 {
                        if market.sides[side_idx].address.is_some() {
                            let split = market.winning_splits[side_idx];
                            let fee_share = ((total_fees as u128) * (split as u128)) / 10_000;

                            if let Some(&(_, ben_acc_idx)) = beneficiary_map.iter().find(|(idx, _)| *idx == side_idx) {
                                if ben_acc_idx < ctx.remaining_accounts.len() {
                                    let ben_dep_info = &ctx.remaining_accounts[ben_acc_idx];

                                    // Validate beneficiary depositor PDA
                                    if let Some(expected_beneficiary) = market.sides[side_idx].address {
                                        let (expected_ben_dep, _) = Pubkey::find_program_address(
                                            &[expected_beneficiary.as_ref()], &crate::ID
                                        );
                                        if ben_dep_info.key() != expected_ben_dep {
                                            msg!("Beneficiary depositor mismatch for side {}", side_idx);
                                            continue;
                                        }
                                    }

                                    if let Ok(mut ben_data) = ben_dep_info.try_borrow_mut_data() {
                                        if let Ok(mut ben_dep) = Depositor::try_deserialize(&mut ben_data.as_ref()) {
                                            let time_delta = (right_now - ben_dep.last_updated).max(0);
                                            ben_dep.deposit_seconds += (ben_dep.deposited_quid as u128)
                                                .saturating_mul(time_delta as u128);
                                            ben_dep.deposited_quid += fee_share as u64;
                                            bank.total_deposits += fee_share as u64;
                                            ben_dep.last_updated = right_now;
                                            total_distributed += fee_share as u64;
                                            let _ = ben_dep.try_serialize(&mut ben_data.as_mut());
                                        }
                                    }
                                }
                            }
                        }
                    } else {
                        if market.sides[side_idx].address.is_some() {
                            undefined_winners.push(side_idx);
                        }
                    }
                }

                // Distribute remainder equally to undefined winners
                if !undefined_winners.is_empty() && total_distributed < total_fees {
                    let remainder = total_fees.saturating_sub(total_distributed);
                    let equal_split = remainder / undefined_winners.len() as u64;
                    for side_idx in undefined_winners.iter() {
                        if let Some(&(_, ben_acc_idx)) = beneficiary_map.iter().find(|(idx, _)| idx == side_idx) {
                            if ben_acc_idx < ctx.remaining_accounts.len() {
                                let ben_dep_info = &ctx.remaining_accounts[ben_acc_idx];
                                if let Ok(mut ben_data) = ben_dep_info.try_borrow_mut_data() {
                                    if let Ok(mut ben_dep) = Depositor::try_deserialize(&mut ben_data.as_ref()) {
                                        let time_delta = (right_now - ben_dep.last_updated).max(0);
                                        ben_dep.deposit_seconds += (ben_dep.deposited_quid as u128)
                                            .saturating_mul(time_delta as u128);
                                        ben_dep.deposited_quid += equal_split;
                                        bank.total_deposits += equal_split;
                                        ben_dep.last_updated = right_now;
                                        total_distributed += equal_split;
                                        let _ = ben_dep.try_serialize(&mut ben_data.as_mut());
                                    }
                                }
                            }
                        }
                    }
                }
                market.fees_collected = market.fees_collected.saturating_sub(total_distributed);
            } else if market.side_proposal_cost > 0 {
                // Equal split among winning sides with addresses (only for proposal markets)
                let winning_sides_with_addresses: Vec<u8> = market.winning_sides.iter()
                    .filter(|&&side_idx| market.sides[side_idx as usize].address.is_some())
                    .copied().collect();

                if !winning_sides_with_addresses.is_empty() {
                    let equal_split = total_fees / winning_sides_with_addresses.len() as u64;
                    let mut beneficiary_account_idx = 2 * num_positions;
                    let mut total_distributed = 0u64;

                    for _ in winning_sides_with_addresses.iter() {
                        if beneficiary_account_idx < ctx.remaining_accounts.len() {
                            let ben_dep_info = &ctx.remaining_accounts[beneficiary_account_idx];
                            if let Ok(mut ben_data) = ben_dep_info.try_borrow_mut_data() {
                                if let Ok(mut ben_dep) = Depositor::try_deserialize(&mut ben_data.as_ref()) {
                                    let time_delta = (right_now - ben_dep.last_updated).max(0);
                                    ben_dep.deposit_seconds += (ben_dep.deposited_quid as u128)
                                        .saturating_mul(time_delta as u128);
                                    ben_dep.deposited_quid += equal_split;
                                    bank.total_deposits += equal_split;
                                    ben_dep.last_updated = right_now;
                                    total_distributed += equal_split;
                                    let _ = ben_dep.try_serialize(&mut ben_data.as_mut());
                                }
                            }
                            beneficiary_account_idx += 1;
                        }
                    }
                    market.fees_collected = market.fees_collected.saturating_sub(total_distributed);
                }
            }

            // Remaining fees go to creator
            if market.fees_collected > 0 {
                let time_delta = (right_now - creator.last_updated).max(0);
                creator.deposit_seconds += (creator.deposited_quid as u128).saturating_mul(time_delta as u128);
                creator.deposited_quid += market.fees_collected;
                bank.total_deposits += market.fees_collected;
                creator.last_updated = right_now;
                market.fees_collected = 0;
            }
        }

        if !market.force_majeure && market.creator_bond > 0 {
            let time_delta = (right_now - creator.last_updated).max(0);
            creator.deposit_seconds += (creator.deposited_quid as u128).saturating_mul(time_delta as u128);
            creator.deposited_quid += market.creator_bond;
            bank.total_deposits += market.creator_bond;
            creator.last_updated = right_now;
            market.creator_bond = 0;
        }

        if !market.force_majeure && market.allows_rollovers {
            // Reset extensions_count on rollover
            market.extensions_count = 0;

            market.resolution_requested = false;
            market.resolution_received = false;
            market.resolution_requester = None;
            market.resolution_finalized = 0;
            market.winning_sides.clear();
            market.winning_splits.clear();
            market.positions_revealed = 0;
            market.positions_processed = 0;
            market.weights_complete = false;
            market.payouts_complete = false;
            market.total_winner_weight_revealed = 0;
            market.total_loser_weight_revealed = 0;
            market.total_winner_capital_revealed = 0;
            market.total_loser_capital_revealed = 0;
            market.resolution_requested_time = None;

            for i in 0..market.confidence_sum_per_side.len() {
                market.confidence_sum_per_side[i] = 0;
            }
        } else {
            market.payouts_complete = true;
        }
    }

    Ok(())
}
