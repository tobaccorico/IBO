use anchor_lang::prelude::*;
use std::f32::consts::E;

use crate::etc::{ 
    MAX_AGE, update_ema,
    compute_rate_raw, 
    PithyQuip, MAX_LEN
};

#[derive(AnchorSerialize, 
    AnchorDeserialize, 
    Clone, Copy, Debug, 
    PartialEq, Eq)]
pub struct Position {
    // (b"GOOGL\0\0\0")
    pub ticker: [u8; 8], 
    pub pledged: u64,
    pub exposure: i64,
    // ^ same precision
    // as USD* (10^6)
    pub updated: i64
} 
impl Space for Position {
    const INIT_SPACE: 
    usize = 8 + 8 + 8 + 8; 
}

#[account]
#[derive(InitSpace)]
pub struct Depository {
    pub last_updated: i64,
    pub total_deposits: u64, 
    pub total_deposit_seconds: u128, 
    // ^ the faster one enter & exit, 
    // the less of an accrued yield
    // one can take (slower, loyal
    // depositors get more, pro rata)
    pub sum_tp_paid: u128,
    pub ma_util: u64,
    pub ma_payout: u64,
    pub dyn_rate_bps: u16,
    pub last_rate_change: i16,
    pub high_vol_flag: bool,
    // the above influences:
    pub interest_rate: u64,
    pub total_drawn: u64, 
    // ^ leverage exposure
} 

impl Depository {
    pub fn reprice(&mut self) {
        if self.total_deposits == 0 { return; }

        // Calculate current utilization (how much is drawn vs total deposits)
        let util_q32 = ((self.total_drawn  as u128) << 32) /  self.total_deposits as u128;
        // Calculate payout ratio (how much has been paid out as take profits)
        let payout_q32 = ((self.sum_tp_paid as u128) << 32) / (self.total_deposits as u128 + 1);

        // Volatility detection → toggle fast/slow EMA based on utilization swings
        let swing = util_q32.abs_diff(self.ma_util as u128) >> 32;
        if swing > 10 { self.high_vol_flag = true;  } // High volatility threshold
        if swing <  2 { self.high_vol_flag = false; } // Low volatility threshold

        // EMA smoothing speeds - faster during high volatility
        let alpha_u = if self.high_vol_flag { 2 } else { 3 }; // utilization EMA
        let alpha_p = if self.high_vol_flag { 4 } else { 5 }; // payout EMA

        // Update moving averages using math module functions
        self.ma_util = update_ema(self.ma_util, util_q32 as u64, alpha_u);
        self.ma_payout = update_ema(self.ma_payout, payout_q32 as u64, alpha_p);

        // Calculate new raw interest rate using sophisticated math model
        let raw = compute_rate_raw(
            util_q32 as u64,   // Current utilization
            payout_q32 as u64, // Current payout ratio
            self.ma_util,      // Historical utilization EMA
            self.ma_payout,    // Historical payout EMA
            self.dyn_rate_bps, 
        );

        // Velocity damping – halve rate change
        // on direction flip to prevent oscillation
        let delta = raw as i16 - self.dyn_rate_bps as i16;
        let new_rate = if delta * self.last_rate_change < 0 {
            // Direction changed, dampen the movement
            (self.dyn_rate_bps as i16 + delta / 2) as u16
        } else { // Same direction, apply full change
            raw 
        };
        self.last_rate_change = delta;
        self.dyn_rate_bps = new_rate;
        self.interest_rate = new_rate as u64; 
    }
    
    /// Update take profit tracking when a position is closed profitably
    /// This is called from instruction handlers as total_deposits is adjusted
    pub fn record_take_profit(&mut self, amount: u64) {
        self.sum_tp_paid += amount as u128;
        // Don't double-count by adjusting total_deposits here
        // Trigger repricing since take profit affects payout ratio
        self.reprice();
    }
    
    /// Update utilization when positions are opened/closed
    /// tracks total amount at risk (value of all positions)
    pub fn utilisation(&mut self, drawn_change: i64) {
        if drawn_change > 0 {
            self.total_drawn += drawn_change as u64;
        } else {
            self.total_drawn = self.total_drawn.saturating_sub((-drawn_change) as u64);
        }
        self.reprice();
    }
}

