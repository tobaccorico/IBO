
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Amp} from "./Amp.sol";
import {Vogue} from "./Vogue.sol";
import {Rover} from "./Rover.sol";
import {Basket} from "./Basket.sol";

import {BasketLib} from "./BasketLib.sol";
import {Types} from "./imports/Types.sol";
import {VogueCore} from "./VogueCore.sol";

import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {DataTypes} from "aave-v3/protocol/libraries/types/DataTypes.sol";

import {IPool} from "aave-v3/interfaces/IPool.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {WETH as WETH9} from "solmate/src/tokens/WETH.sol";
import {IERC4626} from "forge-std/interfaces/IERC4626.sol";
import {IUniswapV3Pool} from "./imports/v3/IUniswapV3Pool.sol";
import {ReentrancyGuard} from "solmate/src/utils/ReentrancyGuard.sol";

interface IFlashBorrower {
    function onFlashLoan(
        address initiator,
        address token,
        uint256 amount,
        uint16 shareBps,
        bytes calldata data
    ) external returns (bytes32);
}

contract Aux is // Auxiliary
    Ownable, ReentrancyGuard {
    address[] internal stables;
    bool public token1isWETH;

    IERC20 internal USDC; Basket internal QUID;
    Vogue internal V4; VogueCore internal CORE;
    WETH9 public WETH; Rover internal V3;
    uint constant target = 500000 * WAD;
    IUniswapV3Pool internal v3PoolWETH;
    BasketLib.Metrics internal metrics;

    uint256 internal spValue;         // current BOLD principal in SP
    uint256 internal spTotalYield;    // cumulative harvested USD value (WAD)
    uint256 internal spPrincipalTime; // cumulative (principal * seconds)
    uint256 internal spLastUpdate;    // last update timestamp

    mapping(address => address) internal vaults;
    mapping(address => address) internal tokens;
    mapping(address => uint) internal toIndex;
    mapping(address => uint) internal untouchables;

    uint public untouchable;
    // ^ in vault shares, 1e18
    address internal v3Router;
    uint constant WAD = 1e18;
    uint constant RAY = 1e27;
    uint internal lastBlock;

    address internal jury;
    uint24 internal v3Fee;
    IPool internal AAVE;
    Amp internal AMP;

    error LengthMismatch();
    error Unauthorized();
    error NoLiquidity();
    modifier onlyUs {
        if (msg.sender != address(V4)
         && msg.sender != address(CORE)
         && msg.sender != address(QUID)
         && msg.sender != address(this)) revert Unauthorized(); _;
    }

    bytes32 constant CALLBACK_SUCCESS = keccak256(
                "ERC3156FlashBorrower.onFlashLoan");

    /// @notice init (plug) Aux with addresses
    /// @dev optional: V3 rover & AAVE amp...
    constructor(address _vogue, address _core,
        address _amp, address _aave,
        address _v3poolWETH,
        address _v3router, address _v3,
        address[] memory _stables,
        address[] memory _vaults)
        Ownable(msg.sender) {
        AAVE = IPool(_aave);
        v3Router = _v3router;
        lastBlock = block.number - 1;
        v3PoolWETH = IUniswapV3Pool(_v3poolWETH);
        address token0 = v3PoolWETH.token0();
        address token1 = v3PoolWETH.token1();

        if (IERC20(token1).decimals() >
            IERC20(token0).decimals()) {
            WETH = WETH9(payable(token1));
            USDC = IERC20(token0);
            token1isWETH = true;
        } else { token1isWETH = false;
            WETH = WETH9(payable(token0));
            USDC = IERC20(token1);
        } v3Fee = v3PoolWETH.fee();
        V4 = Vogue(payable(_vogue));
        CORE = VogueCore(_core);
        if (_amp != address(0))
            AMP = Amp(payable(_amp));
        if (_v3 != address(0))
            V3 = Rover(payable(_v3));

        if (_stables.length != _vaults.length) revert LengthMismatch();
        spLastUpdate = block.timestamp; stables = _stables;
        uint len = _vaults.length - 1; metrics.last = 1;
        metrics.trackingStart = block.timestamp;
        for (uint i; i <= len; i++) {
            address stable = _stables[i];
            address vault = _vaults[i];
            toIndex[stable] = i + 1;
            tokens[vault] = stable; vaults[stable] = vault;
            stable.call(abi.encodeWithSelector(0x095ea7b3,
                                vault, type(uint).max));
        }
    } fallback() external payable {}
    function get_metrics(bool force)
        public returns (uint, uint) {
        BasketLib.Metrics memory stats = metrics;
        uint elapsed = block.timestamp - stats.last;
        if (force || elapsed > 10 minutes) {
            uint[13] memory amounts = get_deposits();
            metrics = BasketLib.computeMetrics(stats,
                    elapsed, amounts[0], amounts[12]);
        } return (metrics.total, metrics.yield);
    }

    function getAverageYield() public view returns (uint) {
        return BasketLib.getAverageYield(metrics);
    }

    function setQuid(address _quid, address _jury,
        address _court) external onlyOwner {
        renounceOwnership(); QUID = Basket(_quid);
        QUID.setup(_court, _jury); jury = _jury;
        USDC.approve(v3Router, type(uint).max);
        WETH.approve(v3Router, type(uint).max);
        WETH.approve(address(V4), type(uint).max);
        WETH.approve(address(AAVE), type(uint).max);
        USDC.approve(vaults[stables[stables.length - 1]], type(uint).max);
        WETH.approve(address(AMP), type(uint).max);
        USDC.approve(address(AMP), type(uint).max);
        WETH.approve(address(V3), type(uint).max);
        USDC.approve(address(V3), type(uint).max);
    }

    function getTWAP(uint32 period)
        public view returns (uint price) {
        uint32[] memory secondsAgos = new uint32[](2);
        int56[] memory tickCumulatives; bool token0isUSD;
        if (period == 0) { secondsAgos[0] = 1800; secondsAgos[1] = 0;
            (tickCumulatives, ) = v3PoolWETH.observe(secondsAgos);
            period = 1800; token0isUSD = token1isWETH;
        } else {
            secondsAgos[0] = period; secondsAgos[1] = 0;
            tickCumulatives = CORE.observe(secondsAgos);
            token0isUSD = V4.token1isETH();
        }
        price = BasketLib.ticksToPrice(tickCumulatives[0],
                 tickCumulatives[1], period, token0isUSD);
    }

    function v3Fair(uint twapPrice) public view returns (bool) {
        return !BasketLib.isV3Manipulated(address(v3PoolWETH),
                                      token1isWETH, twapPrice);
    }

    /// @param token either token we are paying or want to get
    /// @param forETH ^ for $ --> ETH, opposite for ETH --> $
    /// @param amount Amount to swap (either ETH, QD, or $)
    /// @param minOut Minimum output (slippage protection)
    function swap(address token, bool forETH, uint amount, uint minOut)
        public payable nonReentrant returns (uint max) {
        Types.AuxContext memory ctx = _buildContext();
        (uint160 sqrtPriceX96,,,) = V4.repack();
        bool stable; bool zeroForOne;
        stable = toIndex[token] > 0;
        if (!forETH) {
            if (token != address(QUID)) require(stable);
            amount = _depositETH(msg.sender, amount);
            zeroForOne = !V4.token1isETH();
            max = CORE.POOLED_USD();
        }
        else { max = CORE.POOLED_ETH();
            zeroForOne = V4.token1isETH();
            address vault = tokens[token];
            uint index = toIndex[vault];
            if (index > 4) { if (token == vaults[stables[10]])
                                 token = address(USDC);

                amount = _withdraw(address(this),
                                  index, amount);
            } else require(stable);

            amount = token == address(QUID) ?
               QUID.turn(msg.sender, amount):
               deposit(msg.sender, token, amount);

            token = address(0);
        }
        max = BasketLib.routeSwap(ctx, address(CORE),
            address(V3), sqrtPriceX96, zeroForOne,
            token, amount, max, getTWAP(1800),
            getTWAP(0), msg.sender);
            require(max >= minOut);
    }

    function _buildContext() internal view returns (Types.AuxContext memory) {
        return Types.AuxContext({ v3Pool: address(v3PoolWETH), v3Router: v3Router,
            weth: address(WETH), usdc: address(USDC), vault: address(AAVE),
            v4: address(V4), v3Fee: v3Fee, isAAVE: true });
    }

    function arbETH(uint shortfall)
        public onlyUs returns (uint got) {
        (got,) = BasketLib.arbETH(_buildContext(),
                            shortfall, getTWAP(0));
    }

    /// @notice leveraged long (borrow WETH against USDC)
    /// @dev 70% LTV on AAVE, excess USDC as collateral
    /// @param amount WETH amount to deposit in AAVE
    function leverETH(uint amount) payable
        external { uint twapPrice = getTWAP(0);
        amount = _depositETH(msg.sender, amount);
        uint usdcNeeded = BasketLib.convert(amount, twapPrice, false);
        uint took = _take(address(this), usdcNeeded, address(USDC), false);
        if (took <= usdcNeeded) { // TODO why use getTWAP(0) first then pass in getTWAP(1800)??
            require(v3Fair(twapPrice));
            (uint more, uint used) = BasketLib.source(_buildContext(),
                address(V4), address(V3), usdcNeeded - took, amount,
                twapPrice, getTWAP(1800), true);
                   took += more; amount -= used;

        } require(took >= usdcNeeded * 99 / 100);
        AMP.leverETH(msg.sender, amount, took / 1e12);
    }

    function leverUSD(uint amount, address token)
        external returns (uint usdcAmount) {
        usdcAmount = amount; uint160 sqrtPriceX96;
        if (token == address(USDC)) {
            USDC.transferFrom(msg.sender,
                address(this), usdcAmount);
        } else {
            (sqrtPriceX96,,,) = V4.repack();
            uint depositedAmount = deposit(
             msg.sender, token, usdcAmount);
            uint scale = IERC20(token).decimals() - 6;
            depositedAmount /= scale > 0 ? 10 ** scale : 1;

            // Swap stable → ETH → USDC through V4 pool
            CORE.swap(sqrtPriceX96, address(this),
            V4.token1isETH(), token, depositedAmount);
            uint ethReceived = address(this).balance;

            WETH.deposit{value: ethReceived}();
            AAVE.supply(address(WETH),
            ethReceived, address(V4), 0);

            uint usdcBefore = USDC.balanceOf(address(this));
            CORE.swap(sqrtPriceX96, address(this),
            !V4.token1isETH(), address(USDC), ethReceived);

            usdcAmount = USDC.balanceOf(
            address(this)) - usdcBefore;
        }   uint twapPrice = getTWAP(0);

        require(v3Fair(twapPrice));
        uint targetETH = BasketLib.convert(
           usdcAmount, getTWAP(1800), true);

        (uint inETH, uint spent) = BasketLib.source(
            _buildContext(), address(V4), address(V3),
            targetETH, usdcAmount, twapPrice, 0, false);

        usdcAmount -= spent;
        require(inETH >= targetETH * 99 / 100);
        USDC.approve(address(AMP), usdcAmount);
        AMP.leverUSD(msg.sender, usdcAmount, inETH);
    }

    /// @notice Convert Basket tokens into dollars
    /// @param amount of tokens to redeem, 1e18
    function redeem(uint amount)
        external { uint price = getTWAP(1800);
        (uint total, ) = get_metrics(false);
        uint reserved = CORE.POOLED_ETH();
        uint pooledUSD = CORE.POOLED_USD() * 1e12;
        uint usdAvailable = total > pooledUSD ?
                            total - pooledUSD : 0;

        uint ethAvailable = BasketLib.aaveAvailable(
                        address(AAVE), address(WETH));

        uint ethExcess = ethAvailable > reserved ?
                         ethAvailable - reserved : 0;

        uint ethValue = FullMath.mulDiv(
                  ethExcess, price, WAD);

        amount = QUID.turn(msg.sender, Math.min(amount,
                             usdAvailable + ethValue));

        if (amount == 0) return;
        uint taken = _take(msg.sender,
        amount, address(QUID), false);

        if (taken < amount) {
            uint ethToUse = Math.min(FullMath.mulDiv(
               amount - taken, WAD, price), ethExcess);

            if (ethToUse > 0) { price = getTWAP(0);
                uint received = V4.takeETH(ethToUse, address(this));
                WETH.deposit{value: received}(); require(v3Fair(price));
                received = BasketLib.sourceExternalUSD(_buildContext(),
                                         address(V3), received, price);

                if (received > 0) IERC20(stables[0]).transfer(
                                         msg.sender, received);
            }
        }
    }

    function get_deposits() public view returns
        (uint[13] memory amounts) { uint i;
        address vault; address stable;
        for (i = 0; i < 4; i++) {
            vault = AAVE.getReserveAToken(stables[i]);
            if (IERC20(vault).balanceOf(address(this)) > 0) {
                uint multiplier = i < 2 ? 1e12 : 1; stable = stables[i];
                DataTypes.ReserveDataLegacy memory res = AAVE.getReserveData(stable);
                uint128 currentLiquidityRate = res.currentLiquidityRate;
                uint shares = IERC20(vault).balanceOf(address(this));
                shares *= multiplier; shares -= Math.min(shares,
                                            untouchables[stable]);
                                                                // TODO is currentLiquidityRate
                                                                // already representative of token's precision
                amounts[0] += shares; amounts[i + 1] = shares;
                amounts[12] += FullMath.mulDiv(shares, // TODO check precision
                            currentLiquidityRate, RAY); // all tokens except USDC/USDT are 1e8
            }
        } for (i = 4; i < 9; i++) {
            stable = stables[i]; vault = vaults[stable];
            uint shares = IERC4626(vault).balanceOf(address(this));
            shares -= IERC4626(vault).convertToShares(untouchables[stable]);
            if (shares > 0) { amounts[i + 1] = shares; amounts[0] += shares;
                uint assets = IERC4626(vault).convertToAssets(shares);
                if (IERC4626(vault).totalSupply() > 0) {
                    amounts[12] += FullMath.mulDiv(shares,
                        IERC4626(vault).totalAssets(),
                        IERC4626(vault).totalSupply());
                }
            }
        } stable = stables[10]; vault = vaults[stable];
        (uint usycValue, uint usycYield) = BasketLib.getUSYCValue(
                                             vault, address(this));
        if (usycValue > 0) {
            usycValue -= untouchables[stable]; amounts[0] += usycValue;
            amounts[11] = usycValue; amounts[12] += usycYield;
        }  stable = stables[9]; vault = vaults[stable];

        (uint spTotal, uint spYieldContrib) = BasketLib.calcSPValue(
            vault, address(this), untouchables[stable], BasketLib.SPState(
                    spValue, spTotalYield, spPrincipalTime, spLastUpdate));

        if (spTotal > 0) { amounts[12] += spYieldContrib;
            amounts[10] = spTotal; amounts[0] += spTotal;
        }
    }

    function getFee(address token)
        public view returns (uint) {
        // 'Cause though the truth may vary...
        // ship carry our bodies safe to shore
        return BasketLib.calcFeeL1WithLookup(
        token, get_deposits(), stables, jury);
    }

    /// @notice Get USYC amount redeemable today (min of balance and daily limit)
    /// @dev msg.sender in BasketLib will be Aux (this contract), which is correct
    /// @return Redeemable amount scaled to 1e18
    function getUSYCRedeemable() public view returns (uint) {
        address teller = vaults[stables[stables.length - 1]];
        return BasketLib.getUSYCRedeemable(teller);
    }

    // she let me into a conversation, conversation only kate could make
    // breaking into my imagination: whatever's there, was hers to take
    function _take(address who, uint amount, address token, bool strict)
        internal returns (uint sent) { uint index = toIndex[token];
        address vault; address skip;
        if (token != address(QUID)) { skip = token;
            require(index > 0 && index < 12);
            uint fee = (getFee(token) * WAD) / 10000;
            uint needed = (fee > 0 && fee < WAD / 10) ?
                FullMath.mulDiv(amount, WAD + fee, WAD) : amount;

            // TODO will this withdraw the most we can?
            sent = _withdraw(who, index, needed);
            if (strict) { _tip(sent, token, -1);
                return FullMath.mulDiv(sent,
                        WAD - fee, WAD);
            }
            amount = sent >= amount ? 0 : amount - sent;
            sent = BasketLib.scaleTokenAmount(sent, token, true);
            amount = BasketLib.scaleTokenAmount(amount, token, true);

        } uint[13] memory amounts = get_deposits();
        if (amounts[0] == 0 || amount == 0) return sent;
        uint min = amounts[0]; amount = !strict ?
                 Math.min(min, amount) : amount;

        for (uint i = 1; i <= stables.length; i++) {
            token = stables[i - 1]; if (token == skip) continue;
            amounts[i] = FullMath.mulDiv(amount, FullMath.mulDiv(WAD,
                                        amounts[i], amounts[0]), WAD);
            if (strict) { untouchable -= amounts[i];
                untouchables[token] -= amounts[i];
            }
            if (amounts[i] > 0) {
                uint divisor = (i - 1) > 1 ?
                                    1 : 1e12;
                amounts[i] = _withdraw(who, i,
                        amounts[i] / divisor);
                sent += amounts[i] * divisor;
            }
        }
    }

    // intentionally don't check that sent == passed in
    function take(address who, uint amount, address token,
        bool strict) public onlyUs returns (uint) {
            return _take(who, amount, token, strict);
    }

    function _withdraw(address to,
        uint index, uint amount) internal
        returns (uint sent) { address vault;
        // sent is 1e16 for USDC & USDT...
        if (amount == 0) return 0;
        if (index == 10) { address bold = stables[9]; vault = vaults[bold];
            BasketLib.SPWithdrawResult memory r = BasketLib.withdrawFromSP(vault,
                bold, address(WETH), amount, getTWAP(0), BasketLib.SPState(spValue,
                                    spTotalYield, spPrincipalTime, spLastUpdate));

            if (r.boldReceived == 0) return 0;
            spValue = r.newSpValue;
            spTotalYield = r.newSpTotalYield;
            spPrincipalTime = r.newSpPrincipalTime;
            spLastUpdate = r.newSpLastUpdate; sent = r.sent;
            if (r.wethGain > 0) V4.depositYield(r.wethGain);
        } else if (index < 5) { vault = stables[index - 1];
            if (index == 2) { (sent,) = BasketLib.withdrawUSYC(
                               vaults[stables[10]], to, amount); amount -= sent;
            } if (amount > 0) { amount = Math.min(amount, BasketLib.aaveAvailable(
                                                            address(AAVE), vault));
                sent += AAVE.withdraw(vault, amount, to);
            }
        } else if (index != 11) { vault = vaults[stables[index - 1]];
            (amount,) = BasketLib.calculateVaultWithdrawal(vault, amount);
            if (amount == 0) return 0; // Skip if no shares to redeem
            sent = IERC4626(vault).redeem(amount, to, address(this));
        } else
            (sent,) = BasketLib.withdrawUSYC(stables[10], to, amount);
    }

    // there's never an incentive
    // for EOAs to call this since
    // mint() is the only way to
    // get yield for a deposit...
    // so it's assumed only our
    // contracts will call this...
    function deposit(address from,
        address token, uint amount) public
        returns (uint usd) { address vault;
        if (tokens[token] != address(0)
         && token != address(AAVE)) {
            amount = Math.min(Math.min(
                IERC4626(token).convertToShares(amount),
                IERC4626(token).balanceOf(address(this))),
                IERC4626(token).allowance(from, address(this)));

            usd = IERC4626(token).convertToAssets(amount);
            require(usd > 0); token = tokens[token];
            require(IERC4626(token).transferFrom(from,
                                address(this), amount));
        } else { uint index = toIndex[token];
            require(index > 0 && index < 12);
            usd = Math.min(amount, IERC20(token).allowance(
                                       from, address(this)));

            require(IERC20(token).transferFrom(from,
                                  address(this), usd));
            require(usd > 0);
            (usd, amount) = _supply(token, index, usd);
        }
        if (untouchable < target
        && msg.sender == address(QUID)) {
            if (token == address(USDC)) {
                _tip(BasketLib.depositFee(usd,
                    untouchable, target), token, 1);

                token = stables[stables.length - 1];
                _tip(BasketLib.depositFee(amount,
                    untouchable, target), token, 1);
            } else
                _tip(BasketLib.depositFee(usd + amount,
                      untouchable, target), token, 1);
        }
    }

    function _tip(uint cut, address token, int sign) internal {
        cut = BasketLib.scaleTokenAmount(cut, token, true);
        if (sign > 0) {
                 untouchables[token] += cut; untouchable += cut;
        } else { untouchables[token] -= cut; untouchable -= cut;
        }
    }

    function _depositETH(address sender,
        uint amount) internal returns (uint sent) {
        if (msg.value > 0) { sent = msg.value;
            WETH.deposit{value: msg.value}();
        }
        if (amount > 0) { uint available = Math.min(
                WETH.allowance(sender, address(this)),
                WETH.balanceOf(sender));

            uint took = Math.min(amount, available);
            if (took > 0) { WETH.transferFrom(sender,
                                address(this), took);
                                        sent += took;
            }
        } require(sent > 0);
    }

    /// @notice Atomic flash loan...
    /// @dev tip compounds into basket
    /// @param token Stable token to borrow
    /// @param amount Token amount (native decimals)
    /// @param shareBps LP Profit share signals
    /// higher priority to builders/sequencers
    /// commitment (100 = 1% min, 10000 = 100%)
    /// @param data unused (passed to callback)
    function flashLoan(address token,
        uint256 amount, uint16 shareBps,
        bytes calldata data) external nonReentrant
        returns (bool) { uint index; uint sent;
        bool weth = token == address(WETH);
        sent = weth ? V4.takeETH(amount, msg.sender):
             _take(msg.sender, amount, token, false);

        bytes32 result = IFlashBorrower(msg.sender).onFlashLoan(
                        msg.sender, token, sent, shareBps, data);

        uint returned = IERC20(token).balanceOf(address(this));
        require(result == CALLBACK_SUCCESS && returned >= sent);
        if (weth) { WETH.transfer(address(V4), returned);
                                 V4.depositFlashReturn();
        } else _supply(token, toIndex[token], returned);
        return true;
    }

    function _supply(address token, uint index,
        uint usd) internal returns (uint, uint) {
        address vault = vaults[token]; uint amount;
        if (index == 10) // BOLD -> Stability Pool
            (spValue, spPrincipalTime, spLastUpdate) = BasketLib.depositToSP(
                        vault, usd, BasketLib.SPState(spValue, spTotalYield,
                                            spPrincipalTime, spLastUpdate));
        else if (index < 5) { // AAVE: USDT(1), USDC(2), GHO(3), PYUSD(4)
            if (index == 2) // USDC also deposits to USYC
                (amount, usd) = BasketLib.depositUSYC(
                    vaults[stables[10]], address(AAVE),
                    address(USDC), usd, CORE.POOLED_USD());
            if (usd > 0)
                AAVE.supply(token, usd,
                    address(this), 0);
        } // DAI(5), USDS(6), FRAX(7), USDE(8), CRVUSD(9)
        else if (index != 11)  // 4626 returns shares...
            usd = IERC4626(vault).convertToAssets(
                    IERC4626(vault).deposit(usd,
                                address(this)));
        return (usd, amount);
    }
}
