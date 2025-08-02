
import { useCallback, useEffect, useState, useRef } from "react"
import { formatUnits, parseUnits } from "@ethersproject/units"
import { useConnection, useWallet } from "@solana/wallet-adapter-react";
import { getAssociatedTokenAddressSync, TOKEN_PROGRAM_ID, 
  ASSOCIATED_TOKEN_PROGRAM_ID } from "@solana/spl-token";
import { SystemProgram, PublicKey } from "@solana/web3.js";
import { usePythPrice } from "../contexts/PythPriceProvider";
import { useDepository } from "../contexts/DepositoryProvider";
import { BN } from "@coral-xyz/anchor";
import { Modal } from "./Modal"
import { Icon } from "./Icon"

import { Buttons } from "./Adds/Buttons"
import { useAppContext } from "../contexts/AppContext"
import "./Styles/Mint.scss"

const ChoiseBoxes = ({
  status = true, 
  name = "", relation = "",
  style = {}, onChange = () => { return null }
}) => {
  return (
    <>
        <>
          <span className="mint-switcher mint-availabilityMax">
            <>
              <b style={{ color: '#4ad300' }} className="fade-in">{relation}</b>
            </>
          </span>
          <label className="switch fade-in">
            <input
              name={name}
              type="checkbox"
              className="fade-in"
              checked={status}
              style={style ? style : null}
              onChange={() => onChange()}
            />
            <span className="slider round fade-in"></span>
          </label>
        </>  
    </>
  )
}

