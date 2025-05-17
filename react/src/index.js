
import React from 'react'
import ReactDOM from 'react-dom/client'
import App from './App'

/// NOTE : we temporarily comment out all Ethereum code 
import { AppContextProvider } from "./contexts/AppContext"
// import { MetamaskProvider } from "./contexts/MetamaskProvider"
import { SolanaWalletProvider } from "./contexts/SolanaWalletProvider"
import { PythPriceProvider } from "./contexts/PythPriceProvider"
import { DepositorProvider } from "./contexts/DepositorProvider"
import { DepositoryProvider } from "./contexts/DepositoryProvider"

// Spawn background worker script (only if not already running)
/*
if (process.env.NODE_ENV !== "production") {
  const { spawn } = require("child_process");
  const ps = spawn("node", ["worker.js"], {
    detached: true,
    stdio: "ignore",
  });
  ps.unref(); // allow it to keep running in background
} */

const letsgo = ReactDOM.createRoot(document.getElementById('letsgo'))
letsgo.render(
  <React.StrictMode>
    <SolanaWalletProvider>
      <DepositoryProvider>
          <DepositorProvider>
            <PythPriceProvider>
              <AppContextProvider>
                <App />
              </AppContextProvider>
            </PythPriceProvider>
          </DepositorProvider>
        </DepositoryProvider>
    </SolanaWalletProvider>
  </React.StrictMode>
)
/* TODO
const infuraAPIKey = process.env.INFURA_API_KEY;
const chainID = process.env.CHAIN_ID; 
letsgo.render(
  <React.StrictMode>
    <MetamaskProvider
      sdkOptions={{
        dappMetadata: {
          name: "QU!D",
          //url: window.location.href,
        },
        injectProvider: {
          chainId: chainID,
          infuraAPIKey: infuraAPIKey
        }
      }}>
      <AppContextProvider>
          <App />
      </AppContextProvider>
    </MetamaskProvider>
  </React.StrictMode>
) */
/* TODO throw these back into package.json
    "@ethersproject/abi": "^5.7.0",
    "@ethersproject/bignumber": "^5.7.0",
    "@ethersproject/contracts": "^5.7.0",
    "@ethersproject/networks": "^5.7.1",
    "@ethersproject/providers": "^5.7.2",
    "@metamask/sdk-react": "^0.26.5",
*/            
