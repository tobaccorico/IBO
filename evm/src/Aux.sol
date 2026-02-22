
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Amp} from "./Amp.sol";
import {Vogue} from "./Vogue.sol";
import {Rover} from "./Rover.sol";
import {Basket} from "./Basket.sol";
import {Hook} from "./Hook.sol";

import {Types} from "./imports/Types.sol";
import {VogueCore} from "./VogueCore.sol";
import {FeeLib} from "./imports/FeeLib.sol";
import {BasketLib} from "./imports/BasketLib.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {WETH as WETH9} from "solmate/src/tokens/WETH.sol";
import {IERC4626} from "forge-std/interfaces/IERC4626.sol";
import {IUniswapV3Pool} from "./imports/v3/IUniswapV3Pool.sol";
import {ReentrancyGuard} from "solmate/src/utils/ReentrancyGuard.sol";

import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

interface IFlashBorrower {
    function onFlashLoan(address initiator,
        address token, uint amount,
        uint shareBps, bytes calldata data)
        external returns (bytes32);
}

interface AAVEv3 {
    function getReserveAToken(address asset)
            external view returns (address);

    function supply(address asset, uint amount,
    address onBehalfOf, uint16 referralCode) external;

    function withdraw(address asset, uint amount,
            address to) external returns (uint);
}

interface IHub {
    function getAssetId(address underlying)
            external view returns (uint256);
}

interface IHook {
    function getDepegStats(address) external view
        returns (Types.DepegStats memory);
}

interface AAVEv4 {
    function getReserveId(address hub,
    uint assetId) external returns (uint);

    function withdraw(uint reserveId,
    uint amount, address onBehalfOf)
    external returns (uint, uint);

    function supply(uint reserveId,
    uint amount, address onBehalfOf)
    external returns (uint256, uint256);

    function getUserSuppliedAssets(uint reserveId,
        address user) external view returns (uint);

    function getUserSuppliedShares(uint reserveId,
        address user) external view returns (uint);
}

