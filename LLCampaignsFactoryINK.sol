// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ReentrancyGuard for security
abstract contract ReentrancyGuard {
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;
    uint256 private _status;

    constructor() {
        _status = _NOT_ENTERED;
    }

    modifier nonReentrant() {
        require(_status != _ENTERED, "ReentrancyGuard: reentrant call");
        _status = _ENTERED;
        _;
        _status = _NOT_ENTERED;
    }
}

interface INonfungiblePositionManager {
    struct MintParams {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
    }
    function createAndInitializePoolIfNecessary(
        address token0,
        address token1,
        uint24 fee,
        uint160 sqrtPriceX96
    ) external payable returns (address pool);
    function mint(MintParams calldata params)
        external
        payable
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);
    function safeTransferFrom(address from, address to, uint256 tokenId) external;
    function approve(address to, uint256 tokenId) external;
    function ownerOf(uint256 tokenId) external view returns (address);
}

interface IMavrkLocker {
    function lockLP(uint256 tokenId) external;
}

/**
 * @title MavrkTokenStandard
 * @dev Standard ERC-20 token implementation for LaunchLoop campaigns
 * @notice This contract creates tokens with a fixed supply of 1 billion tokens
 */
contract MavrkTokenStandard {
    string public name;
    string public symbol;
    uint8 public decimals;
    uint256 public totalSupply;
    address public owner;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    
    /**
     * @dev Constructor creates a new token with specified name and symbol
     * @param _name The name of the token
     * @param _symbol The symbol of the token
     * @param _deployer The address that will receive the initial token supply
     */
    constructor(string memory _name, string memory _symbol, address _deployer) {
        name = _name;
        symbol = _symbol;
        decimals = 18;
        totalSupply = 1_000_000_000 * (10 ** uint256(decimals));
        owner = address(0x000000000000000000000000000000000000dEaD);
        balanceOf[_deployer] = totalSupply;
        emit Transfer(address(0), _deployer, totalSupply);
    }
    
    /**
     * @dev Approves a spender to spend tokens on behalf of the caller
     * @param spender The address to approve
     * @param amount The amount to approve
     * @return True if successful
     */
    function approve(address spender, uint256 amount) public returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }
    
    /**
     * @dev Transfers tokens from the caller to a recipient
     * @param to The recipient address
     * @param amount The amount to transfer
     * @return True if successful
     */
    function transfer(address to, uint256 amount) public returns (bool) {
        require(balanceOf[msg.sender] >= amount, "Insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }
    
    /**
     * @dev Transfers tokens from one address to another using allowance
     * @param from The address to transfer from
     * @param to The address to transfer to
     * @param amount The amount to transfer
     * @return True if successful
     */
    function transferFrom(address from, address to, uint256 amount) public returns (bool) {
        require(balanceOf[from] >= amount, "Insufficient balance");
        require(allowance[from][msg.sender] >= amount, "Insufficient allowance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        allowance[from][msg.sender] -= amount;
        emit Transfer(from, to, amount);
        return true;
    }
    
    /**
     * @dev Burns tokens from the caller's balance
     * @param amount The amount to burn
     */
    function burn(uint256 amount) public {
        require(balanceOf[msg.sender] >= amount, "Insufficient balance");
        balanceOf[msg.sender] -= amount;
        totalSupply -= amount;
        emit Transfer(msg.sender, address(0), amount);
    }
}

/**
 * @title TokenCampaign
 * @dev Main escrow contract for LaunchLoop campaigns with Anchor Allocation Model
 * @notice This contract manages token presales with dynamic pricing and automatic LP creation
 * 
 * Key Features:
 * - Anchor Allocation Model for fair token distribution
 * - Automatic Uniswap V3 LP creation and locking
 * - Fee structure: 20% platform, 5% creator, 5% referrer (optional)
 * - Reentrancy protection for security
 * - Withdrawal functionality for contributors
 */
contract TokenCampaign is ReentrancyGuard {
    /// @notice The creator of this campaign
    address public immutable creator;
    
    /// @notice The name of the token to be launched
    string public tokenName;
    
    /// @notice The symbol of the token to be launched
    string public tokenSymbol;
    
    /// @notice The address of the deployed token contract
    address public tokenAddress;
    
    /// @notice Whether the token has been launched
    bool public launched;
    
    /// @notice Minimum ETH required to launch the campaign (0.0001 ETH)
    uint256 public constant MIN_LAUNCH_ETH = 0.0001 ether;
    
    /// @notice Uniswap V3 Position Manager address
    address public constant POSITION_MANAGER = 0xC0836E5B058BBE22ae2266e1AC488A1A0fD8DCE8;
    
    /// @notice Wrapped ETH address
    address public constant WETH = 0x4200000000000000000000000000000000000006;
    
    /// @notice Uniswap V3 fee tier (0.1%)
    uint24 public constant FEE_TIER = 10000;
    
    /// @notice Platform fees wallet address
    address public constant PLATFORM_FEES = 0x817bB5c53BC2cD0A04CD3EAcE02aFC40d7c012Bf;
    
    /// @notice LP locker contract address for permanent locking
    address public constant LOCKER = 0x49fADA7072DB4BACbCAB48D38FeF6aa6ECB6595c;
    
    /// @notice Mapping of user addresses to their LP deposit amounts
    mapping(address => uint256) public lpDeposits;
    
    /// @notice Array of all contributors
    address[] public contributors;
    
    /// @notice Mapping to track if a user has contributed
    mapping(address => bool) public hasContributed;
    
    /// @notice Mapping to track if a user has claimed their tokens
    mapping(address => bool) public hasClaimed;
    
    // Anchor Allocation Model variables
    /// @notice Mapping of user addresses to their total ETH contributions
    mapping(address => uint256) public contributions;
    
    /// @notice The largest single contribution (anchor contribution)
    uint256 public anchorContribution = 0.0005 ether;
    
    /// @notice Maximum tokens per wallet (5% of total supply)
    uint256 public constant ANCHOR_TOKENS = 50_000_000 * 1e18;
    
    /// @notice Total presale allocation (80% of total supply)
    uint256 public constant PRESALE_ALLOCATION = 800_000_000 * 1e18;
    
    /// @notice Whether unallocated tokens have been burned
    bool public burned;

    // Events
    /// @notice Emitted when a user deposits ETH
    event Deposited(address indexed contributor, uint256 amount, address indexed referrer);
    
    /// @notice Emitted when a user withdraws their LP deposit
    event Withdrawn(address indexed user, uint256 amount);
    
    /// @notice Emitted when the token is launched
    event TokenLaunched(address tokenAddress, uint256 lpTokenId);
    
    /// @notice Emitted when a user claims their tokens
    event Claimed(address indexed user, uint256 amount);
    
    /// @notice Emitted when unallocated tokens are burned
    event Burned(uint256 amount);
    
    /// @notice Emitted when platform tokens are allocated
    event PlatformAllocated(address indexed platform, uint256 amount);
    
    /// @notice Emitted when market buy tokens are allocated
    event MarketBuyAllocated(address indexed platform, uint256 ethAmount, uint256 tokenAmount);
    
    /// @notice Emitted when LP NFT is locked
    event NFTLocked(uint256 indexed tokenId);

    /**
     * @dev Constructor creates a new escrow campaign
     * @param _creator The address of the campaign creator
     * @param _name The name of the token to be launched
     * @param _symbol The symbol of the token to be launched
     */
    constructor(address _creator, string memory _name, string memory _symbol) {
        creator = _creator;
        tokenName = _name;
        tokenSymbol = _symbol;
    }

    /**
     * @dev Fallback function - reverts to prevent accidental ETH sends
     */
    receive() external payable {
        revert("Use deposit() instead");
    }

    /**
     * @dev Allows users to deposit ETH into the campaign
     * @notice Users can deposit ETH to participate in the presale. Multiple deposits from the same address are cumulative.
     * 
     * Fee Structure (deducted from each deposit):
     * - 20% to platform fees wallet
     * - 5% to campaign creator
     * - 5% to referrer (if provided, otherwise goes to platform)
     * - 70% goes to LP for token launch
     * 
     * Anchor Allocation Model Integration:
     * - Each deposit adds to the user's cumulative contribution total
     * - If a user's cumulative total becomes the largest single contribution, it becomes the new anchor
     * - This allows users to gradually build their position and potentially become the anchor contributor
     * - Token allocation at claim time is based on cumulative contribution relative to the anchor
     * 
     * Multiple Deposit Example:
     * - User deposits 0.0001 ETH → Total: 0.0001 ETH
     * - User deposits 0.0002 ETH → Total: 0.0003 ETH
     * - User deposits 0.0003 ETH → Total: 0.0006 ETH (becomes new anchor if largest)
     * - User claims tokens based on 0.0006 ETH total contribution
     * 
     * @param referrer The referrer address in bytes32 format (optional)
     * 
     * Fee Structure Details:
     * - With referrer: 20% platform + 5% creator + 5% referrer = 70% to LP
     * - Without referrer: 25% platform + 5% creator = 70% to LP
     */
    function deposit(bytes32 referrer) external payable nonReentrant {
        require(!launched, "Presale ended"); // Block deposits after launch
        require(msg.value > 0, "Must send ETH");
        
        uint256 amount = msg.value;
        uint256 platformFee = (amount * 20) / 100;
        uint256 creatorFee = (amount * 5) / 100;
        uint256 referrerFee = (amount * 5) / 100;
        address refAddr = address(uint160(uint256(referrer)));
        uint256 userDeposit;
        
        if (refAddr != address(0)) {
            // 20% platform, 5% creator, 5% referrer
            userDeposit = amount - platformFee - creatorFee - referrerFee;
            payable(PLATFORM_FEES).transfer(platformFee);
            payable(creator).transfer(creatorFee);
            payable(refAddr).transfer(referrerFee);
        } else {
            // 25% platform, 5% creator
            userDeposit = amount - (platformFee + referrerFee) - creatorFee;
            payable(PLATFORM_FEES).transfer(platformFee + referrerFee);
            payable(creator).transfer(creatorFee);
        }
        
        lpDeposits[msg.sender] += userDeposit;
        
        // Anchor Allocation Model: track total ETH contributed
        if (contributions[msg.sender] == 0) {
            contributors.push(msg.sender);
        }
        contributions[msg.sender] += msg.value;
        
        // Update anchor contribution if this is the largest so far
        if (contributions[msg.sender] > anchorContribution) {
            anchorContribution = contributions[msg.sender];
        }
        
        if (!hasContributed[msg.sender]) {
            hasContributed[msg.sender] = true;
        }
        
        emit Deposited(msg.sender, userDeposit, refAddr);
    }

    /**
     * @dev Allows users to withdraw their LP deposit before launch
     * @notice Users can only withdraw the LP portion (70% of their deposit after fees)
     * Withdrawals are disabled after the token is launched
     */
    function withdraw() external nonReentrant {
        require(!launched, "Withdrawals disabled after launch");
        uint256 amount = lpDeposits[msg.sender];
        require(amount > 0, "No withdrawable balance");
        
        lpDeposits[msg.sender] = 0;
        payable(msg.sender).transfer(amount);
        emit Withdrawn(msg.sender, amount);
    }

    /**
     * @dev Returns the total ETH balance in the contract
     * @return The total ETH balance
     */
    function getTotalLPBalance() public view returns (uint256) {
        return address(this).balance;
    }

    /**
     * @dev Returns the array of all contributors
     * @return Array of contributor addresses
     */
    function getContributors() public view returns (address[] memory) {
        return contributors;
    }

    /**
     * @dev Checks if a user has contributed to the campaign
     * @param user The address to check
     * @return True if the user has contributed
     */
    function hasUserContributed(address user) public view returns (bool) {
        return lpDeposits[user] > 0;
    }

    /**
     * @dev Launches the token and creates the liquidity pool
     * @notice This function can only be called by the campaign creator
     * 
     * The launch process:
     * 1. Creates the ERC-20 token
     * 2. Allocates 2.5% of supply to platform fees wallet
     * 3. Creates Uniswap V3 LP position with 20% of supply
     * 4. Performs market buy with remaining ETH
     * 5. Burns unallocated tokens based on Anchor Allocation Model
     * 6. Permanently locks the LP NFT
     */
    function launchToken() external nonReentrant {
        require(msg.sender == creator, "Only creator can launch");
        require(!launched, "Already launched");
        require(address(this).balance >= MIN_LAUNCH_ETH, "Not enough ETH to launch (0.0001 ETH)");
        
        MavrkTokenStandard token = new MavrkTokenStandard(tokenName, tokenSymbol, address(this));
        tokenAddress = address(token);
        launched = true;
        
        // --- Platform Allocation: Send 2.5% to platform fees wallet at TGE ---
        uint256 platformTokens = (token.totalSupply() * 25) / 1000; // 2.5% = 25,000,000 tokens
        require(token.transfer(PLATFORM_FEES, platformTokens), "Platform transfer failed");
        emit PlatformAllocated(PLATFORM_FEES, platformTokens);
        
        uint256 lpTokens = (token.totalSupply() * 20) / 100;
        uint256 claimableTokens = token.totalSupply() - lpTokens - platformTokens;
        require(token.approve(POSITION_MANAGER, lpTokens), "Token approve failed");
        
        // LP Creation with optimized variable usage
        address token0 = tokenAddress < WETH ? tokenAddress : WETH;
        address token1 = tokenAddress < WETH ? WETH : tokenAddress;
        
        INonfungiblePositionManager npm = INonfungiblePositionManager(POSITION_MANAGER);
        uint256 tokenId;
        
        if (token0 == tokenAddress) {
            npm.createAndInitializePoolIfNecessary(token0, token1, FEE_TIER, 3543049682531703600807385);
            (tokenId,, ,) = npm.mint{value: 0}(INonfungiblePositionManager.MintParams({
                token0: token0,
                token1: token1,
                fee: FEE_TIER,
                tickLower: -200200,
                tickUpper: 0,
                amount0Desired: 199_999_999_999_999_999_999_996_407,
                amount1Desired: 0,
                amount0Min: 199_999_999_999_999_999_999_996_407,
                amount1Min: 0,
                recipient: address(this),
                deadline: block.timestamp + 600
            }));
            emit TokenLaunched(tokenAddress, tokenId);
        } else {
            npm.createAndInitializePoolIfNecessary(token0, token1, FEE_TIER, 1771577727172025373304338615273325);
            (tokenId,, ,) = npm.mint{value: 0}(INonfungiblePositionManager.MintParams({
                token0: token0,
                token1: token1,
                fee: FEE_TIER,
                tickLower: 0,
                tickUpper: 200200,
                amount0Desired: 0,
                amount1Desired: 199_999_999_999_999_999_999_996_452,
                amount0Min: 0,
                amount1Min: 199_999_999_999_999_999_999_996_452,
                recipient: address(this),
                deadline: block.timestamp + 600
            }));
            emit TokenLaunched(tokenAddress, tokenId);
        }

        // --- Market buy with escrowed ETH ---
        uint256 ethBalance = address(this).balance;
        require(ethBalance > 0, "No ETH to wrap");
        IWETH weth = IWETH(WETH);
        weth.deposit{value: ethBalance}();

        address SWAP_ROUTER = 0x177778F19E89dD1012BdBe603F144088A95C4B53;
        require(weth.approve(SWAP_ROUTER, ethBalance), "WETH approve failed");

        ISwapRouter02 swapRouter = ISwapRouter02(SWAP_ROUTER);
        uint256 tokensReceived = swapRouter.exactInputSingle(ISwapRouter02.ExactInputSingleParams({
            tokenIn: WETH,
            tokenOut: tokenAddress,
            fee: FEE_TIER,
            recipient: PLATFORM_FEES,
            amountIn: ethBalance,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        }));
        emit MarketBuyAllocated(PLATFORM_FEES, ethBalance, tokensReceived);

        // --- Anchor Allocation Model: Burn unallocated tokens at launch ---
        uint256 totalClaimable = 0;
        for (uint256 i = 0; i < contributors.length; i++) {
            address user = contributors[i];
            uint256 contribution = contributions[user];
            uint256 owed = (contribution * ANCHOR_TOKENS) / anchorContribution;
            if (owed > ANCHOR_TOKENS) {
                owed = ANCHOR_TOKENS;
            }
            totalClaimable += owed;
        }
        
        uint256 toBurn = claimableTokens - totalClaimable;
        burned = true;
        MavrkTokenStandard(tokenAddress).burn(toBurn);
        emit Burned(toBurn);

        // --- LP NFT Locking: Permanently lock the LP position ---
        require(npm.ownerOf(tokenId) == address(this), "Contract does not own LP NFT");
        npm.approve(LOCKER, tokenId);
        IMavrkLocker(LOCKER).lockLP(tokenId);
        emit NFTLocked(tokenId);
    }

    /**
     * @dev Allows users to claim their allocated tokens after launch
     * @notice Uses the Anchor Allocation Model to calculate token distribution based on cumulative contributions
     * 
     * Anchor Allocation Model:
     * - Token price is dynamically set based on the largest cumulative contribution from any single address
     * - Maximum allocation per wallet is 5% of total supply (50,000,000 tokens)
     * - Users receive tokens proportional to their cumulative contribution relative to the anchor
     * - Formula: (cumulative_contribution * 50,000,000) / anchor_contribution
     * 
     * Cumulative Contribution Handling:
     * - The function uses the total cumulative ETH contributed by the user across all their deposits
     * - Multiple deposits from the same address are summed together for token calculation
     * - This allows users to DCA (Dollar Cost Average) into the campaign while maintaining fair allocation
     * 
     * Example:
     * - User made 3 deposits: 0.0001 ETH + 0.0002 ETH + 0.0003 ETH = 0.0006 ETH total
     * - If anchor contribution is 0.0006 ETH, user gets 50,000,000 tokens (5% cap)
     * - If anchor contribution is 0.001 ETH, user gets 30,000,000 tokens (0.0006/0.001 * 50,000,000)
     */
    function claim() external nonReentrant {
        require(launched, "Not launched yet");
        require(!hasClaimed[msg.sender], "Already claimed");
        uint256 contribution = contributions[msg.sender];
        require(contribution > 0, "No contribution");
        
        MavrkTokenStandard token = MavrkTokenStandard(tokenAddress);
        
        // Anchor Allocation Model: dynamic allocation
        uint256 owed = (contribution * ANCHOR_TOKENS) / anchorContribution;
        if (owed > ANCHOR_TOKENS) {
            owed = ANCHOR_TOKENS;
        }
        
        hasClaimed[msg.sender] = true;
        require(token.transfer(msg.sender, owed), "Token transfer failed");
        emit Claimed(msg.sender, owed);
    }
}

/**
 * @title CampaignFactory
 * @dev Factory contract for deploying new escrow campaigns
 * @notice This contract allows anyone to create new LaunchLoop campaigns
 */
contract CampaignFactory {
    /// @notice The creator of the factory contract
    address public immutable factoryCreator;
    
    /// @notice Array of all deployed campaign addresses
    address[] public deployedCampaigns;
    
    /// @notice Emitted when a new campaign is deployed
    event NewCampaignDeployed(address indexed creator, address indexed campaign, string name, string symbol);

    /**
     * @dev Constructor sets the factory creator
     */
    constructor() {
        factoryCreator = msg.sender;
    }

    /**
     * @dev Creates a new escrow campaign
     * @param _name The name of the token to be launched
     * @param _symbol The symbol of the token to be launched
     * @return newCampaignAddress The address of the deployed campaign contract
     */
    function newCampaign(string memory _name, string memory _symbol)
        external
        returns (address newCampaignAddress)
    {
        TokenCampaign newCampaign = new TokenCampaign(msg.sender, _name, _symbol);
        deployedCampaigns.push(address(newCampaign));
        emit NewCampaignDeployed(msg.sender, address(newCampaign), _name, _symbol);
        return address(newCampaign);
    }

    /**
     * @dev Returns all deployed campaign addresses
     * @return Array of deployed campaign addresses
     */
    function getDeployedCampaigns() external view returns (address[] memory) {
        return deployedCampaigns;
    }
}

/**
 * @title IWETH
 * @dev Interface for Wrapped ETH (WETH) contract
 */
interface IWETH {
    function deposit() external payable;
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/**
 * @title ISwapRouter02
 * @dev Interface for Uniswap V3 SwapRouter02
 */
interface ISwapRouter02 {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }
    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
} 