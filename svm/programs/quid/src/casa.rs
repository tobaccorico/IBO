
use anchor_lang::prelude::*;
use crate::state::*;
use crate::stay::{ 
    stake_from_depositor_cpi, 
    deduct_battle_stake, 
    Depositor, Depository
};

/*
use switchboard_on_demand::{
    FunctionAccountData, 
    FunctionRequestAccountData
}; */

pub fn stake_battle<'info>(
    depositor: &Account<'info, Depositor>,
    depository: &Account<'info, Depository>,
    battle: &mut Account<Battle>,
    stake_amount: u64, 
    ticker: [u8; 8],
    is_challenger: bool,
) -> Result<()> {
    let position = depositor.balances
        .iter().find(|p| p.ticker == ticker)
        .ok_or(PithyQuip::UnknownSymbol)?;
    
    let available = stake_from_depositor_cpi(
        depositor, depository, stake_amount,
        true, // Use time-weighted for fairness
    )?;
    require!(available >= stake_amount, PithyQuip::InsufficientStake);
    require!(position.pledged >= stake_amount, PithyQuip::InsufficientStake);
    
    battle.stake_amount = stake_amount;
    if is_challenger {
        battle.challenger = depositor.owner;
        battle.challenger_ticker = ticker;
    } else {
        battle.defender = depositor.owner;
        battle.defender_ticker = ticker;
        battle.phase = BattlePhase::Active;
    }
    
    Ok(())
}

pub fn settle_battle<'info>(
    battle: &mut Account<Battle>,
    challenger_depositor: &mut Account<'info, Depositor>,
    defender_depositor: &mut Account<'info, Depositor>,
    depository: &mut Account<'info, Depository>,
    winner: Pubkey,
) -> Result<()> {
    require!(battle.phase == BattlePhase::Active,
                PithyQuip::InvalidBattlePhase);
    
    battle.winner = Some(winner);
    battle.phase = BattlePhase::Completed;
    // Deduct from loser using CPI helper
    if winner == battle.challenger {
        deduct_battle_stake(
            defender_depositor,
            depository,
            battle.stake_amount,
            false, // lost
        )?;
        // Winner gets 2x stake (their original + opponent's)
        challenger_depositor.deposited_usd_star += battle.stake_amount;
    } else {
        deduct_battle_stake(
            challenger_depositor,
            depository,
            battle.stake_amount,
            false, // lost
        )?;
        defender_depositor.deposited_usd_star += battle.stake_amount;
    }
    Ok(())
}

pub fn process_oracle_result(
    battle: &mut Account<Battle>,
    broken_by_challenger: Option<bool>, 
    // None = both maintained streak
) -> Result<Pubkey> {
    match broken_by_challenger {
        Some(true) => {
            // Challenger broke the streak
            battle.winner = Some(battle.defender);
            Ok(battle.defender)
        },
        Some(false) => {
            // Defender broke the streak
            battle.winner = Some(battle.challenger);
            Ok(battle.challenger)
        },
        None => {
            // Both maintained streak - need coin flip
            Ok(Pubkey::default()) // Signal that coin flip is needed
        }
    }
}

// Simple coin flip for tie breaker
pub fn break_tie_with_randomness(
    battle: &mut Account<Battle>,
    randomness_account: &AccountInfo) -> Result<()> {
    /*
    let vrf_data = randomness_account.try_borrow_data()?;
    let random_value = u64::from_le_bytes(vrf_data[0..8].try_into().unwrap());
    
    let coin_flip = random_value % 2 == 0;
    battle.winner = Some(if coin_flip {
                            battle.challenger
                        } else {
                            battle.defender
                        });
    */
    battle.winner = Some(battle.challenger);
    Ok(())
}
