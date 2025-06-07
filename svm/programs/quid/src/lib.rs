
use anchor_lang::prelude::*;
use lieb::*; mod lieb;
mod stay; 
mod etc; 
// declare_id!("QDgHUZjtccRjKZ63MBvW8uzKR7qcqjpRfGhNSEGfDu9"); // < devnet
declare_id!("CBk32LDw7RVt1hoCqRx55W5HxJYHzTFFXHkFM7Ue8KeA"); // < localnet

#[program]
pub mod quid {
    use super::*;
    
    pub fn deposit(ctx: Context<Deposit>, amount: u64, ticker: String) -> Result<()> {
        handle_in(ctx, amount, ticker)
    } 

    // if you're obtaining short leverage, flip the signs respectively for amount; otherwise (long):
    // positive amount = increase exposure; negative = withdraw USD* (or) redeem exposure for USD*
    pub fn withdraw(ctx: Context<Withdraw>, amount: i64, ticker: String, exposure: bool) -> Result<()> {
        handle_out(ctx, amount, ticker, exposure) // no ticker = withdraw collateral from all positions;
        // at least one Pyth key must be passed into remaining_accounts (all keys if empty string ticker)
    } // this sort of cross-margining is also re-used in the liquidation process (means of protection)...
    // as such, need to pass in all Pyth keys into liquidate (first one should be the one to liquidate)

    pub fn liquidate(ctx: Context<Liquidate>, ticker: String) -> Result<()> { 
        amortise(ctx, ticker) 
    }
}
