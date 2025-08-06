
use anchor_lang::prelude::*;
use anchor_lang::solana_program::sysvar::instructions::{
    ID as SYSVAR_INSTRUCTIONS_ID};

use crate::state::*;
use crate::case::*;
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
    
    #[account(
        seeds = [b"config"],
        bump
    )]
    pub config: Account<'info, BattleConfig>,
    
    /// CHECK: Instruction sysvar for Ed25519 verification
    #[account(address = SYSVAR_INSTRUCTIONS_ID)]
    pub instruction_sysvar: AccountInfo<'info>,
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

pub fn finalize_battle_with_mpc(
    ctx: Context<FinalizeBattle>,
    winner_is_challenger: bool,
    challenger_sig: [u8; 64],
    defender_sig: [u8; 64],
    judge_sig: [u8; 64],
) -> Result<()> {
    let battle = &mut ctx.accounts.battle;
    
    require!(battle.phase == BattlePhase::Active, PithyQuip::InvalidBattlePhase);
    
    // Create message that was signed
    let message = [
        battle.battle_id.to_le_bytes().as_ref(),
        &[winner_is_challenger as u8],
    ].concat();
    
    // Verify Ed25519 signatures via precompile
    let clock = Clock::get()?;
    
    // 1. Verify challenger signature
    verify_ed25519_signature(
        &battle.challenger,
        &message,
        &challenger_sig,
        &ctx.accounts.instruction_sysvar,
    )?;
    
    // 2. Verify defender signature  
    verify_ed25519_signature(
        &battle.defender,
        &message,
        &defender_sig,
        &ctx.accounts.instruction_sysvar,
    )?;
    
    // 3. Verify judge signature (must be from authorized judge)
    let config = &ctx.accounts.config;
    let judge_pubkey = recover_pubkey_from_signature(&message, &judge_sig)?;
    require!(
        config.judge_pubkeys.contains(&judge_pubkey),
        PithyQuip::UnauthorizedAction
    );
    
    // 4. Aggregate signatures to form MPC signature
    let aggregated_signature = aggregate_signatures(
        &challenger_sig,
        &defender_sig,
        &judge_sig,
    );
    
    // 5. Verify aggregated signature matches authority
    verify_aggregated_authority(
        &config.authority,
        &message,
        &aggregated_signature,
    )?;
    
    // Set winner and settle
    battle.winner = Some(if winner_is_challenger { 
        battle.challenger 
    } else { 
        battle.defender 
    });
    battle.phase = BattlePhase::Completed;
    
    settle_battle(battle,
        &mut ctx.accounts.challenger_depositor,
        &mut ctx.accounts.defender_depositor,
        &mut ctx.accounts.depository,
        battle.winner.unwrap(),
    )?;
    Ok(())
}
