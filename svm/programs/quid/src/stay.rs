
use anchor_lang::prelude::*;
use core::time;
use std::f32::consts::E;
use crate::etc::{MAX_LEN, 
    PithyQuip, MAX_AGE};

#[derive(AnchorSerialize, 
    AnchorDeserialize, 
    Clone, Copy, Debug, 
    PartialEq, Eq)]
pub struct Position {
    // (e.g. b"GOOGL\0\0\0")
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
    pub total_deposits: u64, 
    pub total_deposit_shares: u64, 
    pub interest_rate: u64,
} 

#[account]
#[derive(InitSpace)]
pub struct Depositor {
    pub owner: Pubkey,
    pub deposited_usd_star: u64,
    pub deposited_usd_star_shares: u64, 
    
    #[max_len(MAX_LEN)]
    pub balances: Vec<Position>, 
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
    fn calculate_accrued_interest(principal: u64, time_elapsed: f32, interest_rate: f32) -> f64 {
        return principal as f64 * E.powf(interest_rate / (100 as f32) * time_elapsed) as f64;
    } // At first she seemed really interested, then she told me I should go see a shrink.
    // Position shrinking means "virtual sale": profitable synthetic redemption withdraws
    // Banks.total_deposits (more than pledged); similar to a collar (hedge wrapper), one
    // strategy for protecting against losses...though it limits large gains (under 10%).
    // Some cynic wrote on Twitter that "Ostium is broken," reason being unbounded gains
    // for borrowers dilute depositors' yield; following solution is a game of playing
    // on the edge, always waiting for her next move, yearning for a slightest tingle.
    pub fn reposition(&mut self, ticker: &str, 
        mut amount: i64, price: u64, current_time: i64,
        interest_rate: u64) -> Result<(i64, u64)> {
        let padded = Self::pad_ticker(ticker);
        // the ticker must already be present in depositor's balances...
        if let Some(pod) = self.balances.iter_mut().find(
                             |pod| pod.ticker == padded) {
            
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
                    delta = exposure - delta; // unless...
                    delta += delta / 250; // liquidator's cut 
                    if self.deposited_usd_star >= delta { 
                        // not buying more exposure (impacts P&L), just
                        // extending how long depositor can ride uptrend
                        self.deposited_usd_star -= delta;
                        pod.pledged += delta - delta / 250;
                        pod.updated = current_time;
                        return Ok((delta as i64, accrued_interest));
                    } // need to burn ^ from depository's shares...
                    else if amount != 0 { // caller is not liquidator...
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
                        delta = ((pod.exposure as f32 * // amortised over 4 days...
                             (time_elapsed / MAX_AGE as f32)) / 1152 as f32) as u64; 
                        
                        pod.exposure -= delta as i64; 
                        delta *= price; // to dollars;
                        pod.pledged -= delta; // deduct liquidated value...
                        pod.updated = current_time;
                        return Ok(((delta as i64 * -1), accrued_interest));
                    } // ^ (-) indicates amount is (+) to Banks.total_deposits
                // as it performs a credit (ditto for UniV4's PoolManager) and
                // pays the liquidator a small cut (delta - 0.05% gets absorbed)
                } else { // long hasn't exceeded max growth 
                    delta = pod.pledged - pod.pledged / 10;
                    if  delta > exposure && exposure > 0 { 
                        // exceeding maximum drop of 10% so
                        // first, try to prevent liquidation:
                        delta -= exposure; delta += delta / 250; 
                        // ^ liquidator cut (if one called)
                        if self.deposited_usd_star >= delta {
                            self.deposited_usd_star -= delta;
                            pod.exposure += ((delta - delta / 250) as f32 
                                                            / price as f32) as i64;          
                            pod.updated = current_time;
                            return Ok((delta as i64, 
                                accrued_interest));
                        } 
                        else if amount == 0 {
                            require!(time_elapsed < MAX_AGE as f32, PithyQuip::TooSoon);
                            delta = ((pod.exposure as f32 * // amortised over 4 days...
                                (time_elapsed / MAX_AGE as f32)) / 1152 as f32) as u64; 
                            
                            pod.updated = current_time;
                            pod.exposure -= delta as i64; 
                            delta *= price; // to dollars;
                            pod.pledged -= delta; // deduct liquidated value...
                            return Ok(((delta as i64 * -1), accrued_interest));
                        } else {
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
                        } // otherwise, it's only a partial TP, just in 
                        // case the price will increase even more later
                        else { accrued_interest = delta - accrued_interest;
                            pod.pledged -= delta; delta = 0; // < no need to 
                        } 
                        pod.updated = current_time; // reduces total_deposits
                        return Ok((((delta as i64) * -1), accrued_interest));
                    // interest represents amount to transfer...this includes 
                    // both what was pledged and remainder from total_deposits
                    } else { // amount is greater than zero...
                        exposure = pod.exposure as u64 * price;
                        delta = pod.pledged + pod.pledged / 10;
                        if exposure > delta { // too profitable
                            delta = exposure - delta;
                            if self.deposited_usd_star >= delta {
                                self.deposited_usd_star -= delta;
                                pod.pledged += delta;
                            } else {
                                return Err(PithyQuip::OverExposed.into());
                            }
                        } else {
                            delta = pod.pledged - pod.pledged / 10;
                            if delta > exposure {
                                pod.exposure += (delta - exposure) as i64;
                            }
                            delta = 0; // clear variable as it's returned
                        } // exposure is less than 10% above pledged...
                        // but not less than 10% below pledged (valid)
                        pod.updated = current_time; // no burn shares
                        return Ok((delta as i64, accrued_interest));
                    } 
                }
            } else { // short position: the same but different;
                // exposure can neither be worth 10% more nor
                // 10% less than the value of pod.pledged...
                exposure = -pod.exposure as u64 * price;
                let buffer: u64 = pod.pledged - pod.pledged / 10;
                if buffer >= exposure && exposure > 0 { 
                    // price dropped more than 10% this means
                    // must take profit regardless, lest repair
                    let mut delta = buffer - exposure;
                    delta += delta / 250; // liquidator's cut
                    // to try and repair the position against
                    // our deposits, we can't do the same as
                    // we do in longs (would only widen delta)
                    if self.deposited_usd_star >= delta {
                        self.deposited_usd_star -= delta;
                        // increasing exposure (buying the dip) 
                        // decreases the impact of price drop
                        pod.exposure -= (((delta - delta / 250) as f32) 
                                                         / price as f32) as i64;
                        pod.updated = current_time;
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
                        pod.pledged -= delta * price;
                        return Ok(((delta as i64 * -1), 
                                    accrued_interest));
                    }
                } else if exposure > buffer || exposure == 0 { 
                    delta = pod.pledged + pod.pledged / 10;
                    if exposure > delta { // < too much...
                        delta = exposure - delta;
                        delta += delta / 250;
                        if self.deposited_usd_star >= delta {
                            self.deposited_usd_star -= delta;
                            pod.pledged += delta - delta / 250;
                            pod.updated = current_time;
                            return Ok((delta as i64, 
                                    accrued_interest));
                        } 
                        else if amount == 0 {
                            require!(time_elapsed < MAX_AGE as f32, PithyQuip::TooSoon);
                            delta = ((pod.exposure.abs() as f32 * // amortised over 4 days
                                (time_elapsed / MAX_AGE as f32)) / 1152 as f32) as u64; 
                        
                            pod.exposure += delta as i64;
                            pod.pledged -= delta * price;
                            pod.updated = current_time;
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
                        // percentage of the total profit we're about to absorb
                        delta = (((pod.pledged - exposure) as f32) * amt) as u64;
                        delta -= accrued_interest; // < profit excludes interest
                        // decrease pledged by the same percentage in order 
                        // to prevent re-entry (continuous drawing of even 
                        // greater profit each time, as the delta between
                        // exposure and pledged widens more and more)...
                        amount = (pod.pledged as f32 * amt) as i64;
                        pod.pledged -= amount as u64;
                        pod.updated = current_time;
                        return Ok(((delta as i64) * -1, 
                        (delta as i64 + amount) as u64));
                    } 
                    else if amount < 0 { // exposure issuance...
                        exposure = -pod.exposure as u64 * price;
                        delta = pod.pledged + pod.pledged / 10;
                        if pod.pledged > exposure {
                            // ^ not a valid state unless we
                            // are taking profits (not the 
                            // case with this operation)...
                            delta = pod.pledged - exposure;
                            if self.deposited_usd_star >= delta {
                                self.deposited_usd_star -= delta;
                                // subtract positive number to increase (-)exposure:
                                pod.exposure -= (delta as f32 / price as f32) as i64;
                                pod.updated = current_time;
                                return Ok((delta as i64, accrued_interest));
                            } else {
                                return Err(PithyQuip::UnderExposed.into());
                            }
                        } else if exposure > delta { 
                            // to prevent OverExposed,
                            // adding a positive number
                            // shrinks negative exposure
                            pod.exposure += (
                                ((exposure - delta) as f32) 
                                    / price as f32) as i64;
                        } // why wouldn't a depositor just: 
                    } pod.updated = current_time; 
                    return Ok((0, accrued_interest)); // select the smallest distance,
                   // (greater than pod.pledged) in order to maximise potential profit?
                } // maybe they know a big drop is ahead, and they want to minimise the
            } // chance they might be liquidated; either way we want to maximise control
        } else { return Err(PithyQuip::DepositFirst.into()); } // no pay? 
        Ok((0,0)) // маг не я; schonen bestia, когда не заснуть никак без 
        // тебя..."I want the pill and the preacher who's gonna bless with 
        // it"...casta Diva, the B-book class in it...il dolce far niente, 
        // и после I repent to her, "take me to church, I worship like a," 
    } // collar strategy at the shrine of Diotima's lien, "ты шо грузин?" 
    // She said я ее перегрузил: "I beseech thee, vade retro rico." Such 
    // a QD, "only heaven I'll be sent to is when I'm alone with," quid!
    // Biggie малая, "in separation of subject from object; logic isn't 
    // final wisdom." ~ Линия Кэйё (herZen & the AMM) Atlantean Ланиакея
    // "constellation got a twist in it...a few stars about make it feel
    // like peace in a way...you inspire like the same did Salinger..."
    pub fn renege(&mut self, ticker: Option<&str>, mut amount: i64, 
        prices: Option<&Vec<u64>>, current_time: i64) -> Result<i64> { // pod: подушка
        if ticker.is_none() && amount < 0 { // removing collateral from every position
            // First, we must sort positions by descending amount (without reallocating)
            self.balances.sort_by(|a, b| b.pledged.cmp(&a.pledged));
            // Bigger they come, harder they fall
            let mut deducting: u64 = amount as u64;
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
            amount = deducting as i64; // < remainder in out & bardo
        } else { // remove or add dollars to one specific position...
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
                // deducting...we check the max, same as we did above...
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
                            // short is in-the-money; this
                            // would be like cheating (to add
                            // collateral) as it would widen the
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
                        }
                        amount = max.min(amount as u64) as i64;
                    }
                    pod.pledged += amount as u64;
                } 
            } else {
                require!(amount > 0, PithyQuip::InvalidAmount);
                if self.balances.len() >= MAX_LEN {
                    return Err(PithyQuip::MaxPositionsReached.into());
                } 
                self.balances.push(Position { ticker: padded,
                    pledged: amount as u64, exposure: 0, 
                    updated : current_time 
                }); // ^ this is the only 
            } // place where we update the
        } // timestamp in renege, mostly it 
        // is used in reposition, for maintenance purposes, as
        self.balances.retain(|pod| pod.pledged > 0); // clear vacanties
        Ok(0) // < TODO return how much was actually added or withdrawn for info
    } 
} 
