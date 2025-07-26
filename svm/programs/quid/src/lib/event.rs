use anchor_lang::prelude::*;
use crate::lib::battle_state::{BattleCategoryType, DifficultyTier, BattleVote};

// Events
#[event]
pub struct BattleConfigInitialized {
    pub config: Pubkey,
    pub authority: Pubkey,
    pub min_stake: u64,
    pub organizer_fee: u16,
}

#[event]
pub struct BattleChallengeCreated {
    pub battle_id: u64,
    pub challenger: Pubkey,
    pub challenged_user: String,
    pub stake_amount: u64,
    pub twitter_url: String,
    pub sic_code: String,
    pub battle_category: BattleCategoryType,
    pub difficulty_tier: DifficultyTier,
}

#[event]
pub struct BattleChallengeAccepted {
    pub battle_id: u64,
    pub defender: Pubkey,
    pub total_pot: u64,
}

#[event]
pub struct BattleRandomnessCommitted {
    pub battle_id: u64,
    pub randomness_account: Pubkey,
}

#[event]
pub struct BattleTurnOrderRevealed {
    pub battle_id: u64,
    pub challenger_goes_first: bool,
    pub edit_window_end: i64,
}

#[event]
pub struct BattleEntryRevealed {
    pub battle_id: u64,
    pub participant: Pubkey,
    pub verse_count: usize,
}

#[event]
pub struct CommunityVoteSubmitted {
    pub battle_id: u64,
    pub voter: Pubkey,
    pub vote: BattleVote,
    pub stake_amount: u64,
}

#[event]
pub struct BattleFinalized {
    pub battle_id: u64,
    pub winner: Pubkey,
    pub winner_payout: u64,
    pub organizer_fee: u64,
}

#[event]
pub struct BattleEntryNFTMinted {
    pub battle_id: u64,
    pub participant: Pubkey,
    pub mint: Pubkey,
}

#[event]
pub struct BattleCancelled {
    pub battle_id: u64,
    pub refund_amount: u64,
}

#[event]
pub struct BattleCategoryQueried {
    pub category: BattleCategoryType,
    pub difficulty_tier: Option<DifficultyTier>,
    pub result_count: usize,
}

#[event]
pub struct BattleCategorization {
    pub battle_id: u64,
    pub new_sic_code: String,
    pub new_category: BattleCategoryType,
    pub new_difficulty: DifficultyTier,
}