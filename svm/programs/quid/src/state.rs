
use anchor_lang::prelude::*;

#[account]
#[derive(InitSpace)]
pub struct Battle {
    pub battle_id: u64,
    pub challenger: Pubkey,
    pub defender: Pubkey,
    pub stake_amount: u64,
    // TODO remove tickers they are completely irrelevant
    pub challenger_ticker: [u8; 8], 
    pub defender_ticker: [u8; 8],
    pub challenger_tweet_uri: String, 
    // ^ challenger's initial tweet
    pub defender_tweet_uri: String, 
    // Defender's reply tweet 
    // (must be reply to first
    // tweet in challenger's
    // thread of verses)...
    pub phase: BattlePhase,
    pub created_at: i64,
    pub winner: Option<Pubkey>,
}

#[derive(AnchorSerialize, 
    AnchorDeserialize, 
    Clone, Debug, 
    PartialEq)]
pub enum BattlePhase {
    Open,
    Active,
    Completed,
}

#[account]
#[derive(InitSpace)]
pub struct BattleConfig {
    pub authority: Pubkey,
    pub min_stake: u64,
    pub battle_timeout: i64,
    // pub oracle_function: Pubkey,
}
