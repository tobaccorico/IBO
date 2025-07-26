use anchor_lang::prelude::*;
use crate::lib::{inst, ctx::*, state::*};

declare_id!("ReChatBattleContract1234567890123456789012345678");

#[program]
pub mod raps {
    use super::*;

    pub fn initialize_battle_config(
        ctx: Context<InitializeBattleConfig>, 
        battle_window_start: u64,
        battle_window_end: u64, 
        min_stake_amount: u64,
        organizer_fee_bps: u16,
    ) -> Result<()> {
        inst::initialize_battle_config(
            ctx, battle_window_start, battle_window_end, min_stake_amount, organizer_fee_bps
        )
    }

    pub fn initialize_battle_collection(ctx: Context<InitializeBattleCollection>) -> Result<()> {
        inst::initialize_battle_collection(ctx)
    }

    pub fn create_battle_challenge(
        ctx: Context<CreateBattleChallenge>,
        challenge_data: BattleChallengeData,
        stake_amount: u64,
        commit_hash: [u8; 32],
        hashtags: Vec<String>,
    ) -> Result<()> {
        inst::create_battle_challenge(
            ctx, challenge_data, stake_amount, commit_hash, hashtags
        )
    }

    pub fn accept_battle_challenge(
        ctx: Context<AcceptBattleChallenge>,
        defender_commit_hash: [u8; 32],
        defender_response_url: String,
    ) -> Result<()> {
        inst::accept_battle_challenge(
            ctx, defender_commit_hash, defender_response_url
        )
    }

    pub fn commit_battle_randomness(ctx: Context<CommitBattleRandomness>) -> Result<()> {
        inst::commit_battle_randomness(ctx)
    }

    pub fn reveal_turn_order_and_start(ctx: Context<RevealTurnOrder>) -> Result<()> {
        inst::reveal_turn_order_and_start(ctx)
    }

    pub fn reveal_battle_entry(
        ctx: Context<RevealBattleEntry>,
        verses: Vec<BattleVerse>,
        recording_uri: String,
        nonce: u64,
    ) -> Result<()> {
        inst::reveal_battle_entry(ctx, verses, recording_uri, nonce)
    }

    pub fn submit_community_vote(
        ctx: Context<SubmitCommunityVote>,
        vote: BattleVote,
        stake_amount: u64,
    ) -> Result<()> {
        inst::submit_community_vote(ctx, vote, stake_amount)
    }

    pub fn finalize_battle_results(ctx: Context<FinalizeBattleResults>) -> Result<()> {
        inst::finalize_battle_results(ctx)
    }

    pub fn mint_battle_entry_nft(ctx: Context<MintBattleEntryNFT>) -> Result<()> {
        inst::mint_battle_entry_nft(ctx)
    }

    pub fn cancel_battle_emergency(ctx: Context<CancelBattleEmergency>) -> Result<()> {
        inst::cancel_battle_emergency(ctx)
    }

    pub fn get_battles_by_category(
        ctx: Context<GetBattlesByCategory>,
        category: BattleCategoryType,
        difficulty_tier: Option<DifficultyTier>,
        ) -> Result<Vec<u64>> {
        inst::get_battles_by_category(ctx, category, difficulty_tier)
    }

    pub fn update_battle_categorization(
        ctx: Context<UpdateBattleCategorization>,
        battle_id: u64,
        new_hashtags: Vec<String>,
    ) -> Result<()> {
        inst::update_battle_categorization(ctx, battle_id, new_hashtags)
    }
}