// naive timestamping: it over-weights early dust deposits;
// can be gamed by adding size later to inherit "old" age.
// To prevent this, we use dollar-seconds, time-weighted 
// deposit value, updated continuously to stay accurate.

#[account]
#[derive(InitSpace)]
pub struct Depositor {
    pub owner: Pubkey,
    pub deposited_usd_star: u64,
    pub deposit_seconds: u128,
    pub last_updated: i64,
    #[max_len(MAX_LEN)]
    pub balances: Vec<Position>,
    // TODO support up to 200
    // if this fits into storage
    // of a single account...
}

impl Depositor {    
    fn pad_ticker(ticker: &str) -> [u8; 8] {
        let mut padded_ticker = [0u8; 8];
        let ticker_bytes = ticker.trim().as_bytes();
        let len = ticker_bytes.len().min(8);
        padded_ticker[..len].copy_from_slice(&ticker_bytes[..len]);
        padded_ticker
    }

    // payments depend not only on time elapsed, but also on the value of debt at time of payment 
    // using a floating rate that is reflexive/adaptive with respect to inflow/outflow behavior...
    fn calculate_accrued_interest(principal: u64, time_elapsed: f32, interest_rate: f32) -> f64 {
        return principal as f64 * E.powf(interest_rate / (100 as f32) * time_elapsed) as f64;
    } // At she first seemed really interested, then she told me I should go see a shrink.
    // Position shrinking means "virtual sale": profitable synthetic redemption withdraws
    // Banks.total_deposits (more than pledged); similar to a collar (hedge wrapper), one
    // strategy for protecting against losses...though it limits large gains (under 10%).
    // Some cynic wrote on Twitter that "Ostium is broken," reason being unbounded gains
    // for borrowers dilute depositors' yield; following solution is a game of playing
    // on the edge, always waiting for her next move, yearning for a slightest tingle.
    pub fn repo(&mut self, ticker: &str, // reposition, or repossession (it depends)
        mut amount: i64, price: u64, current_time: i64,
        interest_rate: u64, depository: &mut Depository) -> Result<(i64, u64)> {
        let padded = Self::pad_ticker(ticker);
        // the ticker must already be present in depositor's balances...
        if let Some(pod) = self.balances.iter_mut().find(
                             |pod| pod.ticker == padded) {
            // Instead of fixed calculation, base it on system utilization
            let util_factor = if depository.total_deposits > 0 {
                let util_pct = (depository.total_drawn * 100) / depository.total_deposits;
                // Scale liquidation: 1% at low util, up to 10% at high util
                    1 + (util_pct.min(90) / 10)
            } else { 1 }; // default is 1%       
            let mut exposure: u64 = pod.exposure.abs() as u64;
            let time_elapsed: f32 = (current_time - pod.updated) as f32;
            let mut accrued_interest = Self::calculate_accrued_interest(
            exposure, time_elapsed, interest_rate as f32) as u64;
        
            accrued_interest = (accrued_interest - exposure) * price;
            pod.pledged -= accrued_interest; let mut delta: u64;
            if pod.exposure > 0 || (pod.exposure == 0 && amount > 0) {
                // if increasing exposure for long...it must not be
                // either worth > pledged, or less than 10%
                // same for decreasing, except that whole 
                // amount can be decreased to take profit
                // before we apply changes to exposure, 
                // run checks against current ^^^^^^^^
                exposure *= price; // < 0 if started as 0
                delta = pod.pledged + pod.pledged / 10;
                // for the first clause, amount irrelevant
                // (contains solely a preventative intent)
                // unless amount == 0 (liquidator caller)
                if exposure > delta { // must take profit
                    delta = exposure - delta; // unless:
                    delta += delta / 250; // ликарь cut... 
                    if self.deposited_usd_star >= delta { 
                        // buying more exposure impacts P&L
                        // instead extending uptrend ride 
                        self.deposited_usd_star -= delta;
                        pod.pledged += delta - delta / 250;
                        pod.updated = current_time;
                        // Update utilization for new exposure
                        depository.utilisation(delta as i64);
                        return Ok((delta as i64, accrued_interest));
                    } // need to burn ^ from depository's shares...
                    else if amount != 0 { // caller is not liquidator;
                        // if your profit is too much, you can only TP 
                        // when it's 10% above the max profitabiltiy, as
                        // you caller deducts from Banks.total_deposits...
                        return Err(PithyQuip::Undercollateralised.into());
                        // can't increase exposure or TP (collar constraint)...
                    } // "this is beginning to feel like the bolt busted loose from 
                    // the lever...I'm trying to reconstruct the air and all that it  
                    // brings...oxidation is the compromise you own...if you plant 
                    // ice...then harvest wind..from a static explosion," amortised.
                    else if amount == 0 { // < function got called by a liquidator...
                    // it means profit attribution that should belong to 1 depositor
                    // is actually getting appropriated by all depositors, slowly, 
                    // giving the depositor time to react and close their position
                        require!(time_elapsed < MAX_AGE as f32, PithyQuip::TooSoon);
                        // delta = ((pod.exposure as f32 * // amortised over 4 days...
                        //     (time_elapsed / MAX_AGE as f32)) / 1152 as f32) as u64; 

                        delta = ((pod.exposure.abs() as f32 * 
                            (time_elapsed / MAX_AGE as f32)) / 
                            (1152 as f32 / util_factor as f32)) as u64;
                        
                        pod.exposure -= delta as i64; 
                        delta *= price; // to dollars;
                        pod.pledged -= delta; // сlip
                        pod.updated = current_time;
                        
                        // Update utilization (position size decreased)
                        depository.utilisation(-(delta as i64));
                        // Don't record take profit, happens when 
                        // calling instruction (avoids double-count)
                        
                        return Ok(((delta as i64 * -1), accrued_interest));
                    } // ^ (-) indicates amount is (+) to Banks.total_deposits
                // as it performs a credit (ditto for UniV4's PoolManager) and
                // pays the liquidator a small cut (delta - 0.05% gets absorbed)
                } else { // long hasn't exceeded max growth 
                    delta = pod.pledged - pod.pledged / 10;
                    if  delta > exposure && exposure > 0 { 
                        // exceeding maximum drop of 10% sostate
                        // first, try to prevent liquidation:
                        delta -= exposure + pod.pledged / 10;
                        delta += delta / 250; // < ликарь cut 
                        if self.deposited_usd_star >= delta {
                            self.deposited_usd_star -= delta;
                            pod.exposure += ((delta - delta / 250) as f32 
                                                            / price as f32) as i64;          
                            pod.updated = current_time;
                            // Track increased exposure
                            depository.utilisation(delta as i64);
                            return Ok((delta as i64, 
                                accrued_interest));
                        } 
                        else if amount == 0 {
                            require!(time_elapsed < MAX_AGE as f32, PithyQuip::TooSoon);
                            // delta = ((pod.exposure as f32 * // amortised over 4 days...
                            //    (time_elapsed / MAX_AGE as f32)) / 1152 as f32) as u64; 
                            
                            delta = ((pod.exposure.abs() as f32 * 
                                (time_elapsed / MAX_AGE as f32)) / 
                                (1152 as f32 / util_factor as f32)) as u64;
                            
                            pod.updated = current_time;
                            pod.exposure -= delta as i64; 
                            delta *= price; // to dollars;
                            pod.pledged -= delta; // deduct liquidated value...
                            depository.utilisation(-(delta as i64));
                            return Ok(((delta as i64 * -1), accrued_interest));
                        } else { // ^ total deposits ^ incremented plus ^
                            return Err(PithyQuip::Undercollateralised.into());
                        }  
                    } require!(amount != 0, PithyQuip::InvalidAmount);
                    pod.exposure += amount as i64; // apply reposition
                    if amount < 0 { // trying to redeem units,
                        // this reduces exposure and pledged
                        if pod.exposure < 0 { 
                            // decreased too far... 
                            // with negative amount
                            amount += -pod.exposure;
                            pod.exposure = 0; 
                        } 
                        delta = -amount as u64 * price;
                        // ^ the $ value to be sent to 
                        // depositor is accounted as:
                        if delta > pod.pledged { // all-in TP...
                            exposure = delta; // < total transfer
                            delta -= pod.pledged + accrued_interest;
                            // ^ amount to be deducted from total_deposits
                            // should exclude accrued_interest (retained):
                            // we already deducted it once (at the start),
                            // but usually we append it; here we deduct
                            // it twice only because we don't append it
                            // in out.rs (accrued is interpreted as TP)
                            pod.pledged = 0; accrued_interest = exposure;
                            // Note: record_take_profit happens in instruction handler
                        } // otherwise, it's only a partial TP, just in 
                        // case the price will increase even more later
                        else { accrued_interest = delta - accrued_interest;
                            pod.pledged -= delta; delta = 0; // < no need to 
                            // Note: record_take_profit happens in instruction handler
                        } 
                        pod.updated = current_time; // reduces total_deposits
                        depository.utilisation(-(-amount as i64 * price as i64));
                        return Ok((((delta as i64) * -1), accrued_interest));
                    // interest represents amount to transfer...this includes 
                    // both what was pledged and remainder from total_deposits
                    } else { // amount is greater than zero (exposure issuance)
                        exposure = pod.exposure as u64 * price;
                        delta = pod.pledged + pod.pledged / 10;
                        if exposure > delta { // too profitable
                            delta = exposure - delta;
                            if self.deposited_usd_star >= delta {
                                self.deposited_usd_star -= delta;
                                pod.pledged += delta;
                            } else {
                                pod.exposure -= ((delta / price) 
                                    as f32 / price as f32) as i64;
                            }
                        } else { delta = pod.pledged - pod.pledged / 10;
                                if delta > exposure {
                                    pod.exposure += ((delta - exposure) 
                                        as f32 / price as f32) as i64;
                                } // why would you put exposure above 
                            // and not at the current price? >10% drop 
                            // protection, leaves less room for upside...
                            delta = 0; // clear variable (it's returned)
                        } // exposure is less than 10% above pledged...
                        // but not less than 10% below pledged (valid)
                        pod.updated = current_time; // no burn shares
                        depository.utilisation(amount * price as i64);
                        return Ok((delta as i64, accrued_interest));
                    } 
                }
            } else { // short position: the same but different;
                // exposure can neither be worth 10% more nor
                // 10% less than the value of pod.pledged...
                exposure = -pod.exposure as u64 * price;
                let pivot: u64 = pod.pledged - pod.pledged / 10;
                if pivot >= exposure && exposure > 0 { 
                    // price dropped more than 10% this means
                    // must take profit regardless, lest repair
                    let mut delta = pivot - exposure;
                    delta += delta / 250; // liquidator's cut
                    // to try and repair the position against
                    // our deposits, we can't do the same as
                    // we do in longs (would only widen delta)
                    if self.deposited_usd_star >= delta {
                        self.deposited_usd_star -= delta;
                        // increasing exposure (buying the dip) to
                        // decreases the impact of price drop, but 
                        // only deducted (not added to pod.pledged) 
                        // as the increase in value is represented by 
                        pod.exposure += (((delta - delta / 250) as f32) 
                                                         / price as f32) as i64;
                        pod.updated = current_time; // track position adjustment
                        depository.utilisation(delta as i64);
                        return Ok((delta as i64, 
                                accrued_interest)); 
                    }
                    else if amount != 0 {// caller is not a liquidator...
                        return Err(PithyQuip::Undercollateralised.into());
                    } 
                    else { // lookin' too hot, simmer down cadence,
                    // "menace ou prière, l'un parle bien, l'autre 
                    // se tait; et c'est l'autre que je préfère..."
                    // unlike with longs, we don't shrink exposure 
                    // as this increases position's profitability
                        require!(time_elapsed < MAX_AGE as f32, PithyQuip::TooSoon);
                        delta = ((pod.exposure.abs() as f32 * // amortised over 4 days
                            (time_elapsed / MAX_AGE as f32)) / 1152 as f32) as u64; 
                            
                        pod.updated = current_time;
                        pod.exposure += delta as i64;
                        // ^ adding positive numebr to
                        // negative exposure shrinks it,
                        // a forced buy by depositors,
                        // so they get paid pro rata
                        // to cancel out (ceteris...)
                        pod.pledged -= delta * price;
                        depository.utilisation(-(delta as i64 * price as i64));
                        return Ok(((delta as i64 * -1), 
                                    accrued_interest));
                    }
                } else if exposure > pivot || exposure == 0 {
                    // if the position is up more than 10% less 
                    delta = pod.pledged + pod.pledged / 10;
                    if exposure > delta { // < too much...
                        delta = exposure - delta;
                        delta += delta / 250;
                        if self.deposited_usd_star >= delta {
                            self.deposited_usd_star -= delta;
                            pod.pledged += delta - delta / 250;
                            pod.updated = current_time;
                            depository.utilisation(delta as i64);
                            return Ok((delta as i64, 
                                    accrued_interest));
                        } 
                        else if amount == 0 {
                            require!(time_elapsed < MAX_AGE as f32, PithyQuip::TooSoon);
                            // delta = ((pod.exposure.abs() as f32 * // amortised over 4 days
                            //    (time_elapsed / MAX_AGE as f32)) / 1152 as f32) as u64;
                            delta = ((pod.exposure.abs() as f32 * 
                                (time_elapsed / MAX_AGE as f32)) / 
                                (1152 as f32 / util_factor as f32)) as u64;
                            
                            pod.exposure += delta as i64;
                            pod.pledged -= delta * price;
                            pod.updated = current_time;
                            depository.utilisation(-(delta as i64 * price as i64));
                            return Ok(((delta as i64 * -1), 
                                        accrued_interest));
                        }
                        else { // upside has made this short too unprofitable
                            return Err(PithyQuip::Undercollateralised.into());
                        }
                    } exposure = -pod.exposure as u64 * price;
                    // ^ save this value for P&L calculations
                    pod.exposure += amount as i64;
                    if amount > 0 && exposure > 0 { 
                        // redeem (burning exposure)
                        if pod.exposure > 0 { 
                            // decreased too far with positive amount
                            amount -= pod.exposure; pod.exposure = 0;
                        } // we calculate percentage we're redeeming:
                        let amt: f32 = amount as f32 / exposure as f32;
                        // percentage of the total profit we're about to absorb:
                        delta = (((pod.pledged - exposure) as f32) * amt) as u64;
                        delta -= accrued_interest; // < profit excludes interest
                        // decrease pledged by the same percentage in order 
                        // to prevent re-entry (continuous drawing of even 
                        // greater profit each time, as the delta between
                        // exposure and pledged widens more and more)...
                        amount = (pod.pledged as f32 * amt) as i64;
                        pod.pledged -= amount as u64;
                        pod.updated = current_time;
                        depository.utilisation(-(amount as i64 * price as i64));
                        return Ok(((delta as i64) * -1, 
                        (delta as i64 + amount) as u64));
                    } 
                    else if amount < 0 { // exposure issuance...
                        exposure = -pod.exposure as u64 * price;
                        delta = pod.pledged + pod.pledged / 10;
                        if pod.pledged > exposure {
                            // ^ not a valid state unless we
                            // are taking profits (don't let 
                            // taking on more exposure while
                            // taking profit before TP first)
                            delta = pod.pledged - exposure;
                            if self.deposited_usd_star >= delta {
                                self.deposited_usd_star -= delta;
                                // subtract positive number to increase (-) exposure:
                                pod.exposure -= (delta as f32 / price as f32) as i64;
                                // ^ we are selling against ourselves, buying to burn
                                pod.updated = current_time; 
                                depository.utilisation(delta as i64);
                                return Ok((delta as i64, 
                                                                    accrued_interest));
                            } else { return Err(PithyQuip::UnderExposed.into()); }
                        } else if exposure > delta { // to prevent OverExposed,
                            // adding positive number shrinks negative exposure
                            pod.exposure += (((exposure - delta) as f32) 
                                                         / price as f32) as i64;
                            depository.utilisation(-((exposure - delta) as i64));
                        } 
                    } pod.updated = current_time; // why wouldn't a depositor just: 
                    return Ok((0, accrued_interest)); // select the smallest distance,
                   // (greater than pod.pledged) in order to maximise potential profit?
                } // maybe they know a big drop is ahead, and they want to minimise the
            } // chance they might be liquidated; either way we want to maximise control
        } else { return Err(PithyQuip::DepositFirst.into()); } 
        Ok((0,0)) 
    } 

