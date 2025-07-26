use anchor_lang::prelude::*;

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