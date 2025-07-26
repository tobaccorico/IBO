
use anchor_lang::prelude::*;
use phf::phf_map;

pub static HEX_MAP: phf::Map<&'static str, &'static str> = phf_map! { 
    "XAU" => "0x765d2ba906dbc32ca17cc11f5310a89e9ee1f6420508c63861f2f8ba4ee34bb2", 
    "BTC" => "e62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43",
    // ...
}; 

pub static ACCOUNT_MAP: phf::Map<&'static str, &'static str> = phf_map! {
    "XAU" => "2uPQGpm8X4ZkxMHxrAW1QuhXcse1AHEgPih6Xp9NuEWW", 
    "BTC" => "4cSM2e6rvbGQUFiJbqytoVMi5GgghSMr8LwVrT9VPSPo",
    // ...
};

pub const MAX_LEN: usize = 8;
pub const MAX_AGE: u64 = 300; 

#[constant] 
// pub const USD_STAR: Pubkey = pubkey!("BenJy1n3WTx9mTjEvy63e8Q1j4RqUc6E4VBMz3ir4Wo6");
pub const USD_STAR: Pubkey = pubkey!("5qj9FAj2jdZr4FfveDtKyWYCnd73YQfmJGkAgRxjwbq6");
// ^ this is currently a mock token deployed on devnet, for testing purposes only...

#[error_code]
pub enum PithyQuip { 
    #[msg("If you are who you say you are, then you're not who you are.")]
    forOhfour,

    #[msg("Not under-collateralised...still gains to be realised.")]
    NotUndercollateralised,

    #[msg("Evict one of your other positons before trying to add a new one.")]
    MaxPositionsReached,
    
    #[msg("Think twice, make sure you pass in a price.")]
    NoPrice,    

    #[msg("Must pass in ticker(s).")]
    Tickers,

    #[msg("Don't call in too often...show stops then.")]
    TooSoon,

    #[msg("You're ahead...take profit instead.")]
    TakeProfit,
    
    #[msg("Imported a ticker that's not yet supported.")]
    UnknownSymbol,
    
    #[msg("Re-capitalise; your position is under-collateralised.")]
    Undercollateralised,

    #[msg("Slow it up...amount is either not enough or too much.")]
    InvalidAmount,

    #[msg("Double-check who you're trying to touch.")]
    InvalidUser,
    
    #[msg("We only work with stars here.")]
    InvalidMint,

    #[msg("Your position is over-exposed.")]
    OverExposed,

    #[msg("Your position is under-exposed.")]
    UnderExposed,
    
    #[msg("You must deposit before you can do this.")]
    DepositFirst,
  
    #[msg("Battle's done, the window's shut, no more time to strut your gut")]
    BattleWindowClosed,
    #[msg("Not enough to play this game, your stake's too low, what a shame")]
    InsufficientStake,
    #[msg("This battle's taken, can't you see? Find another, let it be")]
    BattleAlreadyAccepted,
    #[msg("Wrong phase mate, you're way too late, patience is your only fate")]
    InvalidBattlePhase,
    #[msg("Not your turn to spit that fire, wait your chance or you'll expire")]
    NotYourTurn,
    #[msg("Time has passed, your chance is blown, shoulda acted, now you're shown")]
    TurnExpired,
    #[msg("Votes don't match the math we need, recount now or don't proceed")]
    InvalidVoteCount,
    #[msg("Battle's live, can't run away, face the music, time to play")]
    BattleNotCancellable,
    #[msg("No authority to make that call, you're not the one who rules it all")]
    UnauthorizedAction,
    #[msg("Hash don't match, deception found, trust is broken, you're unbound")]
    InvalidCommitment,
    #[msg("Your verse is weak, your flow is whack, step it up or take it back")]
    InvalidBattleEntry,
    #[msg("Category's wrong, don't fit the song, check your tags where you belong")]
    InvalidCategory,
    #[msg("Already cast your vote today, can't vote twice, no child's play")]
    AlreadyVoted,
    #[msg("Battle's done but none have won, stalemate reached, no champion")]
    NoWinnerDetermined,
    #[msg("NFT's minted, can't make two, one per battle, that'll do")]
    NFTAlreadyMinted,
    #[msg("Config exists, can't make it twice, one setup should suffice")]
    ConfigAlreadyExists,
    #[msg("No config found to run this show, set it up before you go")]
    ConfigNotFound,
    #[msg("Collection's there, already made, can't duplicate what's been laid")]
    CollectionAlreadyExists,
    #[msg("Too many tags, you're overdoing, keep it simple, stop pursuing")]
    TooManyHashtags,
    #[msg("Difficulty's off, not in the range, pick a level, make a change")]
    InvalidDifficulty,
    #[msg("Recording's missing, where's your track? Need the audio, bring it back")]
    MissingRecording,
    #[msg("Verse structure's broken, fix your scheme, follow format, chase the dream")]
    InvalidVerseStructure,
}

// Event types for battle protocol
#[derive(AnchorSerialize, AnchorDeserialize, Clone, Debug)]
pub enum BattleEvent {
    BattleCreated {
        battle_id: u64,
        challenger: Pubkey,
        stake: u64,
        challenge_hash: [u8; 32],
    },
    BattleAccepted {
        battle_id: u64,
        defender: Pubkey,
        defender_hash: [u8; 32],
    },
    TurnOrderRevealed {
        battle_id: u64,
        first_rapper: Pubkey,
        second_rapper: Pubkey,
    },
    EntrySubmitted {
        battle_id: u64,
        rapper: Pubkey,
        entry_number: u8,
    },
    VoteSubmitted {
        battle_id: u64,
        voter: Pubkey,
        vote_type: VoteType,
        stake: u64,
    },
    BattleFinalized {
        battle_id: u64,
        winner: Option<Pubkey>,
        challenger_votes: u64,
        defender_votes: u64,
        total_pot: u64,
    },
    NFTMinted {
        battle_id: u64,
        recipient: Pubkey,
        mint: Pubkey,
    },
    BattleCancelled {
        battle_id: u64,
        reason: CancellationReason,
    },
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone, Debug, PartialEq)]
pub enum VoteType {
    Challenger,
    Defender,
    Draw,
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone, Debug)]
pub enum CancellationReason {
    Timeout,
    EmergencyCancel,
    NoDefender,
}

// Emit event helper
pub fn emit_battle_event(event: BattleEvent) -> Result<()> {
    emit!(event);
    Ok(())
}
