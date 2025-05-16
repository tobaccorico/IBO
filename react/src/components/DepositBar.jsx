import { useCallback, useEffect, useState } from "react"
import { useAppContext } from "../contexts/AppContext"

import "./Styles/MintBar.scss"
import "./Styles/DepositeBar.scss"

export const DepositBar = () => {
    const { connected, notifications, totalShorts,
        totalLongs, totalPledged, totalDeposited,
        /* resetAccounts, quid, usde, addressQD */ } = useAppContext()


    // parseFloat((Number(totalDeposited) / 1000000).toFixed(2))

    return (
        <div className="global-summary-root">
            <div className="summary-section">
                <div className="summary-title">Total in depository (USD*):</div>
                <div className="summary-value">
                    ${connected ? totalDeposited : 0 }
                </div>
            </div>
            <div className="summary-section">
                <div className="summary-title">Total short exposure (Au):</div>
                <div className="summary-value">
                    {connected ? totalShorts : 0 }
                </div>
            </div>
            <div className="summary-section">   
                <div className="summary-title">Total long exposure (Au):</div>
                <div className="summary-value">
                    {connected ? totalLongs : 0 }
                </div>
            </div>
            <div className="summary-section">
                <div className="summary-title">Total $ pledged :</div>
                <div className="summary-value">
                    ${connected ? totalPledged : 0 }
                </div>
            </div>
        </div>
    )
}
