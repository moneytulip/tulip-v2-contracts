// SPDX-License-Identifier: MIT
pragma solidity ^0.8.7;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

interface IOracle {
    function update() external;
    function consult(address _token, uint256 _amountIn) external view returns (uint144 amountOut);
    function twap(address _token, uint256 _amountIn) external view returns (uint144 _amountOut);
}

interface ITreasury {
    function epoch() external view returns (uint256);
}

interface IUniswapV2Pair {
    event Approval(address indexed owner, address indexed spender, uint value);
    event Transfer(address indexed from, address indexed to, uint value);

    function name() external pure returns (string memory);
    function symbol() external pure returns (string memory);
    function decimals() external pure returns (uint8);
    function totalSupply() external view returns (uint);
    function balanceOf(address owner) external view returns (uint);
    function allowance(address owner, address spender) external view returns (uint);

    function approve(address spender, uint value) external returns (bool);
    function transfer(address to, uint value) external returns (bool);
    function transferFrom(address from, address to, uint value) external returns (bool);

    function DOMAIN_SEPARATOR() external view returns (bytes32);
    function PERMIT_TYPEHASH() external pure returns (bytes32);
    function nonces(address owner) external view returns (uint);

    function permit(address owner, address spender, uint value, uint deadline, uint8 v, bytes32 r, bytes32 s) external;

    event Mint(address indexed sender, uint amount0, uint amount1);
    event Burn(address indexed sender, uint amount0, uint amount1, address indexed to);
    event Swap(
        address indexed sender,
        uint amount0In,
        uint amount1In,
        uint amount0Out,
        uint amount1Out,
        address indexed to
    );
    event Sync(uint112 reserve0, uint112 reserve1);

    function MINIMUM_LIQUIDITY() external pure returns (uint);
    function factory() external view returns (address);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function price0CumulativeLast() external view returns (uint);
    function price1CumulativeLast() external view returns (uint);
    function kLast() external view returns (uint);

    function mint(address to) external returns (uint liquidity);
    function burn(address to) external returns (uint amount0, uint amount1);
    function swap(uint amount0Out, uint amount1Out, address to, bytes calldata data) external;
    function skim(address to) external;
    function sync() external;

    function initialize(address, address) external;
}