contract Aux is // Auxiliary
    Ownable, ReentrancyGuard {
    address[] public stables;
    bool public token1isWETH;

    IERC20 internal USDC; Basket internal QUID;
    Vogue internal V4; VogueCore internal CORE;
    WETH9 public WETH; Rover internal V3;
    IUniswapV3Pool internal v3PoolWETH;
    BasketLib.Metrics internal metrics;

    uint internal spValue; // current BOLD principal in SP
    uint internal spTotalYield; // cumulative harvested USD
    uint internal spPrincipalTime; // (principal * seconds)
    uint internal spLastUpdate; // last update timestamp...
    uint internal _lastTotalETH; // AAVE WETH at last sync
    uint public vogueETH; // WETH attributed to Vogue pool

    mapping(address => uint) public untouchables;
    mapping(address => address) public vaults;
    mapping(address => address) public tokens;
    mapping(address => uint) internal toIndex;

    uint public untouchable;
    // ^ in vault shares, 1e18
    address internal v3Router;
    uint constant WAD = 1e18;
    uint constant RAY = 1e27;
    uint internal lastBlock;

    address internal JAM;
    AAVEv3 internal POOL;
    uint24 internal v3Fee;
    AAVEv4 internal SPOKE;
    address internal HOOK;
    IHub internal HUB;
    Amp internal AMP;

    error LengthMismatch();
    error Unauthorized();
    modifier onlyUs {
        if (msg.sender != address(V4)
         && msg.sender != address(CORE)
         && msg.sender != address(QUID)
         && msg.sender != address(this))
            revert Unauthorized(); _;
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
        POOL = AAVEv3(_aave);
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
            // amounts[12] = raw TVL, amounts[0] = yield-weighted
            metrics = BasketLib.computeMetrics(stats,
                elapsed, amounts[12], amounts[0], amounts[12]);
        } return (metrics.total, metrics.yield);
    }

    function getAverageYield()
        public view returns (uint) {
        return BasketLib.getAverageYield(metrics);
    }

    function getStables() external view
        returns (address[] memory) { return stables;
    } function setQuid(address _quid, address _jam)
        external onlyOwner { QUID = Basket(_quid);
        HOOK = address(QUID.HOOK()); JAM = _jam;
        USDC.approve(v3Router, type(uint).max);
        WETH.approve(v3Router, type(uint).max);
        WETH.approve(address(V4), type(uint).max);
        WETH.approve(address(POOL), type(uint).max);
        USDC.approve(vaults[stables[stables.length - 1]], type(uint).max);
        WETH.approve(address(AMP), type(uint).max);
        USDC.approve(address(AMP), type(uint).max);
        WETH.approve(address(V3), type(uint).max);
        USDC.approve(address(V3), type(uint).max);
    } //

    function setV4(address _hub, address _spoke) external
        onlyOwner { require(!AMP.hasOpenDebt());
        uint i; uint[4] memory amounts; uint reserveId; address stable;
        uint weth = _withdrawAAVE(address(WETH), _availableETH(),
                    address(this), address(HUB) != address(0));
        for (i = 0; i < 4; i++) { stable = stables[i];
            amounts[i] = _withdrawAAVE(stable, 0,
            address(this), address(HUB) != address(0));
        } SPOKE = AAVEv4(_spoke); HUB = IHub(_hub);
        WETH.approve(_hub, type(uint).max);
        for (i = 0; i < 4; i++) {
            IERC20(stables[i]).approve(
                  _hub, type(uint).max);

            _supplyAAVE(stables[i], amounts[i],
                        address(this), true);

        } _supplyAAVE(address(WETH),
         weth, address(this), true);
        _lastTotalETH = _availableETH();
        AMP.setV4(_hub, _spoke);
        renounceOwnership();
    }

    function getTWAP(uint32 period)
        public view returns (uint price) {
        uint32[] memory secondsAgos = new uint32[](2);
        int56[] memory tickCumulatives; bool token0isUSD;
        if (period == 0) { secondsAgos[0] = 1800; secondsAgos[1] = 0;
            (tickCumulatives, ) = v3PoolWETH.observe(secondsAgos);
            period = 1800; token0isUSD = token1isWETH;
        } else { secondsAgos[0] = period; secondsAgos[1] = 0;
            tickCumulatives = CORE.observe(secondsAgos);
            token0isUSD = V4.token1isETH();
        } price = BasketLib.ticksToPrice(tickCumulatives[0],
                    tickCumulatives[1], period, token0isUSD);
    } function v3Fair(uint twapPrice) internal view returns (bool) {
        return !BasketLib.isV3Manipulated(address(v3PoolWETH),
                                      token1isWETH, twapPrice);
    } /// @param token either token we are paying or want to get
    /// @param forETH ^ for $ --> ETH, opposite for ETH --> $
    /// @param amount Amount to swap (either ETH, QD, or $)
    /// @param minOut Minimum output (slippage protection)
    function swap(address token, bool forETH, uint amount,
        uint minOut) public payable nonReentrant returns
        (uint max) { bool stable; bool zeroForOne;
        Types.AuxContext memory ctx = _buildContext();
        (uint160 sqrtPriceX96,,,) = V4.repack();
        stable = toIndex[token] > 0;
        if (!forETH) {
            if (token != address(QUID)) require(stable);
            amount = _depositETH(msg.sender, amount);
            zeroForOne = !V4.token1isETH();
            max = CORE.POOLED_USD();
        } else { max = CORE.POOLED_ETH();
            zeroForOne = V4.token1isETH();
            if (token == address(QUID)) {
                (uint burned, uint seedBurned) = QUID.turn(
                                        msg.sender, amount);
                amount = burned;
                if (seedBurned > 0) {
                    for (uint i = 0; i < stables.length; i++) {
                        uint share = FullMath.mulDiv(
                            untouchables[stables[i]],
                            seedBurned, burned);
                        _tip(share, stables[i], -1);
                    }
                }
            } else {
                address vault = tokens[token];
                uint index = toIndex[vault];
                if (index > 4) { if (token == vaults[stables[10]])
                                     token = address(USDC);
                    amount = _withdraw(address(this),
                                      index, amount);
                } else require(stable);
                amount = deposit(msg.sender,
                              token, amount);
            }   token = address(0);
        } _syncETH();
        uint poolSupplied;
        (max, poolSupplied) = BasketLib.routeSwap(ctx,
            Types.RouteParams({ sqrtPriceX96: sqrtPriceX96,
                zeroForOne: zeroForOne, token: token,
                amount: amount, pooled: max,
                v4Price: getTWAP(1800),
                v3Price: getTWAP(0),
                recipient: msg.sender
            }));
            if (poolSupplied > 0) {
                vogueETH += poolSupplied;
                _lastTotalETH = _availableETH();
            }   require(max >= minOut);
    }

    function _buildContext() internal view
        returns (Types.AuxContext memory) {
        address aave = address(SPOKE) != address(0) ? address(SPOKE) : address(POOL);
        return Types.AuxContext({ v3Pool: address(v3PoolWETH), hub: address(HUB),
            v3Router: v3Router, weth: address(WETH), usdc: address(USDC),
            vault: aave, v4: address(V4), core: address(CORE),
            rover: address(V3), v3Fee: v3Fee, isAAVE: true });
    }

    function arbETH(uint shortfall)
        public onlyUs returns (uint got) {
        _syncETH();
        (got,) = BasketLib.arbETH(_buildContext(),
                            shortfall, getTWAP(0));
        if (got > 0) {
            vogueETH += got;
            _lastTotalETH = _availableETH();
        }
    }

    /// @notice Proportional AAVE
    /// yield attribution to Vogue
    function _syncETH() internal {
        if (_lastTotalETH > 0) {
            uint avail = _availableETH();
            if (avail > _lastTotalETH)
                vogueETH += (avail - _lastTotalETH)
                          * vogueETH / _lastTotalETH;
            _lastTotalETH = avail;
        }
    }

    /// @notice Unified Vogue ETH operation
    /// @param op 0=deposit, 1=take, 2=sync
    function vogueETHOp(uint amount, uint8 op)
        external returns (uint ret) {
        require(msg.sender == address(V4));
        if (op == 0) { // deposit
            WETH.transferFrom(msg.sender, address(this), amount);
            _supplyAAVE(address(WETH), amount, address(this),
                address(HUB) != address(0)); vogueETH += amount;
        } else if (op == 1) { // take
            amount = Math.min(amount, vogueETH);
            ret = _withdrawAAVE(address(WETH), amount,
            address(this), address(HUB) != address(0));
            vogueETH -= Math.min(ret, vogueETH);
            WETH.transfer(msg.sender, ret);
        } else { // sync
            _syncETH(); ret = vogueETH;
        }
    }

    /// @notice leveraged long (borrow WETH against USDC)
    /// @dev 70% LTV on AAVE, excess USDC as collateral
    /// @param amount WETH amount to deposit in AAVE
    function leverETH(uint amount) payable
        external { uint twapPrice = getTWAP(0);
        amount = _depositETH(msg.sender, amount);
        uint usdcNeeded = BasketLib.convert(
                    amount, twapPrice, false);

        uint took = _take(address(this),
          usdcNeeded, address(USDC), 0);
        if (took <= usdcNeeded) { require(v3Fair(twapPrice));
            (uint more, uint used) = BasketLib.source(_buildContext(),
                            usdcNeeded - took, amount, twapPrice, true);
            took += more;
            amount -= used;
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
            _supplyAAVE(address(WETH), ethReceived,
            address(this), address(HUB) != address(0));
            uint usdcBefore = USDC.balanceOf(address(this));
            CORE.swap(sqrtPriceX96, address(this), !V4.token1isETH(),
                address(USDC), ethReceived); vogueETH += ethReceived;

            usdcAmount = USDC.balanceOf(
            address(this)) - usdcBefore;
        }   uint twapPrice = getTWAP(0);

        require(v3Fair(twapPrice));
        uint targetETH = BasketLib.convert(
           usdcAmount, getTWAP(1800), true);

        (uint inETH, uint spent) = BasketLib.source(
                            _buildContext(), targetETH,
                            usdcAmount, twapPrice, false);
        usdcAmount -= spent;
        require(inETH >= targetETH * 99 / 100);
        USDC.approve(address(AMP), usdcAmount);
        AMP.leverUSD(msg.sender, usdcAmount, inETH);
    }

    /// @notice Convert Basket tokens into dollars
    /// @param amount of tokens to redeem, 1e18...
    function redeem(uint amount) external {
        (uint total,) = get_metrics(false);
        uint price = getTWAP(1800); _syncETH();
        uint ethAvailable = _availableETH();

        uint pooledUSD = CORE.POOLED_USD() * 1e12;
        uint usdAvailable = total > pooledUSD ?
                            total - pooledUSD : 0;

        uint ethExcess = ethAvailable > vogueETH ?
                         ethAvailable - vogueETH : 0;

        uint ethValue = FullMath.mulDiv(
                  ethExcess, price, WAD);

        uint reserved = Math.min(amount,
                usdAvailable + ethValue);

        (uint burned, uint seedBurned) = QUID.turn(
        msg.sender, Math.min(reserved, usdAvailable));

        uint taken = _take(msg.sender, burned,
                    address(QUID), seedBurned);

        if (taken < reserved) {
            uint ethToUse = Math.min(FullMath.mulDiv(
            reserved - taken, WAD, price), ethExcess);

            if (ethToUse > 0) { price = getTWAP(0); require(v3Fair(price));
                uint received = _withdrawAAVE(address(WETH), ethToUse,
                            address(this), address(HUB) != address(0));

                received = BasketLib.sourceExternalUSD(_buildContext(),
                                                      received, price);

                if (received > 0) IERC20(stables[0]).transfer(
                                         msg.sender, received);
            }
        }
    }

    function get_deposits() public
        returns (uint[13] memory amounts) {
        amounts = BasketLib.get_deposits(address(this), address(HUB)
        != address(0) ? address(SPOKE): address(POOL), address(HUB), stables);
        address stable = stables[9]; address vault = vaults[stable];
        (uint spTotal, uint spYieldWeighted) = BasketLib.calcSPValue(vault, address(this),
                      untouchables[stable], BasketLib.SPState(spValue,
                          spTotalYield, spPrincipalTime, spLastUpdate));

        if (spTotal > 0) { amounts[12] += spTotal;
                           amounts[10] = spTotal;
                           amounts[0] += spYieldWeighted; }
    }

    /// @notice Get USYC amount redeemable today
    /// @dev msg.sender in BasketLib will be Aux
    /// @return Redeemable amount scaled to 1e18
    function getUSYCRedeemable() public view returns (uint) {
        address teller = vaults[stables[stables.length - 1]];
        return BasketLib.getUSYCRedeemable(teller);
    }

    // she let me into a conversation, conversation only kate could make
    // breaking into my imagination: whatever's there, was hers to take
    function _take(address who, uint amount, address token, uint seed)
        internal returns (uint sent) { address vault; address skip;
        uint index = toIndex[token];
        uint[13] memory amounts = get_deposits();
        if (token != address(QUID)) { skip = token;
            require(index > 0 && index < 12);
            uint fee = (FeeLib.calcFeeL1WithLookup(token, amounts,
                                    stables, HOOK) * WAD) / 10000;

            uint needed = (fee > 0 && fee < WAD / 10) ?
              FullMath.mulDiv(amount, WAD - fee, WAD) : amount;

            // Haircut applies to ALL redeemers during depeg, not just seed
            { Types.DepegStats memory ds = IHook(HOOK).getDepegStats(token);
              if (ds.depegged) { uint retained = FullMath.mulDiv(
                                needed, QUID.getHaircut(), 10000);
                                needed -= retained;
              }
            } if (seed > 0) { _tip(seed, token, -1);
                sent = _withdraw(who, index, needed);
                return sent;
            }
            sent = _withdraw(who, index, needed);
            amount = needed > sent ? needed - sent : 0;
            sent = BasketLib.scaleTokenAmount(sent, token, true);
            amount = BasketLib.scaleTokenAmount(amount, token, true);
        }
        if (amounts[12] == 0 || amount == 0) return sent;
        uint min = amounts[12]; amount = seed == 0 ?
                  Math.min(min, amount) : amount;
                 // amounts[12] excludes untouchable

        uint haircutBps = QUID.getHaircut();
        for (uint i = 1; i <= stables.length; i++) {
            token = stables[i - 1]; if (token == skip) continue;
            amounts[i] = FullMath.mulDiv(amount, FullMath.mulDiv(WAD,
                                       amounts[i], amounts[12]), WAD);

            if (seed > 0) _tip(FullMath.mulDiv(amounts[i],
                                seed, amount), token, -1);
             // Per-token fee: healthy tokens pay high fee during
            // depeg, depegged $ pays BASE: compensates stayers...
            uint feeBps = FeeLib.calcFeeL1(token, i - 1,
                                amounts, stables, HOOK);
            if (feeBps > 0) {
                uint cut = FullMath.mulDiv(
                 amounts[i], feeBps, 10000); amounts[i] -= cut;
            } // Haircut: depegged token priced below par;
            // captures spread → stayers profit on re-peg
            { Types.DepegStats //
                memory ds = IHook(HOOK).getDepegStats(token);
                if (ds.depegged) amounts[i] -= FullMath.mulDiv(
                                 amounts[i], haircutBps, 10000);
            } if (amounts[i] > 0) {
            // 6-dec tokens: USDT(i=1), USDC(2), PYUSD(3), USYC(11)
                uint divisor = (i < 4 || i == 11) ? 1e12 : 1;
                amounts[i] = _withdraw(who, i,
                        amounts[i] / divisor);
                sent += amounts[i] * divisor;
            }
        }
    } // don't check sent == passed in...
    function take(address who, uint amount,
        address token, uint seed) public onlyUs
        returns (uint) { address weth = address(WETH);
        return (token == weth) ? _withdrawAAVE(weth,
        amount, who, address(HUB) != address(0)):
                 _take(who, amount, token, seed);
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
            if (r.wethGain > 0) { _supplyAAVE(address(WETH), r.wethGain,
                               address(this), address(HUB) != address(0));
                                                   vogueETH += r.wethGain;
            }
        } else if (index < 5) { vault = stables[index - 1];
            if (index == 2) { (sent,) = BasketLib.withdrawUSYC(
                               vaults[stables[10]], to, amount);
                amount -= sent;
            } if (amount > 0) sent += _withdrawAAVE(vault, amount,
                                    to, address(HUB) != address(0));
        } else if (index != 11) { vault = vaults[stables[index - 1]];
            (amount,) = BasketLib.calculateVaultWithdrawal(vault, amount);
            if (amount == 0) return 0; // skip if no shares to redeem...
                sent = IERC4626(vault).redeem(
                    amount, to, address(this));
        } else (sent,) = BasketLib.withdrawUSYC(
                vaults[stables[10]], to, amount);
    } // there's never an incentive
    // for EOAs to call this since
    // mint() is the only way to
    // get yield for a deposit...
    // so it's assumed only our
    // contracts will call this...
    function deposit(address from,
        address token, uint amount) public
        returns (uint usd) { address vault;
        if (tokens[token] != address(0)
         && token != address(POOL)) {
            amount = Math.min(
                IERC4626(token).convertToShares(amount),
                IERC4626(token).allowance(from, address(this)));
            usd = IERC4626(token).convertToAssets(amount);
            require(usd > 0 && IERC4626(token).transferFrom(from,
                                         address(this), amount));
            token = tokens[token];
        } else { uint index = toIndex[token];
            require(index > 0 && index < 12);
            usd = Math.min(amount, IERC20(token).allowance(
                                       from, address(this)));
            IERC20(token).transferFrom(from, address(this), usd);
            // ^ no require() for this b/c USDT doesn't return true
            require(usd > 0);
            (usd, amount) = _supply(
                  token, index, usd);
        } uint _target = QUID.target();
        if (untouchable < _target // fee
        && msg.sender == address(QUID)) {
            uint fee = BasketLib.seedFee(usd, untouchable,
                                _target, getAverageYield());
            if (fee > 0) {
                _tip(fee, token, 1);
                if (token == address(USDC) && amount > 0
                && untouchable < _target) _tip(Math.min(
                    FullMath.mulDiv(amount, fee, usd),
                              _target - untouchable),
                    stables[stables.length - 1], 1);
            }
        }
    } function _tip(uint cut, address token, int sign) internal {
        cut = BasketLib.scaleTokenAmount(cut, token, true);
        if (sign > 0) {
            untouchables[token] += cut; untouchable += cut;
        } else {
            cut = Math.min(cut, untouchables[token]);
            untouchables[token] -= cut;
            untouchable -= Math.min(untouchable, cut);
        }
    }
    function _availableETH() internal returns (uint) {
        if (address(SPOKE) == address(0))
            return BasketLib.aaveAvailableV3(
                address(POOL), address(WETH));
        else { uint reserveId = SPOKE.getReserveId(address(HUB),
                                HUB.getAssetId(address(WETH)));
            return SPOKE.getUserSuppliedAssets(
                      reserveId, address(this));
        }
    }

    function _supplyAAVE(address asset, uint amount,
        address to, bool v4) internal returns (uint deposited) {
        if (asset == address(WETH)) _syncETH();
        deposited = BasketLib.supplyAAVE(v4 ? address(SPOKE) : address(POOL),
                                        asset, amount, to, address(HUB));
        if (asset == address(WETH))
            _lastTotalETH = _availableETH();
    }

    function _withdrawAAVE(address asset, uint amount,
        address to, bool v4) internal returns (uint drawn) {
        if (asset == address(WETH)) _syncETH();
        drawn = BasketLib.withdrawAAVE(v4 ? address(SPOKE) : address(POOL),
                                           asset, amount, to, address(HUB));
        if (asset == address(WETH))
            _lastTotalETH = _availableETH();
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
    } /// @param borrower receive tokens & callback
    /// @param token Stable token being borrowed...
    /// @param amount Token amount (native decimals)
    /// @param shareBps LP Profit share signals
    /// higher priority to builders/sequencers
    /// commitment (100 = 1% min, 10000 = 100%)
    /// @param data passed to borrower callback
    function flashLoan(address borrower,
        address token, uint amount, uint shareBps,
        bytes calldata data) external nonReentrant
        returns (bool) { require(msg.sender == JAM);
        uint bal = IERC20(token).balanceOf(address(this));
        uint sent = take(borrower, amount, token, 0);
        bytes32 result = IFlashBorrower(borrower).onFlashLoan(
                        borrower, token, sent, shareBps, data);
        uint repaid = IERC20(token).balanceOf(address(this)) - bal;

        require(result == CALLBACK_SUCCESS &&
            repaid >= (toIndex[token] > 0 &&
                       toIndex[token] < 4 ? sent / 1e12 : sent));
        if (token == address(WETH)) { _supplyAAVE(address(WETH),
            repaid, address(this), address(HUB) != address(0));
            vogueETH += repaid;
        } else _supply(token, toIndex[token], repaid);
        return true; // Block builders don't introspect
    } // they see priority fees, explicit bribes, not
    // internal profit splits. Bebop's orchestrator
    // could score solvers by committed shareBps,
    // routing more flow to generous solvers...
    function _supply(address token, uint index,
        uint usd) internal returns (uint, uint) {
        address vault = vaults[token]; uint amount;
        if (index == 10) // BOLD -> Stability Pool
            (spValue, spPrincipalTime, spLastUpdate) = BasketLib.depositToSP(
                        vault, usd, BasketLib.SPState(spValue, spTotalYield,
                                            spPrincipalTime, spLastUpdate));
        else if (index < 5) { // AAVE: USDT(1), USDC(2), PYUSD(3), GHO(4)
            bool v4 = address(SPOKE) != address(0);
            vault = v4 ? address(SPOKE) : address(POOL);
            if (index == 2) // USDC also deposits to USYC
                (amount, usd) = BasketLib.depositUSYC(vaults[stables[10]],
                                 vault, address(USDC), usd, address(HUB));

            if (usd > 0) _supplyAAVE(token, usd,
                            address(this), v4);
        } // DAI(5), USDS(6), FRAX(7), USDE(8), CRVUSD(9)
        else if (index != 11) // 4626 returns shares...
            usd = IERC4626(vault).convertToAssets(
                    IERC4626(vault).deposit(usd,
                                address(this)));
        return (usd, amount);
    }
}
