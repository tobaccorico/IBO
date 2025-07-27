use anchor_lang::prelude::*;
use crate::state::*;
use crate::casa::*;
use crate::etc::*;
// use switchboard_on_demand::{FunctionAccountData, FunctionRequestAccountData};

#[derive(Accounts)]
pub struct CreateBattle<'info> {
    #[account(mut)]
    pub challenger: Signer<'info>,
    
    #[account(
        init,
        payer = challenger,
        space = 8 + Battle::INIT_SPACE,
        seeds = [b"battle", &Clock::get()?.slot.to_le_bytes()],
        bump
    )]
    pub battle: Account<'info, Battle>,
    
    #[account(mut)]
    pub challenger_depositor: Account<'info, crate::stay::Depositor>,
    
    #[account(mut)]
    pub depository: Account<'info, crate::stay::Depository>,
    
    #[account(
        seeds = [b"config"],
        bump
    )]
    pub config: Account<'info, BattleConfig>,
    
    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
pub struct AcceptBattle<'info> {
    #[account(mut)]
    pub defender: Signer<'info>,
    
    #[account(mut)]
    pub battle: Account<'info, Battle>,
    
    #[account(mut)]
    pub defender_depositor: Account<'info, crate::stay::Depositor>,
    
    #[account(mut)]
    pub depository: Account<'info, crate::stay::Depository>,
}

#[derive(Accounts)]
pub struct FinalizeBattle<'info> {
    pub authority: Signer<'info>,
    
    #[account(mut)]
    pub battle: Account<'info, Battle>,
    
    #[account(mut)]
    pub challenger_depositor: Account<'info, crate::stay::Depositor>,
    
    #[account(mut)]  
    pub defender_depositor: Account<'info, crate::stay::Depositor>,
    
    #[account(mut)]
    pub depository: Account<'info, crate::stay::Depository>,
    
    /// CHECK: Switchboard VRF account for randomness
    pub randomness_account: AccountInfo<'info>,
}

#[derive(Accounts)]
pub struct RequestOracle<'info> {
    pub authority: Signer<'info>,
    
    pub battle: Account<'info, Battle>,
    
    /// CHECK: Switchboard function account
    // pub switchboard_function: AccountInfo<'info>,
    
    #[account(
        seeds = [b"config"],
        bump
    )]
    pub config: Account<'info, BattleConfig>,
}

pub fn create_battle_challenge(
    ctx: Context<CreateBattle>,
    stake_amount: u64,
    ticker: String,
    initial_tweet_uri: String,
) -> Result<()> {
    let battle = &mut ctx.accounts.battle;
    let config = &ctx.accounts.config;
    
    require!(stake_amount >= config.min_stake, PithyQuip::InsufficientStake);
    require!(!initial_tweet_uri.is_empty(), PithyQuip::InvalidAmount);
    
    let mut ticker_bytes = [0u8; 8];
    let ticker_trimmed = ticker.trim();
    let len = ticker_trimmed.len().min(8);
    ticker_bytes[..len].copy_from_slice(&ticker_trimmed.as_bytes()[..len]);
    
    battle.battle_id = Clock::get()?.slot;
    battle.created_at = Clock::get()?.unix_timestamp;
    battle.phase = BattlePhase::Open;
    battle.challenger_tweet_uri = initial_tweet_uri;
    battle.defender_tweet_uri = String::new(); // Empty until defender joins
    
    stake_battle(
        &ctx.accounts.challenger_depositor,
        &ctx.accounts.depository,
        battle,
        stake_amount,
        ticker_bytes,
        true,
    )?;
    
    emit_battle_event(BattleEvent::BattleCreated {
        battle_id: battle.battle_id,
        challenger: ctx.accounts.challenger.key(),
        stake: stake_amount,
        ticker: ticker_bytes,
    })?;
    
    Ok(())
}

