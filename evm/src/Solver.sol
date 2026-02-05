
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Types} from "./imports/Types.sol";

/// @notice Bebop JAM settlement interface (settle path)
interface IJamSettlement {
    function settle(Types.JamOrder calldata order,
        bytes calldata signature, // raw EIP-712 sig bytes
        Types.Interaction[] calldata interactions,
        bytes memory hooksData, // ABI-encoded hooks (or "")
        address balanceRecipient // where taker sell tokens go
    ) external payable;
}

interface IAux {
    function flashLoan(
        address borrower,
        address token,
        uint256 amount,
        uint16 shareBps,
        bytes calldata data
    ) external returns (bool);
}

/// @title JamSolver
/// @notice Aux-capitalized solver for Bebop JAM settlements.
///
/// @dev Architecture: settle wraps flashLoan (not the reverse).
///
///   JamSettlement.settle() runs interactions via runInteractions,
///   where msg.sender = JamSettlement. The flashLoan call lives inside
///   that interaction list, so Aux can gate with a single require:
///
///     require(msg.sender == jamSettlement)
///
///   This is the inherent gate — no flags, no hooks, no coordination.
///
///   Token flow for a typical order (taker sells WETH, buys USDC):
///
///   1. solve() calls JamSettlement.settle()
///   2. settle step 5: taker's WETH → Solver (balanceRecipient)
///   3. settle step 6: runInteractions → Aux.flashLoan(Solver, USDC, ...)
///        msg.sender = JamSettlement ✓
///        Aux sends 2000 USDC → Solver
///        Solver.onFlashLoan():
///          a. callbackOps route buy tokens to JamSettlement
///             (e.g. USDC.transfer(jamSettlement, 2000))
///          b. callbackOps swap sell tokens for repayment
///             (e.g. DEX swap WETH → 2050 USDC)
///          c. profit split: tip to Aux, rest stays
///          d. principal + tip → Aux
///        Aux checks returned >= sent ✓
///   4. settle step 7: USDC on JamSettlement → taker ✓
///
///   shareBps is the priority auction signal:
///   higher share → more yield to basket LPs → better orchestrator score
///   → more order flow.
///
contract JamSolver is Ownable {
    bytes32 constant CALLBACK_SUCCESS =
        keccak256("ERC3156FlashBorrower.onFlashLoan");

    address public immutable aux;
    address public jamSettlement;

    error Unauthorized();
    error Insolvent();
    error CallFailed();

    event Settled(
        address indexed solver,
        address indexed token,
        uint256 borrowed,
        uint256 profit,
        uint256 auxShare
    );

    constructor(
        address _aux,
        address _jamSettlement
    ) Ownable(msg.sender) {
        aux = _aux;
        jamSettlement = _jamSettlement;
    }

    /// @notice Execute a JAM settlement using Aux flash loan
    /// @param token        Token to borrow from Aux (typically the buy token)
    /// @param amount       Amount to borrow
    /// @param shareBps     Profit share to Aux LPs (5000 = 50%)
    /// @param order        Bebop JAM order
    /// @param signature    Raw EIP-712 taker signature
    /// @param hooksData    ABI-encoded hooks (pass "" if none)
    /// @param callbackOps  Operations executed inside the flash loan callback.
    ///                     The operator constructs these off-chain to:
    ///                       1. Route buy tokens to JamSettlement
    ///                          (e.g. USDC.transfer(jamSettlement, buyAmt))
    ///                       2. Swap sell tokens back to borrowed token
    ///                          (e.g. DEX swap WETH → USDC)
    ///                     Profit split + repayment are handled automatically.
    function solve(
        address token,
        uint256 amount,
        uint16 shareBps,
        Types.JamOrder calldata order,
        bytes calldata signature,
        bytes calldata hooksData,
        Types.Interaction[] calldata callbackOps
    ) external onlyOwner {
        // Single interaction: the flash loan itself.
        // JamSettlement.runInteractions calls to.call{value}(data),
        // making msg.sender = jamSettlement at Aux.flashLoan. This
        // is the structural gate — no other path satisfies it.
        Types.Interaction[] memory ix = new Types.Interaction[](1);
        ix[0] = Types.Interaction({
            result: true, // flashLoan returns bool
            to:     aux,
            value:  0,
            data:   abi.encodeWithSelector(
                        IAux.flashLoan.selector,
                        address(this), // borrower
                        token,
                        amount,
                        shareBps,
                        abi.encode(callbackOps)
                    )
        });

        IJamSettlement(jamSettlement).settle(
            order,
            signature,
            ix,
            hooksData,
            address(this) // balanceRecipient = this solver
        );
    }

    /// @notice ERC-3156 flash loan callback
    /// @dev Called by Aux during flashLoan (which itself runs inside
    ///      JamSettlement.settle → runInteractions). At this point the
    ///      Solver already holds sell tokens from settle step 5, and
    ///      just received borrowed tokens from Aux. The callbackOps
    ///      route buy tokens onto JamSettlement and convert sell tokens
    ///      into the borrowed token for repayment.
    function onFlashLoan(
        address initiator,
        address token,
        uint256 amount,
        uint16 shareBps,
        bytes calldata data
    ) external returns (bytes32) {
        if (msg.sender != aux) revert Unauthorized();
        if (initiator != address(this)) revert Unauthorized();

        Types.Interaction[] memory ops = abi.decode(
            data, (Types.Interaction[])
        );

        // Execute callback operations (operator-constructed):
        //   - transfer buy tokens to JamSettlement
        //   - DEX swaps to convert sell tokens → borrowed token
        //   - any other routing the operator needs
        for (uint i; i < ops.length; ++i) {
            (bool ok,) = ops[i].to.call{
                value: ops[i].value
            }(ops[i].data);
            if (!ok) revert CallFailed();
        }

        // ── Profit split ──────────────────────────────────────
        {
            uint256 bal = IERC20(token).balanceOf(address(this));
            if (bal < amount) revert Insolvent();
            uint256 tip = ((bal - amount) * shareBps) / 10000;
            IERC20(token).transfer(aux, amount + tip);
            emit Settled(owner(), token, amount, bal - amount, tip);
        }
        return CALLBACK_SUCCESS;
    }

    // ── Admin ───────────────────────────────────────────────────

    /// @notice Update JAM settlement address
    function setJamSettlement(address _jam) external onlyOwner {
        jamSettlement = _jam;
    }

    /// @notice Withdraw accumulated profits or stuck tokens
    function rescue(address token, uint256 amount) external onlyOwner {
        IERC20(token).transfer(owner(), amount);
    }

    /// @notice Rescue stuck ETH
    function rescueETH() external onlyOwner {
        payable(owner()).transfer(address(this).balance);
    }

    receive() external payable {}
}