     pub fn adjust_deposit_seconds(&mut self, amount_reduced: u64, current_time: i64) {
        if self.deposited_usd_star > 0 && amount_reduced > 0 {
            // Update time-weighted balance before adjustment
            let time_delta = (current_time - self.last_updated) as u64;
            self.deposit_seconds = self.deposit_seconds
                .saturating_add((time_delta * self.deposited_usd_star) as u128);
            
            // Reduce deposit_seconds proportionally
            // let reduction_ratio = amount_reduced.min(self.deposited_usd_star) as u128;
            let remaining_ratio = self.deposited_usd_star.saturating_sub(amount_reduced) as u128;
            
            if self.deposited_usd_star > 0 {
                self.deposit_seconds = self.deposit_seconds
                    .checked_mul(remaining_ratio)
                    .and_then(|v| v.checked_div(self.deposited_usd_star as u128))
                    .unwrap_or(0);
            }
            
            self.last_updated = current_time;
        }
    }

    /* This function handles collateral adjustments (adding or removing pledged dollars
     * or deposited); safety-first: ensures collateralisation constraints are respected. */
    pub fn renege(&mut self, ticker: Option<&str>, mut amount: i64, 
        prices: Option<&Vec<u64>>, current_time: i64) -> Result<i64> { // pod: подушка
        if ticker.is_none() && amount < 0 { // removing collateral from every position
            // First, we must sort positions by descending amount (without reallocating)
            self.balances.sort_by(|a, b| b.pledged.cmp(&a.pledged));
            // Bigger they come, harder they fall
            let mut deducting: u64 = amount.abs() as u64;
            for i in 0..self.balances.len() {
                if deducting == 0 { break; } 
                let pod = &mut self.balances[i];
                let price = prices.as_ref().unwrap()[i];
                let max: u64 = if pod.exposure > 0 {
                    (pod.pledged + pod.pledged / 10) - 
                     pod.exposure as u64 * price 
                } 
                else if pod.exposure < 0 {
                // we don't have to worry about if 
                // pledged - 10% will be worth more 
                // than exposure, as (theoretically)
                // by that point it's liquidated...
                    (-pod.exposure as u64) * price - 
                    (pod.pledged - pod.pledged / 10)
                } 
                else { pod.pledged };
                let deducted = max.min(deducting);
        
                pod.pledged -= deducted;
                deducting -= deducted;
            }
            amount = deducting as i64; // < remainder (out & clutch)
        } 
        else { // remove or add dollars to one specific position...
            let padded = Self::pad_ticker(ticker.unwrap());
            if let Some(pod) = self.balances.iter_mut().find(
                                 |pod| pod.ticker == padded) {
                let price = prices
                                .and_then(|p| p.first())
                                .copied() // Convert &u64 to u64
                                .unwrap_or(0);
                if pod.exposure != 0 && price == 0 {
                    return Err(PithyQuip::NoPrice.into());    
                }
                let exposure = pod.exposure.abs() as u64 * price;
                // deducting...we check the max, same as we did above,
                // with a slightly different approach (why not, right?) 
                if amount < 0 { require!(pod.pledged >= -amount as u64, 
                                            PithyQuip::InvalidAmount);
                    if pod.exposure < 0 { 
                        // short position
                        if exposure > pod.pledged {
                            let max: i64 = (( // calculate most we can deduct
                                (pod.pledged / 10) - (exposure - pod.pledged)
                            ) as i64) * -1;
                            amount = max.max(amount); // in absolute value
                            // terms this ^ actually returns smaller one...
                        }
                        else if pod.pledged > exposure {
                            // short is in-the-money, so
                            // it doesn't make sense to
                            // decrease collateral as it
                            // would diminish profitability
                            return Err(PithyQuip::TakeProfit.into());
                        }
                    } else if pod.exposure > 0 { 
                        let mut max: u64 = 0; 
                        // most we can deduct
                        if pod.pledged >= exposure {
                            max = (pod.pledged / 10) - (pod.pledged - exposure);
                        }
                        else if exposure > pod.pledged {
                            max = (pod.pledged / 10) - (exposure - pod.pledged);
                        }
                        amount = (max.min(-amount as u64) as i64) * -1;
                    }
                    pod.pledged -= -amount as u64;
                } 
                else { // amount is > 0 
                    if pod.exposure < 0 {
                        if exposure > pod.pledged { // simple enough here, not 
                            // sure why anyone would do this, but it's doable...
                            amount = amount.min((exposure - pod.pledged) as i64);
                        }
                        else if pod.pledged > exposure {
                            // short is in-the-money; throw as
                            // would be like cheating otherwise
                            // as adding collateral widens the
                            // delta (i.e. profitability, what's
                            // deducted from bank.total_deposits)...
                            return Err(PithyQuip::TakeProfit.into());
                        }
                    } else if pod.exposure > 0 {
                        let mut max: u64 = 0; 
                        // most we can deduct
                        if pod.pledged >= exposure {
                            max = (pod.pledged / 10) - (pod.pledged - exposure);
                        }
                        else if exposure > pod.pledged {
                            max = (exposure + exposure / 10) - pod.pledged;
                        }   amount = max.min(amount as u64) as i64;
                    }       pod.pledged += amount as u64;
                } 
                amount = 0; 
                self.last_updated = current_time; 
             
            } else { require!(amount > 0, 
                PithyQuip::InvalidAmount);
                if self.balances.len() >= MAX_LEN {
                    return Err(PithyQuip::MaxPositionsReached.into());
                }   self.balances.push(Position { ticker: padded,
                        pledged: amount as u64, exposure: 0, 
                        updated : current_time }); amount = 0;
            } // is in reposition, for maintenance purposes as is
        } self.balances.retain(|pod| pod.pledged > 10000000); 
        // if there is exposure it will automatically shrink (charging %) 
        Ok(amount) // < remainder must be returned if ticker was None...
    }    
}