pub fn accept_battle_challenge(
    ctx: Context<AcceptBattle>,
    ticker: String,
    defender_tweet_uri: String,
) -> Result<()> {
    let battle = &mut ctx.accounts.battle;
    
    require!(battle.phase == BattlePhase::Open, PithyQuip::InvalidBattlePhase);
    require!(battle.defender == Pubkey::default(), PithyQuip::InvalidBattlePhase);
    require!(!defender_tweet_uri.is_empty(), PithyQuip::InvalidAmount);
    
    let mut ticker_bytes = [0u8; 8];
    let ticker_trimmed = ticker.trim();
    let len = ticker_trimmed.len().min(8);
    ticker_bytes[..len].copy_from_slice(&ticker_trimmed.as_bytes()[..len]);
    
    // Store defender's tweet URI - oracle will verify it's a reply to challenger's tweet
    battle.defender_tweet_uri = defender_tweet_uri;
    
    stake_battle(
        &ctx.accounts.defender_depositor,
        &ctx.accounts.depository,
        battle,
        battle.stake_amount,
        ticker_bytes,
        false,
    )?;
    
    emit_battle_event(BattleEvent::BattleAccepted {
        battle_id: battle.battle_id,
        defender: ctx.accounts.defender.key(),
        ticker: ticker_bytes,
    })?;
    Ok(())
}

// Finalize battle using oracle result
pub fn finalize_battle_with_oracle(
    ctx: Context<FinalizeBattle>,
    oracle_result: OracleResult,
) -> Result<()> {
    let battle = &mut ctx.accounts.battle;
    
    require!(battle.phase == BattlePhase::Active, PithyQuip::InvalidBattlePhase);
    
    // DUMMY: For now, always assume no one broke streak (triggers coin flip)
    // TODO: Uncomment when Switchboard oracle is integrated
    /*
    // Process oracle result
    let winner = if oracle_result.challenger_broke_streak && !oracle_result.defender_broke_streak {
        // Challenger broke streak, defender wins
        battle.defender
    } else if !oracle_result.challenger_broke_streak && oracle_result.defender_broke_streak {
        // Defender broke streak, challenger wins
        battle.challenger
    } else if oracle_result.challenger_broke_streak && oracle_result.defender_broke_streak {
        // Both broke streak - first to break loses
        // Oracle should indicate who broke first
        return Err(PithyQuip::InvalidBattlePhase.into()); // Need more info
    } else {
        // Neither broke streak - coin flip
        break_tie_with_randomness(
            battle,
            &ctx.accounts.randomness_account,
        )?;
        battle.winner.unwrap()
    };
    */
    
    // DUMMY: Always do coin flip (which currently always picks challenger)
    break_tie_with_randomness(
        battle,
        &ctx.accounts.randomness_account,
    )?;
    let winner = battle.winner.unwrap();
    
    // Settle stakes
    settle_battle(
        battle,
        &mut ctx.accounts.challenger_depositor,
        &mut ctx.accounts.defender_depositor,
        &mut ctx.accounts.depository,
        winner,
    )?;
    
    emit_battle_event(BattleEvent::BattleFinalized {
        battle_id: battle.battle_id,
        winner,
        reason: "dummy_coin_flip".to_string(), // DUMMY: Always coin flip for now
        /*
        reason: if oracle_result.challenger_broke_streak || oracle_result.defender_broke_streak {
            format!("streak_broken_{:?}", oracle_result.broken_at_tweet)
        } else {
            "coin_flip".to_string()
        },
        */
    })?;
    
    Ok(())
}

// Request oracle verification (called automatically or by authority)
pub fn request_oracle_verification(
    ctx: Context<RequestOracle>,
) -> Result<()> {
    let battle = &ctx.accounts.battle;
    // let function_account = &ctx.accounts.switchboard_function;
    
    require!(battle.phase == BattlePhase::Active, PithyQuip::InvalidBattlePhase);
    
    // DUMMY: For now, just log that we would request oracle
    // TODO: Uncomment when Switchboard is integrated
    /*
    // Trigger Switchboard function with battle data
    let params = format!(
        r#"{{"battle_id": {}, "challenger_tweet": "{}", "defender_tweet": "{}"}}"#,
        battle.battle_id,
        battle.challenger_tweet_uri,
        battle.defender_tweet_uri
    );
    
    // The oracle function will traverse the tweet thread and check consecutive likes
    msg!("Requesting oracle verification for battle {}", battle.battle_id);
    msg!("Parameters: {}", params);
    */
    
    // DUMMY: Just log for now
    msg!("DUMMY: Would request oracle verification for battle {}", battle.battle_id);
    
    Ok(())
}
