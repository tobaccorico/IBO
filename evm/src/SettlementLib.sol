// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./Basket.sol";
import "./Auction.sol";

library SettlementLib {
    
    // Proposal validation
    function validateProposal(
        address market,
        uint stakeAmount,
        uint minStake
    ) external view {
        require(stakeAmount >= minStake, "Insufficient stake");
        require(_isValidMarket(market), "Invalid market");
        require(_canPropose(market), "Cannot propose");
    }
    
    function _isValidMarket(address market) internal view returns (bool) {
        // Check if market is an Auction contract by checking if it has required functions
        // Instead of trying to access the struct, just check for a function
        try Auction(payable(market)).bettingWindowClosed() returns (bool) {
            return true;
        } catch {
            return false;
        }
    }
    
    function _canPropose(address market) internal view returns (bool) {
        Auction auction = Auction(payable(market));
        
        // Check if resolved
        (, , , , , bool resolved, ) = auction.getPredictionSummary();
        if (resolved) return false;
        
        // Check resolution time
        uint resolutionTime = auction.resolutionTime();
        if (block.timestamp < resolutionTime) return false;
        
        return true;
    }
    
    // Jury selection helpers
    function selectJurorsFromHolders(
        address basketAddress,
        uint randomSeed,
        uint jurySize,
        uint minBalance,
        mapping(address => uint) storage activeDisputes
    ) external view returns (address[] memory selected) {
        Basket basket = Basket(basketAddress);
        uint latestHolder = basket.latest_holder();
        
        // Count eligible
        uint eligibleCount = 0;
        for (uint i = 1; i <= latestHolder; i++) {
            address holder = basket.holders(i);
            if (holder != address(0)) {
                uint balance = basket.totalBalances(holder);
                if (balance >= minBalance && activeDisputes[holder] == 0) {
                    eligibleCount++;
                }
            }
        }
        
        require(eligibleCount >= jurySize, "Not enough eligible jurors");
        
        // Collect eligible addresses
        address[] memory eligibleJurors = new address[](eligibleCount);
        uint index = 0;
        for (uint i = 1; i <= latestHolder; i++) {
            address holder = basket.holders(i);
            if (holder != address(0)) {
                uint balance = basket.totalBalances(holder);
                if (balance >= minBalance && activeDisputes[holder] == 0) {
                    eligibleJurors[index++] = holder;
                }
            }
        }
        
        // Fisher-Yates shuffle variant
        selected = new address[](jurySize);
        bool[] memory used = new bool[](eligibleCount);
        
        for (uint i = 0; i < jurySize; i++) {
            uint remaining = eligibleCount - i;
            uint idx = uint(keccak256(abi.encode(randomSeed, i))) % remaining;
            
            uint currentIndex = 0;
            for (uint j = 0; j < eligibleCount; j++) {
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
        uint slashPercent
    ) external view returns (uint) {
        Basket basket = Basket(basketAddress);
        uint balance = basket.totalBalances(juror);
        return (balance * slashPercent) / 100;
    }
    
    // Proposal threshold checking
    function canExecuteProposal(
        uint supportStake,
        uint opposeStake,
        uint supportThreshold,
        uint createdAt,
        uint votingPeriod,
        uint executionDelay
    ) external view returns (bool) {
        if (block.timestamp < createdAt + votingPeriod + executionDelay) {
            return false;
        }
        
        return supportStake >= opposeStake * supportThreshold;
    }
}