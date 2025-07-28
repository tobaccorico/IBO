use anchor_lang::prelude::*;
use crate::state::*;
use crate::casa::*;
// use switchboard_on_demand::{FunctionAccountData, FunctionRequestAccountData};

#[derive(Accounts)]
pub struct CreateBattle<'info> {
    #[account(mut)]
    pub challenger: Signer<'info>,
    
    #[account(
        init,
        payer = challenger,
        space = 8 + Battle::INIT_SPACE,
        seeds = [b"battle", challenger.key.as_ref()],
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
    
    let mut ticker_bytes = [0u8; 8];
    let ticker_trimmed = ticker.trim();
    let len = ticker_trimmed.len().min(8);
    ticker_bytes[..len].copy_from_slice(&ticker_trimmed.as_bytes()[..len]);
    
    battle.battle_id = Clock::get()?.slot;
    battle.created_at = Clock::get()?.unix_timestamp;
    battle.phase = BattlePhase::Open;
    battle.challenger_tweet_uri = initial_tweet_uri; // TODO validation 43 chars
    // first step in validation is simply
    // require!(!initial_tweet_uri.is_empty(), PithyQuip::ValidationError);
    battle.defender_tweet_uri = String::new(); // Empty until defender joins
    
    stake_battle(
        &ctx.accounts.challenger_depositor,
        &ctx.accounts.depository,
        battle, stake_amount,
        ticker_bytes, true,
    )?;
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
    
    let mut ticker_bytes = [0u8; 8];
    let ticker_trimmed = ticker.trim();
    let len = ticker_trimmed.len().min(8);
    ticker_bytes[..len].copy_from_slice(&ticker_trimmed.as_bytes()[..len]);

    // TODO validation 43 chars
    // first step in validation is simply
    // require!(!defender_tweet_uri.is_empty(), PithyQuip:: );
    
    // then also trim
    
    // Store defender's tweet URI - oracle will verify 
    // that it is a reply to challenger's tweet...
    battle.defender_tweet_uri = defender_tweet_uri;
    
    stake_battle(
        &ctx.accounts.defender_depositor,
        &ctx.accounts.depository,
        battle,
        battle.stake_amount,
        ticker_bytes,
        false,
    )?;
    Ok(())
}

// Finalize battle using oracle result
pub fn finalize_battle_with_oracle(
    ctx: Context<FinalizeBattle>,
    oracle_result: OracleResult,
) -> Result<()> {
    let battle = &mut ctx.accounts.battle;
    
    require!(battle.phase == BattlePhase::Active, PithyQuip::InvalidBattlePhase);
    
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
    break_tie_with_randomness( battle,
        &ctx.accounts.randomness_account)?;
    let winner = battle.winner.unwrap();

    settle_battle(
        battle,
        &mut ctx.accounts.challenger_depositor,
        &mut ctx.accounts.defender_depositor,
        &mut ctx.accounts.depository,
        winner,
    )?;
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