contract RebateTreasury is Ownable {

    struct Asset {
        bool isAdded;
        uint256 multiplier;
        address oracle;
        bool isLP;
        address pair;
    }

    struct VestingSchedule {
        uint256 amount;
        uint256 period;
        uint256 end;
        uint256 claimed;
        uint256 lastClaimed;
    }

    IERC20 public Tulip;
    IOracle public TulipOracle;
    ITreasury public Treasury;

    mapping (address => Asset) public assets;
    mapping (address => VestingSchedule) public vesting;

    uint256 public bondThreshold = 20 * 1e4;
    uint256 public bondFactor = 80 * 1e4;
    uint256 public secondaryThreshold = 70 * 1e4;
    uint256 public secondaryFactor = 15 * 1e4;

    uint256 public bondVesting = 3 days;
    uint256 public totalVested = 0;

    uint256 public lastBuyback;
    uint256 public buybackAmount = 10 * 1e4;

    address public constant WROSE = 0x21C718C22D52d0F3a789b752D4c2fD5908a8A733;
    uint256 public constant DENOMINATOR = 1e6;

    /*
     * ---------
     * MODIFIERS
     * ---------
     */
    
    // Only allow a function to be called with a bondable asset

    modifier onlyAsset(address token) {
        require(assets[token].isAdded, "RebateTreasury: token is not a bondable asset");
        _;
    }

    /*
     * ------------------
     * EXTERNAL FUNCTIONS
     * ------------------
     */

    // Initialize parameters

    constructor(address tulip, address tulipOracle, address treasury) {
        Tulip = IERC20(tulip);
        TulipOracle = IOracle(tulipOracle);
        Treasury = ITreasury(treasury);
    }
    
    // Bond asset for discounted Tulip at bond rate

    function bond(address token, uint256 amount) external onlyAsset(token) {
        require(amount > 0, "RebateTreasury: invalid bond amount");
        uint256 tulipAmount = getTulipReturn(token, amount);
        require(tulipAmount <= Tulip.balanceOf(address(this)) - totalVested, "RebateTreasury: insufficient tulip balance");

        IERC20(token).transferFrom(msg.sender, address(this), amount);
        _claimVested(msg.sender);

        VestingSchedule storage schedule = vesting[msg.sender];
        schedule.amount = schedule.amount - schedule.claimed + tulipAmount;
        schedule.period = bondVesting;
        schedule.end = block.timestamp + bondVesting;
        schedule.claimed = 0;
        schedule.lastClaimed = block.timestamp;
        totalVested += tulipAmount;
    }

    // Claim available Tulip rewards from bonding

    function claimRewards() external {
        _claimVested(msg.sender);
    }

    /*
     * --------------------
     * RESTRICTED FUNCTIONS
     * --------------------
     */
    
    // Set Tulip token

    function setTulip(address tulip) external onlyOwner {
        Tulip = IERC20(tulip);
    }

    // Set Tulip oracle

    function setTulipOracle(address oracle) external onlyOwner {
        TulipOracle = IOracle(oracle);
    }

    // Set Tulip treasury

    function setTreasury(address treasury) external onlyOwner {
        Treasury = ITreasury(treasury);
    }
    
    // Set bonding parameters of token
    
    function setAsset(
        address token,
        bool isAdded,
        uint256 multiplier,
        address oracle,
        bool isLP,
        address pair
    ) external onlyOwner {
        assets[token].isAdded = isAdded;
        assets[token].multiplier = multiplier;
        assets[token].oracle = oracle;
        assets[token].isLP = isLP;
        assets[token].pair = pair;
    }

    // Set bond pricing parameters

    function setBondParameters(
        uint256 primaryThreshold,
        uint256 primaryFactor,
        uint256 secondThreshold,
        uint256 secondFactor,
        uint256 vestingPeriod
    ) external onlyOwner {
        bondThreshold = primaryThreshold;
        bondFactor = primaryFactor;
        secondaryThreshold = secondThreshold;
        secondaryFactor = secondFactor;
        bondVesting = vestingPeriod;
    }

    // Redeem assets for buyback under peg

    function redeemAssetsForBuyback(address[] calldata tokens) external onlyOwner {
        require(getTulipPrice() < 1e18, "RebateTreasury: unable to buy back");
        uint256 epoch = Treasury.epoch();
        require(lastBuyback != epoch, "RebateTreasury: already bought back");
        lastBuyback = epoch;

        for (uint256 t = 0; t < tokens.length; t ++) {
            require(assets[tokens[t]].isAdded, "RebateTreasury: invalid token");
            IERC20 Token = IERC20(tokens[t]);
            Token.transfer(owner(), Token.balanceOf(address(this)) * buybackAmount / DENOMINATOR);
        }
    }

    /*
     * ------------------
     * INTERNAL FUNCTIONS
     * ------------------
     */

    function _claimVested(address account) internal {
        VestingSchedule storage schedule = vesting[account];
        if (schedule.amount == 0 || schedule.amount == schedule.claimed) return;
        if (block.timestamp <= schedule.lastClaimed || schedule.lastClaimed >= schedule.end) return;

        uint256 duration = (block.timestamp > schedule.end ? schedule.end : block.timestamp) - schedule.lastClaimed;
        uint256 claimable = schedule.amount * duration / schedule.period;
        if (claimable == 0) return;

        schedule.claimed += claimable;
        schedule.lastClaimed = block.timestamp > schedule.end ? schedule.end : block.timestamp;
        totalVested -= claimable;
        Tulip.transfer(account, claimable);
    }

    /*
     * --------------
     * VIEW FUNCTIONS
     * --------------
     */

    // Calculate Tulip return of bonding amount of token

    function getTulipReturn(address token, uint256 amount) public view onlyAsset(token) returns (uint256) {
        uint256 tulipPrice = getTulipPrice();
        uint256 tokenPrice = getTokenPrice(token);
        uint256 bondPremium = getBondPremium();
        return amount * tokenPrice * (bondPremium + DENOMINATOR) * assets[token].multiplier / (DENOMINATOR * DENOMINATOR) / tulipPrice;
    }

    // Calculate premium for bonds based on bonding curve

    function getBondPremium() public view returns (uint256) {
        uint256 tulipPrice = getTulipPrice();
        if (tulipPrice < 1e18) return 0;

        uint256 tulipPremium = tulipPrice * DENOMINATOR / 1e18 - DENOMINATOR;
        if (tulipPremium < bondThreshold) return 0;
        if (tulipPremium <= secondaryThreshold) {
            return (tulipPremium - bondThreshold) * bondFactor / DENOMINATOR;
        } else {
            uint256 primaryPremium = (secondaryThreshold - bondThreshold) * bondFactor / DENOMINATOR;
            return primaryPremium + (tulipPremium - secondaryThreshold) * secondaryFactor / DENOMINATOR;
        }
    }

    // Get TOMB price from Oracle

    function getTulipPrice() public view returns (uint256) {
        return TulipOracle.consult(address(Tulip), 1e18);
    }

    // Get token price from Oracle

    function getTokenPrice(address token) public view onlyAsset(token) returns (uint256) {
        Asset memory asset = assets[token];
        IOracle Oracle = IOracle(asset.oracle);
        if (!asset.isLP) {
            return Oracle.consult(token, 1e18);
        }

        IUniswapV2Pair Pair = IUniswapV2Pair(asset.pair);
        uint256 totalPairSupply = Pair.totalSupply();
        address token0 = Pair.token0();
        address token1 = Pair.token1();
        (uint256 reserve0, uint256 reserve1,) = Pair.getReserves();

        if (token1 == WROSE) {
            uint256 tokenPrice = Oracle.consult(token0, 1e18);
            return tokenPrice * reserve0 / totalPairSupply +
                   reserve1 * 1e18 / totalPairSupply;
        } else {
            uint256 tokenPrice = Oracle.consult(token1, 1e18);
            return tokenPrice * reserve1 / totalPairSupply +
                   reserve0 * 1e18 / totalPairSupply;
        }
    }

    // Get claimable vested Tulip for account

    function claimableTulip(address account) external view returns (uint256) {
        VestingSchedule memory schedule = vesting[account];
        if (block.timestamp <= schedule.lastClaimed || schedule.lastClaimed >= schedule.end) return 0;
        uint256 duration = (block.timestamp > schedule.end ? schedule.end : block.timestamp) - schedule.lastClaimed;
        return schedule.amount * duration / schedule.period;
    }

}
