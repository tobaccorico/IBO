// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./Basket.sol";
import "./Safta.sol";

library SettlementLib {
    
    // Proposal validation
    function validateProposal(
        address market,
        uint256 stakeAmount,
        uint256 minStake
    ) external view {
        require(stakeAmount >= minStake, "Insufficient stake");
        require(_isValidMarket(market), "Invalid market");
        require(_canPropose(market), "Cannot propose");
    }
    
    function _isValidMarket(address market) internal view returns (bool) {
        // Check if market is a Safta contract by checking if it has required functions
        try Safta(market).getMarketInfo() returns (
            string memory,
            uint256,
            bool,
            bool,
            uint256,
            uint256
        ) {
            return true;
        } catch {
            return false;
        }
    }
    
    function _canPropose(address market) internal view returns (bool) {
        Safta doppler = Safta(market);
        
        // Get market info
        (,uint256 resolutionTime,,,,) = doppler.getMarketInfo();
        
        // Check if already resolved
        if (doppler.isResolved()) return false;
        
        // Check resolution time
        if (block.timestamp < resolutionTime) return false;
        
        return true;
    }
    
    // Jury selection helpers
    function selectJurorsFromHolders(
        address basketAddress,
        uint256 randomSeed,
        uint256 jurySize,
        uint256 minBalance,
        mapping(address => uint256) storage activeDisputes
    ) external view returns (address[] memory selected) {
        Basket basket = Basket(basketAddress);
        uint256 latestHolder = basket.latest_holder();
        
        // Count eligible
        uint256 eligibleCount = 0;
        for (uint256 i = 1; i <= latestHolder; i++) {
            address holder = basket.holders(i);
            if (holder != address(0)) {
                uint256 balance = basket.totalBalances(holder);
                if (balance >= minBalance && activeDisputes[holder] == 0) {
                    eligibleCount++;
                }
            }
        }
        
        require(eligibleCount >= jurySize, "Not enough eligible jurors");
        
        // Collect eligible addresses
        address[] memory eligibleJurors = new address[](eligibleCount);
        uint256 index = 0;
        for (uint256 i = 1; i <= latestHolder; i++) {
            address holder = basket.holders(i);
            if (holder != address(0)) {
                uint256 balance = basket.totalBalances(holder);
                if (balance >= minBalance && activeDisputes[holder] == 0) {
                    eligibleJurors[index++] = holder;
                }
            }
        }
        
        // Fisher-Yates shuffle variant
        selected = new address[](jurySize);
        bool[] memory used = new bool[](eligibleCount);
        
        for (uint256 i = 0; i < jurySize; i++) {
            uint256 remaining = eligibleCount - i;
            uint256 idx = uint256(keccak256(abi.encode(randomSeed, i))) % remaining;
            
            uint256 currentIndex = 0;
            for (uint256 j = 0; j < eligibleCount; j++) {
                if (!used[j]) {
                    if (currentIndex == idx) {
                        selected[i] = eligibleJurors[j];
                        used[j] = true;
                        break;
                    }
                    currentIndex++;
                }
            }
        }
    }
    
    // Slash calculation
    function calculateSlashAmount(
        address basketAddress,
        address juror,
        uint256 slashPercent
    ) external view returns (uint256) {
        Basket basket = Basket(basketAddress);
        uint256 balance = basket.totalBalances(juror);
        return (balance * slashPercent) / 100;
    }
    
    // Proposal threshold checking
    function canExecuteProposal(
        uint256 supportStake,
        uint256 opposeStake,
        uint256 supportThreshold,
        uint256 createdAt,
        uint256 votingPeriod,
        uint256 executionDelay
    ) external view returns (bool) {
        if (block.timestamp < createdAt + votingPeriod + executionDelay) {
            return false;
        }
        
        return supportStake >= opposeStake * supportThreshold;
    }
}