export const Mint = () => {
  const DELAY = 60 * 60 * 8

  const { setStorage, setSwipe,  chooseButton, swipeStatus, getTotals, 
    refetchDepositorAccount, notifications, walletBalanceUSD, getWalletBalance,
    updatePrice, depositor, usd_star, connected } = useAppContext()

  const { connection } = useConnection();
  const { sendTransaction, publicKey } = useWallet();
  const { program } = useDepository();

  const { PriceFeedAccount } = usePythPrice();
  const [inputValue, setInputValue] = useState('')

  const [exposureStatus, setExposureStatus] = useState(false)
  
  const [isModalOpen, setIsModalOpen] = useState(false)
  const [startMsg, setStartMsg] = useState('')
  const [ticker, setTickerStatus] = useState('') 

  const [buttonSign, setSign] = useState('')
  const [placeHolder, setPlaceHolder] = useState('')
  const [isProcessing, setIsProcessing] = useState(false)

  const buttonRef = useRef(null)
  const inputRef = useRef(null)
  const consoleRef = useRef(null)
  const TICKER = 'XAU' // TODO make chooseable, currently hardcoded
  // also update AppContext with totals per ticker 

  const handleCloseModal = () => setIsModalOpen(false)

  const handleAgreeTerms = useCallback(async () => {
    setIsModalOpen(false)
    localStorage.setItem("hasAgreedToTerms", "true")
    buttonRef.current?.click()
  }, [])

  /* const handleChangeValue = useCallback((e) => { // TODO uncomment for Ethereum
    const regex = /^\d*(\.\d*)?$|^$/

    let originalValue = e.target.value

    if (originalValue.length > 1 && originalValue[0] === "0" && originalValue[1] !== ".")
      originalValue = originalValue.substring(1)

    if (originalValue[0] === ".") originalValue = "0" + originalValue

    if (regex.test(originalValue)) {
      if (chooseButton == null) setInputValue(Number(originalValue).toFixed())
      else setInputValue(originalValue) // allows using inputs like 0.01 for ETH
    }
  }, [chooseButton]) */

  const handleChangeValue = useCallback((e) => {
    let originalValue = e.target.value;
  
    // Allow empty string (for clearing)
    if (originalValue === "") {
      setInputValue("");
      return;
    }
  
    // Only allow whole numbers (positive or negative), no leading zeros
    const regex = /^-?(0|[1-9]\d*)$/;
  
    if (regex.test(originalValue)) {
      // Disallow values like "00", "-01", etc.
      if (
        originalValue.length > 1 &&
        (originalValue.startsWith("0") || originalValue.startsWith("-0"))
      ) {
        return;
      }
  
      setInputValue(originalValue);
    }
  }, []);
  
  
  const setNotifications = useCallback((severity, message, status = false) => {
    setStorage(prevNotifications => [
      ...prevNotifications,
      { severity: severity, message: message, status: status }
    ])
  }, [setStorage])

  //================================================================================================
  // -------------------------- STARTING TRANSFERS TERMINAL METHOD ---------------------------------
  //================================================================================================

  // TODO add chain argument in addition to button
  // withdraw will use reclaim and only accept a 
  // positive id showing the text in red... 
  const terminalStarting = async (button) => {
    
    const hasAgreedToTerms = localStorage.getItem("hasAgreedToTerms") === "true"
    if (!hasAgreedToTerms) return setIsModalOpen(true)

    if (!connected) return setNotifications("error", "Please connect your wallet")
    if (!inputValue.length) return setNotifications("error", "Please enter amount")

    /*
    const balanceStatus = await getWalletBalance().then((balance) => {
      if (Number(inputValue) > Number(balance.eth)) return true
      else return false
    }) 

    const usdebalance = async () => { // TODO
      // if (usde) return Number(formatUnits(await usde.methods.balanceOf(account).call(), 18))
        if (usde) return Number(formatUnits(await usde.methods.balanceOf(account).call(), 6))
    } */

    let signatureString;
    const valueDepo = parseUnits(inputValue, 6).toString()
    const amount = new BN(valueDepo);
    const customerTokenAccount = getAssociatedTokenAddressSync(
      usd_star,
      publicKey
    )
    // Derive bank PDA
    const [bank, _bankBump] = PublicKey.findProgramAddressSync(
      [usd_star.toBuffer()],
      program.programId
    )
    // Derive bank_token_account PDA
    const [bankTokenAccount, _bankTokenBump] = PublicKey.findProgramAddressSync(
      [Buffer.from("vault"), usd_star.toBuffer()],
      program.programId
    )
    // Derive customer_account PDA
    const [customerAccount, _customerBump] = PublicKey.findProgramAddressSync(
      [publicKey.toBuffer()],
      program.programId
    )
    try {
      if (button === "DEPOSIT") {
          // TODO form validator
          // return setNotifications("error", "Cost shouldn't be more than your USD* balance.")
          const tx = await program.methods
            .deposit(amount, exposureStatus ? TICKER : '')
            .accounts({
              signer: publicKey,
              mint: usd_star,
              bank,
              bankTokenAccount,
              customerAccount,
              customerTokenAccount,
              tokenProgram: TOKEN_PROGRAM_ID,
              associatedTokenProgram: ASSOCIATED_TOKEN_PROGRAM_ID,
              systemProgram: SystemProgram.programId,
            })
            .transaction();

          console.log("tx", tx)
          const transactionSignature = await sendTransaction(tx, connection, {
            skipPreflight: true,
          });
          signatureString = JSON.stringify(transactionSignature);
          console.log("signatureString")
          setIsProcessing(true)
          setNotifications("info", "Processing. Please don't close or refresh page when terminal is working")
        
      }
      if (button === "WITHDRAW") { // TODO we have depInfo here, perform checks
        if (exposureStatus)
          console.log('exposed')
      
        console.log(ticker)

        const remainingAccounts = [
          { pubkey: PriceFeedAccount, isSigner: false, isWritable: false },
        ];
        const tx = await program.methods
            .withdraw(amount, ticker, exposureStatus)
            .accounts({
              signer: depositor.owner,
              mint: usd_star,
              customerAccount,
              customerTokenAccount,
              tokenProgram: TOKEN_PROGRAM_ID,
              associatedTokenProgram: ASSOCIATED_TOKEN_PROGRAM_ID,
              systemProgram: SystemProgram.programId,
            })
            .remainingAccounts(remainingAccounts)
            .transaction();

          const transactionSignature = await sendTransaction(tx, connection, {
            skipPreflight: true,
          });
          signatureString = JSON.stringify(transactionSignature);
          setIsProcessing(true)
          setNotifications("info", "Processing. Please don't close or refresh page when terminal is working")   
      }
    } catch (err) {
      setNotifications("error",  err.message)
    } finally {
      refetchDepositorAccount(publicKey)
      getWalletBalance(true)
      getTotals(true)
      setNotifications("success", "Your transaction has been completed! " + signatureString, true)
      setIsProcessing(false)
      setInputValue("")
    }
  }

  //================================================================================================
  // -------------------------- THE END OF WALLET TERMINAL METHOD ----------------------------------
  //================================================================================================

  const handleSubmit = () => {
    terminalStarting(chooseButton.current)
  }

  const handleSetMaxValue = useCallback(async () => {
    if (buttonRef.current === "DEPOSIT") {
      const setUSDeValue = Number(walletBalanceUSD).toFixed()
      setInputValue(setUSDeValue.toString())
    }
    else setInputValue() // TODO exposure 
  }, [walletBalanceUSD]);

  const handleTicker = useCallback(() => {
    if (ticker === TICKER) {
      setTickerStatus('')
      setSign('$')
    }
    else { 
      setTickerStatus(TICKER)
      setSign('Au')
    }
  }, [ticker, setTickerStatus]);

  const handleExposure = useCallback(() => {
    if (exposureStatus) {
      setExposureStatus(false)
    }
    else { 
      setExposureStatus(true)
    }
  }, [exposureStatus, setExposureStatus]);

  useEffect(() => {
    if (swipeStatus) {
      setInputValue("")
      setTickerStatus('')
      setExposureStatus(false)
      setSwipe()
    }
    setPlaceHolder('amount (+/-)')
    if (chooseButton.current === "DEPOSIT" || chooseButton.current == null) {
      setSign('$')
    } 
    if (connected) {
      updatePrice();
      setStartMsg('Welcome...');
    }
    else {
      localStorage.setItem("consoleNotifications", JSON.stringify(''))
    }
    if (consoleRef.current) consoleRef.current.scrollTop = consoleRef.current.scrollHeight
    if (notifications[0] && !connected) setTimeout(() => setStorage([]), 500)

  }, [setSwipe, chooseButton, swipeStatus, ticker,
      updatePrice, setStorage, connected, notifications])

  return (
    <div className="mint">
      <div className="mint-root fade-in" onSubmit={handleSubmit}>
        <div className="mint-inputContainer fade-in">
          <input
            type="text"
            id="mint-input"
            className="mint-input"
            value={inputValue}
            onChange={handleChangeValue}
            
            placeholder={placeHolder}
            ref={inputRef}
          />
          <div className="mint-dollarSign">
            <button id="mint-button">
              <div className="fade-in">{buttonSign}</div>
            </button>
          </div>
          <button className="mint-maxButton" onClick={handleSetMaxValue} type="button">
            Max
            <Icon preserveAspectRatio="none" className="mint-maxButtonBackground" name="btn-bg" />
          </button>
        </div>
        <div className="mint-sub">
          <label className="checkbox-container">
          {chooseButton.current === "WITHDRAW" || chooseButton.current === "DEPOSIT" || chooseButton.current == null || chooseButton.current == "" ?
              <ChoiseBoxes
                status={exposureStatus}
                name={"exposure"}
                relation={""}
                onChange={handleExposure}/> : null
            }
            {chooseButton.current === "WITHDRAW" ?
               <ChoiseBoxes status={ticker === TICKER}
               name={"ticker"} relation={"...Au:"}
               onChange={handleTicker}/> : null
            } 
          </label>
        </div>
        <Buttons
          names={["WITHDRAW", "DEPOSIT"]}
          initialSlide={1}
          buttonRef={buttonRef}
          isProcessing={isProcessing}
          handleSubmit={handleSubmit}
        />
        <Modal open={isModalOpen} handleAgree={handleAgreeTerms} handleClose={handleCloseModal} />
      </div>
      <div className="mint-console fade-in" ref={consoleRef}>
        <div className="mint-console-content">
          <div>{connected ? startMsg : 'Connect your wallet...'}</div>
          {notifications ? notifications.map((notification, index) => (
            <div
              key={index}
              className={`mint-console-line ${notification.severity}`}
            >
              {notification.message}
            </div>
          )) : null}
          {isProcessing && (
            <div className="mint-console-line info">
              Processing<span className="processing-dots">...</span>
            </div>
          )}
        </div>
      </div>
    </div>
  )
}
