
use anchor_lang::prelude::*;
use crate::stay::Position;
use std::str::FromStr;
use phf::phf_map;

use pyth_solana_receiver_sdk::price_update::{
    get_feed_id_from_hex, PriceUpdateV2
};

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
}

pub fn fetch_price(ticker: &str, account_info: &AccountInfo) -> Result<u64> {
    let hex = HEX_MAP.get(ticker).ok_or(PithyQuip::UnknownSymbol)?;
    let mut data: &[u8] = &account_info.try_borrow_data()?;
    let price_update = PriceUpdateV2::try_deserialize(&mut data)?;
    let feed_id = get_feed_id_from_hex(hex)?;
    let price = price_update.get_price_no_older_than(&Clock::get()?, MAX_AGE, &feed_id)?;
    let adjusted_price = (price.price as f64) * 10f64.powi(price.exponent as i32);
    Ok(adjusted_price as u64)
}

pub fn fetch_multiple_prices(positions: &[Position], remaining_accounts: &[AccountInfo]) -> Result<Vec<u64>> {
    let mut prices = Vec::new();
    for pos in positions {
        let ticker = std::str::from_utf8(&pos.ticker)
            .map_err(|_| PithyQuip::UnknownSymbol)?
            .trim_end_matches('\0');
        let key = ACCOUNT_MAP.get(ticker).ok_or(PithyQuip::UnknownSymbol)?;
        let pubkey = Pubkey::from_str(key).map_err(|_| PithyQuip::UnknownSymbol)?;
        let acct_info = remaining_accounts
            .iter()
            .find(|a| a.key == &pubkey)
            .ok_or(PithyQuip::Tickers)?;
        prices.push(fetch_price(ticker, acct_info)?);
    }
    Ok(prices)
}

/// Update exponential moving average
/// alpha is the smoothing factor (higher = faster response)
pub fn update_ema(old_value: u64, new_value: u64, alpha: u8) -> u64 {
    // EMA = α * new_value + (1 - α) * old_value
    // Using fixed point math to avoid floats
    let alpha_q16 = ((alpha as u64) << 16) / 10; // Convert to Q16 fixed point
    let one_minus_alpha_q16 = (1 << 16) - alpha_q16;
    
    let ema_q16 = (alpha_q16 * new_value) + (one_minus_alpha_q16 * old_value);
    ema_q16 >> 16 // Convert back from Q16
}

/// Compute raw interest rate based on utilization and payout metrics
/// Returns rate in basis points (bps)
pub fn compute_rate_raw(
    util_q32: u64,      // Current utilization in Q32 fixed point
    payout_q32: u64,    // Current payout ratio in Q32 fixed point
    ma_util: u64,       // Moving average utilization
    ma_payout: u64,     // Moving average payout
    current_rate_bps: u16, // Current rate for self-scaling
) -> u16 {
    // Base rate calculation using utilization curve
    // Higher utilization → higher rates to incentivize deposits
    let util_pct = (util_q32 >> 25) as u16; // Convert Q32 to percentage (approx)
    
    // Kink at 80% utilization
    let base_rate = if util_pct < 80 {
        // Linear up to 80%: 0% at 0 util, 10% at 80% util
        (util_pct * 1000) / 80 // Results in bps (basis points)
    } else {
        // Steep increase after 80%: 10% at 80%, 50% at 100%
        1000 + ((util_pct - 80) * 4000) / 20
    };
    
    // Payout adjustment - higher payouts INCREASE rates
    // This protects depositors by incentivizing new deposits when many are taking profits
    let payout_pct = (payout_q32 >> 25) as u16;
    let payout_premium = if payout_pct > 20 {
        // Increase rate if payouts exceed 20% of deposits
        ((payout_pct - 20) * 1000) / 80 // Max 1000bps increase
    } else if payout_pct > 10 {
        // Moderate increase for 10-20% payouts
        ((payout_pct - 10) * 300) / 10
    } else {
        0
    };
    
    // Volatility premium - compare current vs moving average
    let util_volatility = util_q32.abs_diff(ma_util << 32) >> 32;
    let payout_volatility = payout_q32.abs_diff(ma_payout << 32) >> 32;
    let volatility_premium = ((util_volatility + payout_volatility) / 2).min(200) as u16;
    
    // Self-scaling factor - rates adjust based on current level
    let scale_factor = if current_rate_bps > 2000 {
        90 // Dampen changes when rates are high
    } else if current_rate_bps < 500 {
        110 // Amplify changes when rates are low
    } else {
        100
    };
    
    // Final rate calculation
    let raw_rate = base_rate + volatility_premium + payout_premium;
    let scaled_rate = (raw_rate as u32 * scale_factor) / 100;
    
    // Clamp between 50bps (0.5%) and 5000bps (50%)
    scaled_rate.max(50).min(5000) as u16
}
