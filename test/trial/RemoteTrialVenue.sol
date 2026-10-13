// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IERC20Min {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
}

interface IRemoteStackerMin {
    function credit(address trader, uint256 imdAmount) external returns (uint256 queued);
    function VAULT() external view returns (address);
    function RECEIVER() external view returns (address);
}

/// @title RemoteTrialVenue
/// @notice The positive case for the imd/acc ProjectRegistry trial on Robinhood Chain: the Sepolia
/// trials' TrialVenue, crediting through the RemoteStacker instead of the Stacker. A small
/// constant-product pool between IMD and its own token, TRIAL (this contract), whose liquidity can
/// never be withdrawn by anyone. Every trade pays a 1% fee on its IMD side: 0.5% is the trader's
/// cashback, credited through the RemoteStacker (where it waits for a flush to Ethereum and reaches
/// the trader as staked IMD), and 0.5% is burned (sent to 0x...dEaD). Nothing goes to the owner,
/// who can only seed the pool once.
///
/// The trader is the caller when it is a plain wallet, else the active caller its router reports
/// through `msgSender()`; a caller that resolves to no valid trader gets no cashback, and that
/// cashback is burned instead (never paid to a router). If `credit` fails, the trader is paid the
/// cashback in plain IMD. The gas for `credit` is checked before the call.
contract RemoteTrialVenue {
    string public constant name = "imd/acc trial token";
    string public constant symbol = "TRIAL";
    uint8 public constant decimals = 18;

    uint256 public constant BPS = 10_000;
    uint256 public constant FEE_BPS = 100; // 1% of each trade's IMD side
    uint256 public constant CASHBACK_BPS = 50; // to the trader, as staked IMD
    uint256 public constant BURN_BPS = 50; // burned
    address public constant BURN = 0x000000000000000000000000000000000000dEaD;
    uint256 public constant TRIAL_SUPPLY = 1_000_000e18;

    IERC20Min public immutable IMD;
    IRemoteStackerMin public immutable stacker;
    /// @notice The Ethereum vault and receiver the RemoteStacker names, refused as traders.
    address public immutable VAULT;
    address public immutable RECEIVER;
    /// @notice The only power the owner has: seeding the pool once.
    address public immutable owner;
    /// @notice Gas forwarded to `credit`, and the gas kept for the rest of the trade.
    uint256 public immutable creditGas;
    uint256 public immutable gasReserve;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    uint256 public reserveImd;
    uint256 public reserveTrial;
    bool public seeded;
    uint256 private _lock = 1;

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);
    event Seeded(uint256 imd, uint256 trial);
    event Trade(
        address indexed caller,
        address indexed trader,
        bool buy,
        uint256 imd,
        uint256 trial,
        uint256 cashback,
        uint256 burned
    );

    error NotOwner();
    error AlreadySeeded();
    error NotSeeded();
    error Slippage();
    error ZeroAmount();
    error Reentrant();

    modifier nonReentrant() {
        if (_lock != 1) revert Reentrant();
        _lock = 2;
        _;
        _lock = 1;
    }

    constructor(
        IERC20Min imd,
        IRemoteStackerMin stacker_,
        uint256 creditGas_,
        uint256 gasReserve_
    ) {
        IMD = imd;
        stacker = stacker_;
        VAULT = stacker_.VAULT();
        RECEIVER = stacker_.RECEIVER();
        owner = msg.sender;
        creditGas = creditGas_;
        gasReserve = gasReserve_;
        imd.approve(address(stacker_), type(uint256).max);
        totalSupply = TRIAL_SUPPLY;
        balanceOf[address(this)] = TRIAL_SUPPLY;
        emit Transfer(address(0), address(this), TRIAL_SUPPLY);
    }

    // ------------------------------------------------------------------ pool

    /// @notice Locks `imdAmount` IMD and the whole TRIAL supply into the pool, once. There is no way
    /// to take liquidity out.
    function seed(uint256 imdAmount) external {
        if (msg.sender != owner) revert NotOwner();
        if (seeded) revert AlreadySeeded();
        if (imdAmount == 0) revert ZeroAmount();
        seeded = true;
        require(IMD.transferFrom(msg.sender, address(this), imdAmount));
        reserveImd = imdAmount;
        reserveTrial = TRIAL_SUPPLY;
        emit Seeded(imdAmount, TRIAL_SUPPLY);
    }

    /// @notice Pay `imdIn` IMD for TRIAL. 1% of `imdIn` is the fee: half cashback, half burned.
    function buy(uint256 imdIn, uint256 minTrialOut)
        external
        nonReentrant
        returns (uint256 trialOut)
    {
        if (!seeded) revert NotSeeded();
        if (imdIn == 0) revert ZeroAmount();
        require(IMD.transferFrom(msg.sender, address(this), imdIn));
        uint256 fee = imdIn * FEE_BPS / BPS;
        uint256 net = imdIn - fee;
        trialOut = reserveTrial * net / (reserveImd + net);
        if (trialOut == 0 || trialOut < minTrialOut) revert Slippage();
        reserveImd += net;
        reserveTrial -= trialOut;
        _move(address(this), msg.sender, trialOut);
        _settleFee(imdIn, fee, true, trialOut);
    }

    /// @notice Sell `trialIn` TRIAL for IMD. 1% of the IMD paid out is the fee: half cashback, half
    /// burned.
    function sell(uint256 trialIn, uint256 minImdOut)
        external
        nonReentrant
        returns (uint256 imdOut)
    {
        if (!seeded) revert NotSeeded();
        if (trialIn == 0) revert ZeroAmount();
        _move(msg.sender, address(this), trialIn);
        uint256 gross = reserveImd * trialIn / (reserveTrial + trialIn);
        uint256 fee = gross * FEE_BPS / BPS;
        imdOut = gross - fee;
        if (imdOut == 0 || imdOut < minImdOut) revert Slippage();
        reserveImd -= gross;
        reserveTrial += trialIn;
        require(IMD.transfer(msg.sender, imdOut));
        _settleFee(gross, fee, false, trialIn);
    }

    /// @dev Splits a trade's fee: the cashback to the resolved trader, the rest burned.
    function _settleFee(uint256 imd, uint256 fee, bool isBuy, uint256 trial) internal {
        uint256 cashback = fee * CASHBACK_BPS / FEE_BPS;
        uint256 burned = fee - cashback;
        address trader = resolveTrader(msg.sender);
        if (trader == address(0)) {
            burned += cashback; // no valid trader: the cashback is burned, never paid to a router
            cashback = 0;
        }
        if (burned > 0) require(IMD.transfer(BURN, burned));
        if (cashback > 0) {
            require(gasleft() >= creditGas + gasReserve, "imd/acc: insufficient gas");
            try stacker.credit{gas: creditGas}(trader, cashback) {}
            catch {
                require(IMD.transfer(trader, cashback)); // plain IMD: the trade never reverts
            }
        }
        emit Trade(msg.sender, trader, isBuy, imd, trial, cashback, burned);
    }

    /// @notice The trader of a trade made by `who`: `who` itself when it has no code, else
    /// the active caller its router reports through `msgSender()` (bounded gas, at most 32 bytes
    /// read). Zero when no valid trader can be resolved.
    function resolveTrader(address who) public view returns (address trader) {
        if (who.code.length == 0) {
            trader = who;
        } else {
            bool ok;
            uint256 size;
            uint256 value;
            assembly ("memory-safe") {
                mstore(0, 0xd737d0c700000000000000000000000000000000000000000000000000000000) // msgSender()
                ok := staticcall(30000, who, 0, 4, 0, 32)
                size := returndatasize()
                value := mload(0)
            }
            if (!ok || size != 32 || value > type(uint160).max) return address(0);
            trader = address(uint160(value));
        }
        if (
            trader == address(0) || trader == address(stacker) || trader == address(IMD)
                || trader == VAULT || trader == RECEIVER || trader == address(this)
                || (trader == who && who.code.length != 0)
        ) return address(0);
    }

    // ------------------------------------------------------------------ TRIAL token

    function transfer(address to, uint256 amount) external returns (bool) {
        _move(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        _move(from, to, amount);
        return true;
    }

    function _move(address from, address to, uint256 amount) internal {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }
}
