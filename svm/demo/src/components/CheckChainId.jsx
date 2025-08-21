import { useEffect, useCallback, useRef } from 'react'
import { useAppContext } from "../contexts/AppContext"

// checks if the current chain is Base
export const CheckChainId = () => {
  const { setStorage } = useAppContext()
  const hasCheckedRef = useRef(false)  

  const chainHex = '0x2105'

  const setNotifications = useCallback((severity, message, status = false) => {
    setStorage(prevNotifications => [
      ...prevNotifications,
      { severity: severity, message: message, status: status }
    ])
  }, [setStorage])

  useEffect(() => {
    const checkAndSwitchChain = async () => {
      if (hasCheckedRef.current) return
      hasCheckedRef.current = true

      if (window.ethereum) {
        try {
          const currentChainId = await window.ethereum.request({ method: 'eth_chainId' })

          if (currentChainId.toLowerCase() === chainHex) return
          

          setNotifications('info', 'Requesting to switch to Base mainnet...')

          await window.ethereum.request({
            method: 'wallet_switchEthereumChain',
            params: [{ chainId: chainHex }],
          })

          const newChainId = await window.ethereum.request({ method: 'eth_chainId' })
          if (newChainId.toLowerCase() === chainHex) {
            setNotifications('success', 'Successfully switched to Base mainnet')
          } else {
            setNotifications('error', 'Failed to switch to Base mainnet')
          }
        } catch (error) {
          if (error.code === 4902) {
            setNotifications('error', 'Base mainnet not found in wallet. Please add the network manually.')
          } else if (error.code === 4001) {
            setNotifications('info', 'Network switch request was rejected by the user.')
          } else {
            setNotifications('error', `Error: ${error.message}`)
          }
          console.error('Error during chain check or switch:', error)
        }
      } else {
        setNotifications('error', 'Ethereum provider not detected. Please install MetaMask.')
      }
    }

    const onChainChanged = (chainId) => {
      if (chainId.toLowerCase() === chainHex) {
        setNotifications('success', 'Connected to Base mainnet')
      } else {
        setNotifications('info', 'Requesting a switch to Base mainnet...')
        checkAndSwitchChain()
      }
    }

    checkAndSwitchChain()

    if (window.ethereum) {
      window.ethereum.on('chainChanged', onChainChanged)
    }

    return () => {
      if (window.ethereum) {
        window.ethereum.removeListener('chainChanged', onChainChanged)
      }
    }
  }, [setNotifications])

  return null
}

export default CheckChainId