pub fn stake_from_depositor_cpi<'info>(
    depositor_account: &Account<'info, Depositor>,
    depository_account: &Account<'info, Depository>,
    amount: u64,
    use_time_weighted: bool,
) -> Result<u64> {
    let stake_value = if use_time_weighted {
        // Calculate the depositor's proportional share based on time-weighted contribution
        let depositor_share_ratio = depositor_account.deposit_seconds
            .checked_div(depository_account.total_deposit_seconds)
            .unwrap_or(0);
        
        // Apply ratio to current total deposits to get available stake
        let available_stake = (depository_account.total_deposits as u128)
            .saturating_mul(depositor_share_ratio)
            .checked_div(1_000_000) // Normalize if using fixed point math
            .unwrap_or(0)
            .min(depositor_account.deposited_usd_star as u128) // Can't exceed actual deposits
            .min(amount as u128) as u64;
      
        available_stake
    } else {
        // Simple current balance check
        depositor_account.deposited_usd_star.min(amount)
    };   
    Ok(stake_value)
}

pub fn deduct_battle_stake<'info>(
    depositor: &mut Account<'info, Depositor>,
    depository: &mut Account<'info, Depository>,
    amount: u64, won: bool) -> Result<()> {
    if won { // Winner keeps 
        // their stake
        return Ok(());
    }   let now = Clock::get()?.unix_timestamp;    
    // Loser pays from deposited_usd_star first
    let deduction = amount.min(depositor.deposited_usd_star);
    depositor.deposited_usd_star -= deduction;

    // we don't deduct from total_deposits because (like liqudation)
    // If not enough in deposits, take from positions proportionally
    let remaining = amount - deduction;
    if remaining > 0 {
        let total_pledged: u64 = depositor.balances.iter().map(|p| p.pledged).sum();
        if total_pledged > 0 {
            for pos in depositor.balances.iter_mut() {
                let pos_share = (remaining * pos.pledged) / total_pledged;
                pos.pledged = pos.pledged.saturating_sub(pos_share);
            }
        }
    } depositor.last_updated = now; depository.last_updated = now;
    Ok(())
}
