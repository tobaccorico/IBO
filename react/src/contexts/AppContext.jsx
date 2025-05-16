  
import { createContext, useState, useContext, useCallback, useRef} from "react"
import { useConnection, useWallet } from "@solana/wallet-adapter-react";
import { PublicKey } from "@solana/web3.js";
import { useDepository } from "./DepositoryProvider";
import { useDepositor } from "./DepositorProvider";
import { usePythPrice } from "./PythPriceProvider";

/* TODO uncomment later when we implement "choose chain"
import { useSDK } from "@metamask/sdk-react"
import { formatUnits, parseUnits } from "@ethersproject/units"
import { BigNumber } from "@ethersproject/bignumber"
import { Web3Provider } from "@ethersproject/providers"
import Web3 from "web3"
import { QUID, USDE,  MO, 
  addressQD, addressUSDE, 
  addressMO } from "../utils/constant"
*/

const contextState = {
  
  setBalanceUSD: () => {}, 
  setTotalShorts: () => {}, 
  setTotalLongs: () => {},
  setTotalDeposited: () => {},

  getTotalInfo: () => { },
  updatePrice: () => { },
  
  getDepositorInfo: () => { },
  getTotals: () => { },
  getWalletBalance: () => { },
  setNotifications: () => { },
  setStorage: () => { },
  
  choiseButton: () => { },
  setSwipe: () => { },
  setCurrentPrice: () => { },
  swipeStatus: false,
  chooseButton: null,
  connected: false,
  // TODO...uncomment Ethereum
  // resetAccounts: () => { },
  // connectToMetaMask: () => { },
  // getUsde: () => { }, 
  // account: "",
  // connecting: false,
  // provider: {},
  // sdk: {},
  // web3: {},
  // addressMO
}

const AppContext = createContext(contextState)

