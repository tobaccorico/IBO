import { useCallback, useEffect, useState } from "react"
// import { BN } from "@coral-xyz/anchor";

import { useAppContext } from "../contexts/AppContext";
import { useDepositor } from "../contexts/DepositorProvider";
import { usePythPrice } from "../contexts/PythPriceProvider";
import { numberWithCommas } from "../utils/number-with-commas"

import "./Styles/MintBar.scss"

export const MintBar = () => { // TODO Ethereum stuff commented out

  const { depositor } = useDepositor();
  const { AuPrice } = usePythPrice();
  const { connected /*
    account, quid, usde, resetAccounts, addressQD */ } = useAppContext()

  return (
    <div className={`summary-root`} >
      <div className="summary-section">
        <div className="summary-title">Position ({ connected && depositor && depositor.balances.length > 0 
          && depositor.balances[0] != null ? (
             depositor.balances[0].exposure == 0 ? "none" :
            (depositor.balances[0].exposure > 0 ? "long" : "short")) : "none" })
        </div>
        <div className="summary-value">{ connected && depositor 
          && depositor.balances.length > 0 && depositor.balances[0] != null ?
              numberWithCommas(depositor.balances[0].exposure / 1000000) : 0 }
        </div>
      </div>
      <div className="summary-section">
        <div className="summary-title">Current Price of Gold</div>
        <div className="summary-value">
          ${ connected && AuPrice ? (parseFloat(AuPrice.toString()).toFixed(2)) : 0 }
        </div>
      </div>
      <div className="summary-section">
        <div className="summary-title">$ Deposited (for yield)</div>
        <div className="summary-value">
          { connected && depositor ? 
            numberWithCommas(depositor.depositedUsdStar / 1000000) : 0 }
        </div>
      </div>
      <div className="summary-section">
        <div className="summary-title">Current profit in $</div>
        <div className="summary-section">
        <div className="summary-title">Current profit in $</div>
        <div className="summary-value">
          {connected && depositor && depositor.balances.length > 0 && depositor.balances[0] != null && depositor.balances[0].exposure !== 0 ? (
            depositor.balances[0].exposure > 0 ? (
              numberWithCommas(
                (
                  (depositor.balances[0].exposure * parseFloat(AuPrice.toString()) -
                    depositor.balances[0].pledged) / 1000000
                )
              )
            ) : (
              numberWithCommas(
                (
                  (depositor.balances[0].pledged -
                    (-1 * depositor.balances[0].exposure) * parseFloat(AuPrice.toString())) / 1000000
                )
              )
            )
          ) : 0}
        </div>
      </div>
      </div>
      <div className="summary-section">
        <div className="summary-title">Collateral (pledged $)</div>
        <div className="summary-value">
            { connected && depositor && depositor.balances 
            && depositor.balances.length > 0 && depositor.balances[0] != null  ? 
              numberWithCommas(depositor.balances[0].pledged / 1000000) : 0 }
        </div>
      </div>
    </div>
  )
}
