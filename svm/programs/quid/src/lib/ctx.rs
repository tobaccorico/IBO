use anchor_lang::prelude::*;
use anchor_spl::{
    associated_token::AssociatedToken,
    token_interface::{Mint, TokenAccount, TokenInterface}
};
use anchor_spl::metadata::Metadata;
use crate::lib::battle_state::{BattleConfig, Battle, CommunityVoterRecord, BattleChallengeData};

// Context structures
#[derive(Accounts)]
pub struct InitializeBattleConfig<'info> {
    #[account(mut)]
    pub payer: Signer<'info>,
    
    #[account(
        init,
        payer = payer,
        space = 8 + BattleConfig::INIT_SPACE,
        seeds = [b"battle_config".as_ref()],
        bump
    )]
    pub battle_config: Account<'info, BattleConfig>,
    
    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
pub struct InitializeBattleCollection<'info> {
    #[account(mut)]
    pub payer: Signer<'info>,
    
    #[account(
        init,
        payer = payer,
        mint::decimals = 0,
        mint::authority = collection_mint,
        mint::freeze_authority = collection_mint,
        seeds = [b"battle_collection".as_ref()],
        bump,
    )]
    pub collection_mint: InterfaceAccount<'info, Mint>,
    
    /// CHECK: Metadata account
    #[account(mut)]
    pub metadata: UncheckedAccount<'info>,
    
    /// CHECK: Master edition account
    #[account(mut)]
    pub master_edition: UncheckedAccount<'info>,
    
    #[account(
        init_if_needed,
        payer = payer,
        seeds = [b"collection_token_account".as_ref()],
        bump,
        token::mint = collection_mint,
        token::authority = collection_token_account
    )]
    pub collection_token_account: InterfaceAccount<'info, TokenAccount>,
    
    pub token_program: Interface<'info, TokenInterface>,
    pub associated_token_program: Program<'info, AssociatedToken>,
    pub system_program: Program<'info, System>,
    pub token_metadata_program: Program<'info, Metadata>,
    pub rent: Sysvar<'info, Rent>,
}

#[derive(Accounts)]
#[instruction(challenge_data: BattleChallengeData, stake_amount: u64, commit_hash: [u8; 32], hashtags: Vec<String>)]
pub struct CreateBattleChallenge<'info> {
    #[account(mut)]
    pub challenger: Signer<'info>,
    
    #[account(
        mut,
        seeds = [b"battle_config".as_ref()],
        bump = battle_config.bump,
    )]
    pub battle_config: Account<'info, BattleConfig>,
    
    #[account(
        init,
        payer = challenger,
        space = 8 + Battle::INIT_SPACE,
        seeds = [b"battle".as_ref(), battle_config.battle_count.to_le_bytes().as_ref()],
        bump
    )]
    pub battle: Account<'info, Battle>,
    
    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
pub struct AcceptBattleChallenge<'info> {
    #[account(mut)]
    pub defender: Signer<'info>,
    
    #[account(
        mut,
        seeds = [b"battle".as_ref(), battle.battle_id.to_le_bytes().as_ref()],
        bump,
    )]
    pub battle: Account<'info, Battle>,
    
    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
pub struct CommitBattleRandomness<'info> {
    #[account(mut)]
    pub authority: Signer<'info>,
    
    #[account(
        seeds = [b"battle_config".as_ref()],
        bump = battle_config.bump,
    )]
    pub battle_config: Account<'info, BattleConfig>,
    
    #[account(
        mut,
        seeds = [b"battle".as_ref(), battle.battle_id.to_le_bytes().as_ref()],
        bump,
    )]
    pub battle: Account<'info, Battle>,
    
    /// CHECK: Switchboard randomness account
    pub randomness_account_data: UncheckedAccount<'info>,
    
    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
pub struct RevealTurnOrder<'info> {
    #[account(
        mut,
        seeds = [b"battle".as_ref(), battle.battle_id.to_le_bytes().as_ref()],
        bump,
    )]
    pub battle: Account<'info, Battle>,
    
    /// CHECK: Switchboard randomness account
    pub randomness_account_data: UncheckedAccount<'info>,
}

#[derive(Accounts)]
pub struct RevealBattleEntry<'info> {
    #[account(mut)]
    pub participant: Signer<'info>,
    
    #[account(
        mut,
        seeds = [b"battle".as_ref(), battle.battle_id.to_le_bytes().as_ref()],
        bump,
    )]
    pub battle: Account<'info, Battle>,
}

#[derive(Accounts)]
pub struct SubmitCommunityVote<'info> {
    #[account(mut)]
    pub voter: Signer<'info>,
    
    #[account(
        seeds = [b"battle".as_ref(), battle.battle_id.to_le_bytes().as_ref()],
        bump,
    )]
    pub battle: Account<'info, Battle>,
    
    #[account(
        init,
        payer = voter,
        space = 8 + CommunityVoterRecord::INIT_SPACE,
        seeds = [b"voter".as_ref(), battle.battle_id.to_le_bytes().as_ref(), voter.key().as_ref()],
        bump
    )]
    pub voter_record: Account<'info, CommunityVoterRecord>,
    
    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
