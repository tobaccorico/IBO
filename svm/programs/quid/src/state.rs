
use anchor_lang::prelude::*;
use anchor_lang::solana_program::ed25519_program::ID as ED25519_ID;
use anchor_lang::solana_program::sysvar::instructions::{
    load_instruction_at_checked};

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
    pub authority: Pubkey,  // This will be the aggregated MPC public key
    pub min_stake: u64,
    pub battle_timeout: i64,
    #[max_len(12)] 
    pub judge_pubkeys: Vec<Pubkey>, // List of authorized judges
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

pub fn verify_ed25519_signature(
    pubkey: &Pubkey,
    message: &[u8],
    signature: &[u8; 64],
    instruction_sysvar: &AccountInfo,
) -> Result<()> {
    // The Ed25519 program precompile expects the signature verification
    // to be done in the previous instruction
    let ix = load_instruction_at_checked(0, instruction_sysvar)?;
    
    // Verify the instruction is for Ed25519 verification
    require_keys_eq!(ix.program_id, ED25519_ID, PithyQuip::UnauthorizedAction);
    
    // Verify the signature data matches
    let expected_data = [
        &[1u8][..], // Number of signatures
        &[0u8; 16][..], // Padding
        &signature[..], // Convert array reference to slice
        pubkey.as_ref(),
        message,
    ].concat();
    
    require!(ix.data == expected_data, PithyQuip::UnauthorizedAction);
    Ok(())
}

// Aggregate three signatures using simple XOR (in production, use proper MPC scheme)
pub fn aggregate_signatures(
    sig1: &[u8; 64],
    sig2: &[u8; 64],
    sig3: &[u8; 64],
) -> [u8; 64] {
    let mut result = [0u8; 64];
    for i in 0..64 {
        result[i] = sig1[i] ^ sig2[i] ^ sig3[i];
    }
    result
}

// Verify the aggregated signature represents the authority
pub fn verify_aggregated_authority(
    authority: &Pubkey,
    message: &[u8],
    aggregated_sig: &[u8; 64],
) -> Result<()> {
    // In a real MPC implementation, this would verify that the
    // aggregated signature is valid under the combined public key
    // For now, we use a simplified check
    
    // The authority pubkey should be derived from the MPC setup
    // This is a placeholder - implement actual MPC verification
    Ok(())
}

// Function to recover public key from signature (placeholder)
pub fn recover_pubkey_from_signature(
    message: &[u8],
    signature: &[u8; 64],
) -> Result<Pubkey> {
    // In production, implement Ed25519 public key recovery
    // For now, return a placeholder
    Ok(Pubkey::default())
}