export const AppContextProvider = ({ children }) => {
  
  /* TODO uncomment MetaMask functionality...
    const [account, setAccount] = useState("")
    const { sdk, connected, connecting, provider } = useSDK()
    
    const [quid, setQuid] = useState(null) // Basket contract
    const [usde, setUsde] = useState(null) // Accounts payable 
    // ^ (deposit in order to mint Basket tokens, i.e. accounts receivable)
    //const [susde, setSusde] = useState(null)
b
    const [mo, setMO] = useState(null)
    const [balanceQD, setBalanceQD] = useState(null)
  */

  // const USD_STAR = "BenJy1n3WTx9mTjEvy63e8Q1j4RqUc6E4VBMz3ir4Wo6"; // TODO mainnet
  const USD_STAR = "6QxnHc15LVbRf8nj6XToxb8RYZQi5P9QvgJ4NDW3yxRc";
  const usd_star = new PublicKey(USD_STAR);
  const { connection } = useConnection();
  const { publicKey, connected } = useWallet();
  
  const { depository } = useDepository();
  const { AuPrice, fetchInitialPrice } = usePythPrice();
  const { depositor, allDepositorAccounts, 
    refetchDepositorAccount, fetchAllDepositorAccounts } = useDepositor();
  
  const [balanceUSD, setBalanceUSD] = useState(null)

  const [totalLongs, setTotalLongs] = useState(null)
  const [totalShorts, setTotalShorts] = useState(null)
  const [totalDeposited, setTotalDeposited] = useState(null)
  const [totalPledged, setTotalPledged] = useState(null)

  const [notifications, setNotifications] = useState('')
  const [swipeStatus, setSwipeStatus] = useState(false)

  const setStorage = useCallback((newNotifications) => {
    try {
      setNotifications(newNotifications)
      localStorage.setItem("consoleNotifications",
               JSON.stringify(newNotifications))
    } catch (error) {
      console.error("Error setting notifications:", error)
    }
  }, [])

  const updatePrice = useCallback(async () => {
    try { 
      if (!AuPrice) {
        fetchInitialPrice();
      }
    } catch (error) {
      console.error("Some problem with getPrice: ", error)
      return null
    } // const ethPrice = (parseFloat(...) / 1e18)
  }, [AuPrice, fetchInitialPrice])

  const getTotals = useCallback(async (force) => {
    try {
      const depositorAccounts = await fetchAllDepositorAccounts(force);
      const totals = depositorAccounts.reduce((acc, account) => {
          const b = account.account?.balances?.[0]; if (b) {
            if (b.exposure > 0) acc.longs += b.exposure;
            else if (b.exposure < 0) acc.shorts += b.exposure;
            acc.pledged += b.pledged;
          } acc.deposited += account.account.depositedUsdStar || 0;
          return acc;
        }, { shorts: 0, longs: 0, pledged: 0, deposited: 0 });
        setTotalDeposited(totals.deposited / 1_000_000 || 1);
        setTotalPledged(totals.pledged / 1_000_000 || 1);
        setTotalShorts(totals.shorts / 1_000_000 || 1);
        setTotalLongs(totals.longs / 1_000_000 || 1);
    } catch (error) {
      console.error("Some problem with getSupply: ", error)
      return null
    }
  }, [fetchAllDepositorAccounts, allDepositorAccounts, 
    totalLongs, totalShorts, totalDeposited, totalPledged])

  /* TODO uncoment later to connect Ethereum...
  const getTotalInfo = useCallback(async () => {
    try {
      if (connected && account && quid && usde && addressQD) {
        const totalSupply = await quid.methods.totalSupply().call()
        
        const formattedTotalMinted = formatUnits(totalSupply, 18).split(".")[0]

        const total = await quid.methods.get_total_deposits(true).call()
        const formattedTotalDeposited = formatUnits(total.toString(), 18)

        const totalInfo = {
          total_dep: formattedTotalDeposited,
          total_mint: formattedTotalMinted
        }

        return totalInfo
      }
    } catch (error) {
      console.error("Error in updateInfo: ", error)
    }
  }, [account, connected, quid, usde]) */

  const getDepositorInfo = useCallback(async () => {
    try {
      if (connected) {
        refetchDepositorAccount(publicKey)
      }
    } catch (error) {
      console.warn(`Failed to get account info:`, error)
    }
  }, [refetchDepositorAccount, publicKey, connected])

  const getWalletBalance = useCallback(async (force) => {
    try {    
      if (connected && (!balanceUSD || force)) {
        const tokenAccounts = await connection.getParsedTokenAccountsByOwner(
          publicKey, { mint: usd_star }
        );
        
        if (tokenAccounts.value.length === 0) {
          return 0;
        }
        
        const balance = tokenAccounts.value[0].account.data.parsed.info.tokenAmount.uiAmount
        // const formattedBalance = (parseFloat(balance) / 1e6).toFixed(2);
        
        /* TODO uncomment for Ethereum 
        const ethersProvider = new Web3Provider(provider)
        const mainBalance = await ethersProvider.getBalance(account)
        const formatEthBalance = (parseFloat(mainBalance) / 1e18).toFixed(4)
          // iterate through stablecoin addresses from constant.js
          // if user has balance, add token as one of the
          // available accounts payable choices in dropdown,
          // sort the order by large balanace first
          // e.g. await usde.methods.balanceOf(account).call()
        */
        if (balance == 0) setBalanceUSD(1)
        else setBalanceUSD(balance);
      }
    } catch (error) {
      console.warn(`Failed to connect:`, error)
    }
  }, [connected, connection, publicKey, usd_star, balanceUSD])
  
  /* TODO uncoment later to re-connect Ethereum...
    const getBalanceQD = useCallback(async () => {
      try {
        if (quid && account) {
          const balance = await quid.methods.totalBalances(account).call()

          setBalanceQD(parseFloat(balance) / 1e18)
        }
      } catch (error) {
        console.warn(`Failed to connect:`, error)
      }
    }, [setBalanceQD, account, quid])

    const getUsde = useCallback(async (who) => {
      try {
        if (usde) {
          await usde.methods.balanceOf(who).call() 
        } // await usde.methods.mint(who).send({ from: account })
        
      } catch (error) {
        console.warn(`Failed to connect:`, error)
      }
    }, [account, usde])

    const connectToMetaMask = useCallback(async () => {
      try {
        if (!account) {
          const accounts = await window.ethereum.request({ method: 'eth_requestAccounts' })

          setAccount(accounts[0])

          if (accounts && provider) {

            const web3Instance = new Web3(provider)
            const quidContract = new web3Instance.eth.Contract(QUID, addressQD)
            const moContract = new web3Instance.eth.Contract(MO, addressMO)
            const usdeContract = new web3Instance.eth.Contract(USDE, addressUSDE)
            //const susdeContract = new web3Instance.eth.Contract(SUSDE, addressSUSDE)

            setMO(moContract) // UniswapV4 Router
            // TODO add AUX contract
            setQuid(quidContract)
            // ^ Basket contract (ERC20-comptabile ERC6909 token)
            setUsde(usdeContract)
            // ^ accounts payable ERC20 (stablecoin for minting Basket tokens)
            //setSusde(susdeContract)
          }
        }
      } catch (error) {
        console.warn(`Failed to connect:`, error)
      }
    }, [setAccount, setMO, setUsde, setQuid, account, provider]) 
    
    const resetAccounts = useCallback(async (reset = false) => {
      try {
        if (reset) setAccount("")
      } catch (error) {
        console.warn(`Failed to set all info:`, error)
      }
    }, [])

  */

  const chooseButton = useRef(null)
  const choiseButton = useCallback((name) => {
      try {
          const newButton = name

          return chooseButton.current = newButton
      } catch(error) {
          console.error("Error with button's choising: ", error)
      }
  },[chooseButton])

  const setSwipe = useCallback(()=>{
    try {
      if (swipeStatus) setSwipeStatus(false)
      else setSwipeStatus(true)
    } 
    catch (error) {
      console.error("Error with swipe: ", error)
    }
  },[swipeStatus])

  return ( // TODO 
  // uncomment for Ethereum
    <AppContext.Provider
      value={{
        getDepositorInfo,
        getTotals,
        updatePrice,
        getWalletBalance, 
        setBalanceUSD,
        depositor,
        depository,
        setTotalLongs,
        totalLongs,
        setTotalShorts,
        totalShorts,
        AuPrice,
        setTotalDeposited,
        totalDeposited,
        setTotalPledged,
        totalPledged,
        setNotifications,
        refetchDepositorAccount,
        setStorage,
        connected,
        balanceUSD,
        usd_star,
        notifications,
        choiseButton,
        chooseButton,
        setSwipe,
        swipeStatus
        // connecting,
        // provider,
        // sdk,
        // mo, // Router
        // quid, // Basket contract object
        // usde, // accounts payable contract object
        // balanceQD,
        // addressQD, // Basket address
        // addressUSDE,
        // setMO,
        // account,
        // addressMO, // Router address 
        // connectToMetaMask,
        // getUsde, 
        // resetAccounts,
        // getBalanceQD,
      }}> {children}
    </AppContext.Provider>
  )
}

export const useAppContext = () => useContext(AppContext)

export default AppContext
