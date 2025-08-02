
use anchor_lang::prelude::*;

#[account]
#[derive(InitSpace)]
pub struct Battle {
    pub battle_id: u64,
    pub challenger: Pubkey,
    pub defender: Pubkey,
    pub stake_amount: u64,
    
    pub challenger_ticker: [u8; 8], 
    pub defender_ticker: [u8; 8],
    
    #[max_len(43)]
    pub challenger_tweet_uri: String, 
    // ^ challenger's initial tweet
    // maximum length following x.com :
    // / + 15 max (username) + /status/ + 19 (ID)
    // = 1 + 15 + 8 + 19 = **43 characters**
    
    #[max_len(43)]
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
    PartialEq,
    InitSpace)]
pub enum BattlePhase {
    Open, Active,
    Completed,
}

#[account]
#[derive(InitSpace)]
pub struct BattleConfig {
    pub authority: Pubkey,
    pub min_stake: u64,
    pub battle_timeout: i64,
}

#[error_code]
pub enum PithyQuip { 
    #[msg("Imported a ticker that's not yet supported.")]
    UnknownSymbol,

    #[msg("Not enough to play this game, your stake's too low, what a shame")]
    InsufficientStake,
    
    #[msg("Wrong phase mate, you're way too late, patience is your only fate")]
    InvalidBattlePhase,
    
    #[msg("Not your turn to spit that fire, wait your chance or you'll expire")]
    NotYourTurn,
    
    #[msg("No authority to make that call, you're not the one who rules it all")]
    UnauthorizedAction,
}
