
use anchor_lang::prelude::*;
use lieb::*; mod lieb; mod stay; 
mod state; use state::*;
mod casa; mod etc; 

declare_id!("QgV3iN5rSkBU8jaZy8AszQt5eoYwKLmBgXEK5cehAKX"); // < devnet
// declare_id!("CBk32LDw7RVt1hoCqRx55W5HxJYHzTFFXHkFM7Ue8KeA"); // < localnet

#[program]
pub mod quid {
    use super::*;
    
    pub fn deposit(ctx: Context<Deposit>, amount: u64, ticker: String) -> Result<()> {
        handle_in(ctx, amount, ticker)
    } 

    // if you're obtaining short leverage, flip the Stringsigns respectively for amount; otherwise (long):
    // positive amount = increase exposure; negative = withdraw USD* (or) redeem exposure for USD*
    pub fn withdraw(ctx: Context<Withdraw>, amount: i64, ticker: String, exposure: bool) -> Result<()> {
        handle_out(ctx, amount, ticker, exposure) // no ticker = withdraw collateral from all positions;
        // at least one Pyth key must be passed into remaining_accounts (all keys if empty string ticker)
    } // this sort of cross-margining is also re-used in the liquidation process (means of protection)...
    // as such, need to pass in all Pyth keys into liquidate (first one should be the one to liquidate)

    pub fn liquidate(ctx: Context<Liquidate>, ticker: String) -> Result<()> { 
        amortise(ctx, ticker) 
    }

    pub fn create_battle(
        ctx: Context<CreateBattle>,
        stake_amount: u64,
        ticker: String,
        initial_tweet_uri: String,
    ) -> Result<()> {
        create_battle_challenge(ctx, stake_amount, ticker, initial_tweet_uri)
    }
    
    pub fn accept_battle(
        ctx: Context<AcceptBattle>,
        ticker: String,
        defender_tweet_uri: String,
    ) -> Result<()> {
        accept_battle_challenge(ctx, ticker, defender_tweet_uri)
    }
    
    pub fn finalize_battle_mpc(
        ctx: Context<FinalizeBattle>,
        winner_is_challenger: bool,
        challenger_sig: [u8; 64],
        defender_sig: [u8; 64],
        judge_sig: [u8; 64],
    ) -> Result<()> {
        finalize_battle_with_mpc(ctx, winner_is_challenger, challenger_sig, defender_sig, judge_sig)
    }
}

