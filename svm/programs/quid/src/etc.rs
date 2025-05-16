
use anchor_lang::prelude::*;
use phf::phf_map;

pub static HEX_MAP: phf::Map<&'static str, &'static str> = phf_map! { 
    "XAU" => "0x765d2ba906dbc32ca17cc11f5310a89e9ee1f6420508c63861f2f8ba4ee34bb2", 
    "BTC" => "e62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43",
    // ...
}; // "drain the whole sea...get somethin' shiny...
// Auuuuuuuuu....56709...淋しさに Ah... 気づいてた Ah..."
pub static ACCOUNT_MAP: phf::Map<&'static str, &'static str> = phf_map! {
    "XAU" => "2uPQGpm8X4ZkxMHxrAW1QuhXcse1AHEgPih6Xp9NuEWW", 
    "BTC" => "4cSM2e6rvbGQUFiJbqytoVMi5GgghSMr8LwVrT9VPSPo",
    // ...
};

pub const MAX_LEN: usize = 8;
pub const MAX_AGE: u64 = 300; 

#[constant] 
// pub const USD_STAR: Pubkey = pubkey!("BenJy1n3WTx9mTjEvy63e8Q1j4RqUc6E4VBMz3ir4Wo6");
pub const USD_STAR: Pubkey = pubkey!("6QxnHc15LVbRf8nj6XToxb8RYZQi5P9QvgJ4NDW3yxRc");
// ^ this is currently a mock token deployed on devnet, for testing purposes only...

#[error_code]
pub enum PithyQuip { 
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
}