pub struct FinalizeBattleResults<'info> {
    #[account(mut)]
    pub authority: Signer<'info>,
    
    #[account(
        seeds = [b"battle_config".as_ref()],
        bump = battle_config.bump,
    )]
    pub battle_config: Account<'info, BattleConfig>,
    
    #[account(
        mut,
        seeds = [b"battle".as_ref(), battle.battle_id.to_le_bytes().as_ref()],
        bump,
    )]
    pub battle: Account<'info, Battle>,
    
    /// CHECK: Winner account to receive payout
    #[account(mut)]
    pub winner: UncheckedAccount<'info>,
    
    /// CHECK: Organizer fee account
    #[account(mut)]
    pub organizer_fee_account: UncheckedAccount<'info>,
}

#[derive(Accounts)]
pub struct MintBattleEntryNFT<'info> {
    #[account(mut)]
    pub participant: Signer<'info>,
    
    #[account(
        seeds = [b"battle".as_ref(), battle.battle_id.to_le_bytes().as_ref()],
        bump,
    )]
    pub battle: Account<'info, Battle>,
    
    #[account(
        init,
        payer = participant,
        seeds = [b"entry_mint".as_ref(), battle.battle_id.to_le_bytes().as_ref(), participant.key().as_ref()],
        bump,
        mint::decimals = 0,
        mint::authority = collection_mint,
        mint::freeze_authority = collection_mint,
        mint::token_program = token_program
    )]
    pub entry_mint: InterfaceAccount<'info, Mint>,
    
    #[account(
        init,
        payer = participant,
        associated_token::mint = entry_mint,
        associated_token::authority = participant,
        associated_token::token_program = token_program,
    )]
    pub destination: InterfaceAccount<'info, TokenAccount>,
    
    #[account(
        mut,
        seeds = [b"metadata", token_metadata_program.key().as_ref(), entry_mint.key().as_ref()],
        bump,
        seeds::program = token_metadata_program.key(),
    )]
    /// CHECK: Metadata account
    pub metadata: UncheckedAccount<'info>,
    
    #[account(
        mut,
        seeds = [b"metadata", token_metadata_program.key().as_ref(), entry_mint.key().as_ref(), b"edition"],
        bump,
        seeds::program = token_metadata_program.key(),
    )]
    /// CHECK: Master edition account
    pub master_edition: UncheckedAccount<'info>,
    
    #[account(
        mut,
        seeds = [b"metadata", token_metadata_program.key().as_ref(), collection_mint.key().as_ref()],
        bump,
        seeds::program = token_metadata_program.key(),
    )]
    /// CHECK: Collection metadata
    pub collection_metadata: UncheckedAccount<'info>,
    
    #[account(
        mut,
        seeds = [b"metadata", token_metadata_program.key().as_ref(), collection_mint.key().as_ref(), b"edition"],
        bump,
        seeds::program = token_metadata_program.key(),
    )]
    /// CHECK: Collection master edition
    pub collection_master_edition: UncheckedAccount<'info>,
    
    #[account(
        mut,
        seeds = [b"battle_collection".as_ref()],
        bump,
    )]
    pub collection_mint: InterfaceAccount<'info, Mint>,
    
    pub associated_token_program: Program<'info, AssociatedToken>,
    pub token_program: Interface<'info, TokenInterface>,
    pub system_program: Program<'info, System>,
    pub token_metadata_program: Program<'info, Metadata>,
    pub rent: Sysvar<'info, Rent>,
}

#[derive(Accounts)]
pub struct CancelBattleEmergency<'info> {
    #[account(mut)]
    pub authority: Signer<'info>,
    
    #[account(
        seeds = [b"battle_config".as_ref()],
        bump = battle_config.bump,
    )]
    pub battle_config: Account<'info, BattleConfig>,
    
    #[account(
        mut,
        seeds = [b"battle".as_ref(), battle.battle_id.to_le_bytes().as_ref()],
        bump,
    )]
    pub battle: Account<'info, Battle>,
    
    /// CHECK: Challenger refund account
    #[account(mut)]
    pub challenger_refund: UncheckedAccount<'info>,
    
    /// CHECK: Defender refund account (optional)
    #[account(mut)]
    pub defender_refund: UncheckedAccount<'info>,
}

#[derive(Accounts)]
pub struct GetBattlesByCategory<'info> {
    #[account(
        seeds = [b"battle_config".as_ref()],
        bump = battle_config.bump,
    )]
    pub battle_config: Account<'info, BattleConfig>,
}

#[derive(Accounts)]
pub struct UpdateBattleCategorization<'info> {
    #[account(mut)]
    pub authority: Signer<'info>,
    
    #[account(
        seeds = [b"battle_config".as_ref()],
        bump = battle_config.bump,
    )]
    pub battle_config: Account<'info, BattleConfig>,
    
    #[account(
        mut,
        seeds = [b"battle".as_ref(), battle.battle_id.to_le_bytes().as_ref()],
        bump,
    )]
    pub battle: Account<'info, Battle>,
}