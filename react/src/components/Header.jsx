
import { Icon } from "./Icon"
import { useEffect, useState, useCallback } from "react"
import { shortedHash } from "../utils/shorted-hash"
import { numberWithCommas } from "../utils/number-with-commas"
import { useAppContext } from "../contexts/AppContext"

import { WalletMultiButton } from "@solana/wallet-adapter-react-ui";

import "./Styles/Header.scss"

// import { CheckChainId } from "./CheckChainId"
// ^ TODO so far this only checks which Ethereum chain you're on,
// extend the functionality to choose between Solana and EVM...

export const Header = () => {
  
  const { getWalletBalance, balanceUSD, getTotals,
    connected, notifications, totalLongs, depository,
    totalShorts, totalDeposited, totalPledged
  } = useAppContext() 
  
  const updatedTotalInfo = useCallback(async () => {
    try {
      var force = (!totalLongs && !totalShorts && !totalDeposited && !totalPledged)
      if (connected && force) {
          await getTotals(force).then(() => {
            getWalletBalance(false)
          })
      }     
    } catch (error) {
      console.warn(`Failed to get total info:`, error)
    }
  }, [getWalletBalance, getTotals, 
      totalLongs, totalShorts, 
      totalDeposited, totalPledged])
  

  /* TODO uncomment for Ethereum
  const handleConnectClick = useCallback(async () => {
    try {
      await connectToMetaMask()
      // await usdeToWallet() // On testnet 
      // ^ this automatically throws some mockTokens into
      // the accounts payable balance so we can test minting accounts receivable
    } catch (error) {
      console.error("Failed to connect to MetaMask", error)
    }
  }, [connectToMetaMask])
  
  const usdeToWallet = useCallback(async () => {
    try {
      if (connected) await Promise.all([getUsde()]).then(() => updatedTotalInfo())
    } catch (error) {
      console.warn(`Failed to mint free money :`, error)
    }
  }, [getUsde, updatedTotalInfo, connected])
  
  useEffect(() => {
    if (!connected) {
      connectToMetaMask()
      updatedTotalInfo()
    } else {
      getUserInfo()
    }
  }, [connectToMetaMask, updatedTotalInfo, getUserInfo, connected, notifications]) */

  useEffect(() => {
    if (connected) {
      updatedTotalInfo()
    } 
  }, [updatedTotalInfo, connected, notifications])

  /*
    TODO add this back to balanceBlock
    <div className="header-summaryEl fade-in">
      <div className="header-summaryElTitle">ETH balance</div>
      <div className="header-summaryElValue">
        Ξ{Number(actualEth).toFixed(4)}
      </div>
    </div>
  */
  const balanceBlock = (
    <>
      <div className="header-summaryEl fade-in">
        <div className="header-summaryElTitle"></div>
        <div className="header-summaryElValue">
          {depository ? depository.interestRate.toString() : 0}%
        </div>
      </div>  
      <div className="header-summaryEl fade-in">
        <div className="header-summaryElTitle">USD* balance</div>
        <div className="header-summaryElValue">
          ${balanceUSD ? numberWithCommas(balanceUSD) : 0}
        </div>
      </div>
    </>
  )
  
  return (
    <header className="header-root">
      <div className="header-logoContainer fade-in">
        <a className="header-logo" href="https://yo.quid.io"> </a>
      </div>
      <div className="header-summary fade-in">
        {connected ? balanceBlock : null}
      </div>
      <div className="header-walletContainer">
        <div className="header-wallet fade-in">    
          <WalletMultiButton />
        </div>
      </div>
    </header>
  )
}

/* TODO for Ethereum add this into walletContainer class 
  {connected ? (
    <div className="header-wallet fade-in">
      
      <div className="header-metamaskIcon">
        <img
          width="18"
          height="18"
          src="/images/metamask.svg"
          alt="metamask"
        />
      </div>
      {shortedHash(account)}
      <Icon name="btn-bg" className="header-walletBackground" />
      <CheckChainId />
    </div>          
  ) : (
    <button className="header-wallet fade-in" onClick={handleConnectClick}>
      Connect Metamask
      <Icon name="btn-bg" className="header-walletBackground" />
    </button>
  )}
*/

