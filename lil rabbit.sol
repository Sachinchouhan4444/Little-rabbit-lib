// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

// Interfaces
interface IUniswapV2Factory {
    function createPair(address tokenA, address tokenB) external returns (address pair);
}

interface IUniswapV2Router02 {
    function factory() external pure returns (address);
    function WETH() external pure returns (address);
    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external;
    function addLiquidityETH(
        address token,
        uint amountTokenDesired,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external payable returns (uint amountToken, uint amountETH, uint liquidity);
}

interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address recipient, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
}

interface IERC20Metadata is IERC20 {
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
}

// Contracts
abstract contract Context {
    function _msgSender() internal view virtual returns (address) {
        return msg.sender;
    }
    
    function _msgData() internal view virtual returns (bytes calldata) {
        return msg.data;
    }
}

contract Ownable is Context {
    address private _owner;
    
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    
    constructor() {
        address msgSender = _msgSender();
        _owner = msgSender;
        emit OwnershipTransferred(address(0), msgSender);
    }
    
    function owner() public view returns (address) {
        return _owner;
    }
    
    modifier onlyOwner() {
        require(_owner == _msgSender(), "Ownable: caller is not the owner");
        _;
    }
    
    function renounceOwnership() public virtual onlyOwner {
        emit OwnershipTransferred(_owner, address(0));
        _owner = address(0);
    }

    function transferOwnership(address newOwner) public virtual onlyOwner {
        require(newOwner != address(0), "Ownable: new owner is the zero address");
        emit OwnershipTransferred(_owner, newOwner);
        _owner = newOwner;
    }
    
    function getTime() public view returns (uint256) {
        return block.timestamp;
    }
}

// Main Contract
contract LittleRabbitToken is Context, IERC20, IERC20Metadata, Ownable {
    // Custom interfaces
    IUniswapV2Router02 public uniswapV2Router;
    
    // Strings
    string private _name = "Little Rabbit";
    string private _symbol = "LTRBT";
    
    // Booleans
    bool public moveBnbToWallets = true;
    bool public swapAndLiquifyEnabled = true;
    bool public marketActive = false;
    bool public limitActive = true;
    bool public buyTimeLimit = true;
    bool private isInternalTransaction = false;
    
    // Addresses
    address public uniswapV2Pair;
    address public marketingWallet;
    address public developmentWallet;
    address public nftTreasuryWallet;
    address public buybackWallet;
    address[] private _excluded;
    
    // Uints
    uint public buyReflectionFee = 1;
    uint public sellReflectionFee = 1;
    uint public buyMarketingFee = 3;
    uint public sellMarketingFee = 3;
    uint public buyDevelopmentFee = 1;
    uint public sellDevelopmentFee = 1;
    uint public buyNftTreasuryFee = 1;
    uint public sellNftTreasuryFee = 1;
    uint public buyBuybackFee = 1;
    uint public sellBuybackFee = 2;
    
    uint public buyFee;
    uint public sellFee;
    
    uint public buySecondsLimit = 5;
    uint public maxBuyTx;
    uint public maxSellTx;
    uint public maxWallet;
    uint public intervalSecondsForSwap = 4;
    uint public minimumWeiForTokenomics = 1 * 10**14; // 0.0001 BNB
    
    uint private startTimeForSwap;
    uint private marketActiveAt;
    
    uint8 private constant _decimals = 9;
    uint private constant MAX = ~uint256(0);
    uint private _tTotal = 10_000_000_000_000_000_000_000_000 * 10 ** _decimals;
    uint private _rTotal = (MAX - (MAX % _tTotal));
    uint private _tFeeTotal;
    
    uint private _reflectionFee;
    uint private _marketingFee;
    uint private _developmentFee;
    uint private _nftTreasuryFee;
    uint private _buybackFee;
    
    uint private _oldReflectionFee;
    uint private _oldMarketingFee;
    uint private _oldDevelopmentFee;
    uint private _oldNftTreasuryFee;
    uint private _oldBuybackFee;
    
    // Mappings
    mapping (address => uint256) private _rOwned;
    mapping (address => uint256) private _tOwned;
    mapping (address => mapping (address => uint256)) private _allowances;
    mapping (address => bool) public premarketUser;
    mapping (address => bool) public excludedFromFees;
    mapping (address => bool) private _isExcluded;
    mapping (address => bool) public automatedMarketMakerPairs;
    mapping (address => uint) public userLastBuy;
    
    // Events
    event MarketingCollected(uint256 amount);
    event DevelopmentCollected(uint256 amount);
    event NftTreasuryCollected(uint256 amount);
    event BuyBackCollected(uint256 amount);
    event ExcludedFromFees(address indexed user, bool state);
    event SwapSystemChanged(bool status, uint256 intervalSecondsToWait);
    event MoveBnbToWallets(bool state);
    event LimitChanged(uint maxSell, uint maxBuy, uint maxWallet);
    
    // Constructor
    constructor(address initialOwner) {
        // Set the deployer as the owner
        transferOwnership(initialOwner);
        
        // Set wallet addresses to the owner
        marketingWallet = initialOwner;
        developmentWallet = initialOwner;
        nftTreasuryWallet = initialOwner;
        buybackWallet = initialOwner;
        
        // Set up Uniswap V2 Router
        IUniswapV2Router02 _uniswapV2Router = IUniswapV2Router02(0x10ED43C718714eb63d5aA57B78B54704E256024E);
        uniswapV2Router = _uniswapV2Router;
        
        // Create Uniswap pair
        uniswapV2Pair = IUniswapV2Factory(_uniswapV2Router.factory())
            .createPair(address(this), _uniswapV2Router.WETH());
        
        // Initialize mappings
        automatedMarketMakerPairs[uniswapV2Pair] = true;
        excludedFromFees[address(this)] = true;
        excludedFromFees[owner()] = true;
        premarketUser[owner()] = true;
        excludedFromFees[marketingWallet] = true;
        excludedFromFees[nftTreasuryWallet] = true;
        excludedFromFees[buybackWallet] = true;

        // Set initial balances
        _rOwned[owner()] = _rTotal;
        
        // Set limits
        maxBuyTx = _tTotal / 100; // 1%
        maxSellTx = _tTotal / 200; // 0.5%
        maxWallet = _tTotal * 2 / 100; // 2%
        
        // Calculate fees
        setFees();
        
        emit Transfer(address(0), owner(), _tTotal);
    }
    
    // Receive function to accept BNB
    receive() external payable {}
    
    // ERC20 functions
    function name() public view override returns (string memory) {
        return _name;
    }
    
    function symbol() public view override returns (string memory) {
        return _symbol;
    }
    
    function decimals() public pure override returns (uint8) {
        return _decimals;
    }
    
    function totalSupply() public view override returns (uint256) {
        return _tTotal;
    }
    
    function balanceOf(address account) public view override returns (uint256) {
        if (_isExcluded[account]) return _tOwned[account];
        return tokenFromReflection(_rOwned[account]);
    }
    
    function transfer(address recipient, uint256 amount) public override returns (bool) {
        _transfer(_msgSender(), recipient, amount);
        return true;
    }
    
    function allowance(address owner, address spender) public view override returns (uint256) {
        return _allowances[owner][spender];
    }
    
    function approve(address spender, uint256 amount) public override returns (bool) {
        _approve(_msgSender(), spender, amount);
        return true;
    }
    
    function transferFrom(address sender, address recipient, uint256 amount) public override returns (bool) {
        _transfer(sender, recipient, amount);
        
        uint256 currentAllowance = _allowances[sender][_msgSender()];
        require(currentAllowance >= amount, "ERC20: transfer amount exceeds allowance");
        _approve(sender, _msgSender(), currentAllowance - amount);
        
        return true;
    }
    
    function increaseAllowance(address spender, uint256 addedValue) public virtual returns (bool) {
        _approve(_msgSender(), spender, _allowances[_msgSender()][spender] + addedValue);
        return true;
    }
    
    function decreaseAllowance(address spender, uint256 subtractedValue) public virtual returns (bool) {
        uint256 currentAllowance = _allowances[_msgSender()][spender];
        require(currentAllowance >= subtractedValue, "ERC20: decreased allowance below zero");
        _approve(_msgSender(), spender, currentAllowance - subtractedValue);
        return true;
    }
    
    // Reflection functions
    function isExcludedFromReward(address account) public view returns (bool) {
        return _isExcluded[account];
    }
    
    function totalFees() public view returns (uint256) {
        return _tFeeTotal;
    }
    
    function reflectionFromToken(uint256 tAmount, bool deductTransferFee) public view returns (uint256) {
        require(tAmount <= _tTotal, "Amount must be less than supply");
        if (!deductTransferFee) {
            (uint256 rAmount,,,,,,,,) = _getValues(tAmount);
            return rAmount;
        } else {
            (,uint256 rTransferAmount,,,,,,,) = _getValues(tAmount);
            return rTransferAmount;
        }
    }
    
    function tokenFromReflection(uint256 rAmount) public view returns (uint256) {
        require(rAmount <= _rTotal, "Amount must be less than total reflections");
        uint256 currentRate = _getRate();
        return rAmount / currentRate;
    }
    
    // Fee management
    function setFees() private {
        buyFee = buyReflectionFee + buyMarketingFee + buyDevelopmentFee + buyNftTreasuryFee + buyBuybackFee;
        sellFee = sellReflectionFee + sellMarketingFee + sellDevelopmentFee + sellNftTreasuryFee + sellBuybackFee;
    }
    
    function excludeFromReward(address account) external onlyOwner {
        require(!_isExcluded[account], "Account is already excluded");
        
        if (_rOwned[account] > 0) {
            _tOwned[account] = tokenFromReflection(_rOwned[account]);
        }
        
        _isExcluded[account] = true;
        _excluded.push(account);
    }
    
    function includeInReward(address account) external onlyOwner {
        require(_isExcluded[account], "Account is already included");
        
        for (uint256 i = 0; i < _excluded.length; i++) {
            if (_excluded[i] == account) {
                _excluded[i] = _excluded[_excluded.length - 1];
                _tOwned[account] = 0;
                _isExcluded[account] = false;
                _excluded.pop();
                break;
            }
        }
    }
    
    function setMoveBnbToWallets(bool state) external onlyOwner {
        moveBnbToWallets = state;
        emit MoveBnbToWallets(state);
    }
    
    function excludeFromFee(address account) external onlyOwner {
        excludedFromFees[account] = true;
        emit ExcludedFromFees(account, true);
    }
    
    function includeInFee(address account) external onlyOwner {
        excludedFromFees[account] = false;
        emit ExcludedFromFees(account, false);
    }
    
    function setFeesByType(bool isBuy, uint reflection, uint marketing, uint development, uint nftTreasury, uint buyback) public onlyOwner {
        require(reflection + marketing + development + nftTreasury + buyback <= 20, "Fees too high");
        
        if (isBuy) {
            buyReflectionFee = reflection;
            buyMarketingFee = marketing;
            buyDevelopmentFee = development;
            buyNftTreasuryFee = nftTreasury;
            buyBuybackFee = buyback;
        } else {
            sellReflectionFee = reflection;
            sellMarketingFee = marketing;
            sellDevelopmentFee = development;
            sellNftTreasuryFee = nftTreasury;
            sellBuybackFee = buyback;
        }
        
        setFees();
    }
    
    function setMinimumWeiForTokenomics(uint _value) external onlyOwner {
        minimumWeiForTokenomics = _value;
    }
    
    // Internal fee functions
    function _reflectFee(uint256 rFee, uint256 tFee) private {
        _rTotal -= rFee;
        _tFeeTotal += tFee;
    }
    
    function _getValues(uint256 tAmount) private view returns (
        uint256 rAmount, 
        uint256 rTransferAmount, 
        uint256 rFee,
        uint256 tTransferAmount, 
        uint256 tFee, 
        uint256 tMarketing,
        uint256 tDevelopment, 
        uint256 tNftTreasury, 
        uint256 tBuyback
    ) {
        (tTransferAmount, tFee, tMarketing, tDevelopment, tNftTreasury, tBuyback) = _getTValues(tAmount);
        (rAmount, rTransferAmount, rFee) = _getRValues(tAmount, tFee, tMarketing, tDevelopment, tNftTreasury, tBuyback, _getRate());
        
        return (rAmount, rTransferAmount, rFee, tTransferAmount, tFee, tMarketing, tDevelopment, tNftTreasury, tBuyback);
    }
    
    function _getTValues(uint256 tAmount) private view returns (
        uint256 tTransferAmount, 
        uint256 tFee, 
        uint256 tMarketing, 
        uint256 tDevelopment, 
        uint256 tNftTreasury, 
        uint256 tBuyback
    ) {
        tFee = calculateReflectionFee(tAmount);
        tMarketing = calculateMarketingFee(tAmount);
        tDevelopment = calculateDevelopmentFee(tAmount);
        tNftTreasury = calculateNftTreasuryFee(tAmount);
        tBuyback = calculateBuybackFee(tAmount);
        
        tTransferAmount = tAmount - tFee - tMarketing - tDevelopment - tNftTreasury - tBuyback;
        
        return (tTransferAmount, tFee, tMarketing, tDevelopment, tNftTreasury, tBuyback);
    }
    
    function _getRValues(
        uint256 tAmount, 
        uint256 tFee, 
        uint256 tMarketing, 
        uint256 tDevelopment, 
        uint256 tNftTreasury, 
        uint256 tBuyback, 
        uint256 currentRate
    ) private pure returns (uint256, uint256, uint256) {
        uint256 rAmount = tAmount * currentRate;
        uint256 rFee = tFee * currentRate;
        uint256 rMarketing = tMarketing * currentRate;
        uint256 rDevelopment = tDevelopment * currentRate;
        uint256 rNftTreasury = tNftTreasury * currentRate;
        uint256 rBuyback = tBuyback * currentRate;
        
        uint256 rTransferAmount = rAmount - rFee - rMarketing - rDevelopment - rNftTreasury - rBuyback;
        
        return (rAmount, rTransferAmount, rFee);
    }
    
    function _getRate() private view returns (uint256) {
        (uint256 rSupply, uint256 tSupply) = _getCurrentSupply();
        return rSupply / tSupply;
    }
    
    function _getCurrentSupply() private view returns (uint256, uint256) {
        uint256 rSupply = _rTotal;
        uint256 tSupply = _tTotal;
        
        for (uint256 i = 0; i < _excluded.length; i++) {
            if (_rOwned[_excluded[i]] > rSupply || _tOwned[_excluded[i]] > tSupply) {
                return (_rTotal, _tTotal);
            }
            rSupply -= _rOwned[_excluded[i]];
            tSupply -= _tOwned[_excluded[i]];
        }
        
        if (rSupply < _rTotal / _tTotal) return (_rTotal, _tTotal);
        return (rSupply, tSupply);
    }
    
    function _takeMarketing(uint256 tMarketing) private {
        uint256 currentRate = _getRate();
        uint256 rMarketing = tMarketing * currentRate;
        _rOwned[address(this)] += rMarketing;
        
        if (_isExcluded[address(this)]) {
            _tOwned[address(this)] += tMarketing;
        }
    }
    
    function _takeDevelopment(uint256 tDevelopment) private {
        uint256 currentRate = _getRate();
        uint256 rDevelopment = tDevelopment * currentRate;
        _rOwned[address(this)] += rDevelopment;
        
        if (_isExcluded[address(this)]) {
            _tOwned[address(this)] += tDevelopment;
        }
    }
    
    function _takeNftTreasury(uint256 tNftTreasury) private {
        uint256 currentRate = _getRate();
        uint256 rNftTreasury = tNftTreasury * currentRate;
        _rOwned[address(this)] += rNftTreasury;
        
        if (_isExcluded[address(this)]) {
            _tOwned[address(this)] += tNftTreasury;
        }
    }
    
    function _takeBuyback(uint256 tBuyback) private {
        uint256 currentRate = _getRate();
        uint256 rBuyback = tBuyback * currentRate;
        _rOwned[address(this)] += rBuyback;
        
        if (_isExcluded[address(this)]) {
            _tOwned[address(this)] += tBuyback;
        }
    }
    
    function calculateReflectionFee(uint256 _amount) private view returns (uint256) {
        return _amount * _reflectionFee / 10**2;
    }
    
    function calculateMarketingFee(uint256 _amount) private view returns (uint256) {
        return _amount * _marketingFee / 10**2;
    }
    
    function calculateDevelopmentFee(uint256 _amount) private view returns (uint256) {
        return _amount * _developmentFee / 10**2;
    }
    
    function calculateNftTreasuryFee(uint256 _amount) private view returns (uint256) {
        return _amount * _nftTreasuryFee / 10**2;
    }
    
    function calculateBuybackFee(uint256 _amount) private view returns (uint256) {
        return _amount * _buybackFee / 10**2;
    }
    
    function setOldFees() private {
        _oldReflectionFee = _reflectionFee;
        _oldMarketingFee = _marketingFee;
        _oldDevelopmentFee = _developmentFee;
        _oldNftTreasuryFee = _nftTreasuryFee;
        _oldBuybackFee = _buybackFee;
    }
    
    function shutdownFees() private {
        _reflectionFee = 0;
        _marketingFee = 0;
        _developmentFee = 0;
        _nftTreasuryFee = 0;
        _buybackFee = 0;
    }
    
    function setFeesByType(uint tradeType) private {
        if (tradeType == 1) { // Buy
            _reflectionFee = buyReflectionFee;
            _marketingFee = buyMarketingFee;
            _developmentFee = buyDevelopmentFee;
            _nftTreasuryFee = buyNftTreasuryFee;
            _buybackFee = buyBuybackFee;
        } else if (tradeType == 2) { // Sell
            _reflectionFee = sellReflectionFee;
            _marketingFee = sellMarketingFee;
            _developmentFee = sellDevelopmentFee;
            _nftTreasuryFee = sellNftTreasuryFee;
            _buybackFee = sellBuybackFee;
        }
    }
    
    function restoreFees() private {
        _reflectionFee = _oldReflectionFee;
        _marketingFee = _oldMarketingFee;
        _developmentFee = _oldDevelopmentFee;
        _nftTreasuryFee = _oldNftTreasuryFee;
        _buybackFee = _oldBuybackFee;
    }
    
    modifier checkDisableFees(bool isEnabled, uint tradeType, address from) {
        if (!isEnabled) {
            setOldFees();
            shutdownFees();
            _;
            restoreFees();
        } else {
            if (tradeType == 1 || tradeType == 2) { // Buy or sell
                setOldFees();
                setFeesByType(tradeType);
                _;
                restoreFees();
            } else { // Wallet to wallet transfer
                setOldFees();
                shutdownFees();
                _;
                restoreFees();
            }
        }
    }
    
    function isExcludedFromFee(address account) public view returns (bool) {
        return excludedFromFees[account];
    }
    
    function _approve(address owner, address spender, uint256 amount) private {
        require(owner != address(0), "ERC20: approve from the zero address");
        require(spender != address(0), "ERC20: approve to the zero address");
        
        _allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }
    
    modifier fastTx() {
        isInternalTransaction = true;
        _;
        isInternalTransaction = false;
    }
    
    function sendToWallet(uint amount) private {
        // This function was incomplete in the original code
        // Implement logic to distribute BNB to respective wallets
        uint256 marketingShare = amount * buyMarketingFee / buyFee;
        uint256 developmentShare = amount * buyDevelopmentFee / buyFee;
        uint256 nftTreasuryShare = amount * buyNftTreasuryFee / buyFee;
        uint256 buybackShare = amount * buyBuybackFee / buyFee;
        
        payable(marketingWallet).transfer(marketingShare);
        payable(developmentWallet).transfer(developmentShare);
        payable(nftTreasuryWallet).transfer(nftTreasuryShare);
        payable(buybackWallet).transfer(buybackShare);
        
        emit MarketingCollected(marketingShare);
        emit DevelopmentCollected(developmentShare);
        emit NftTreasuryCollected(nftTreasuryShare);
        emit BuyBackCollected(buybackShare);
    }
    
    function swapTokensForEth(uint256 tokenAmount) private {
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = uniswapV2Router.WETH();
        
        _approve(address(this), address(uniswapV2Router), tokenAmount);
        
        uniswapV2Router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            tokenAmount,
            0,
            path,
            address(this),
            block.timestamp
        );
    }
    
    function swapAndLiquify(uint256 contractTokenBalance) private {
        // Split the contract balance into halves
        uint256 half = contractTokenBalance / 2;
        uint256 otherHalf = contractTokenBalance - half;
        
        // Capture the contract's current ETH balance
        uint256 initialBalance = address(this).balance;
        
        // Swap tokens for ETH
        swapTokensForEth(half);
        
        // How much ETH did we just swap into?
        uint256 newBalance = address(this).balance - initialBalance;
        
        // Add liquidity to Uniswap
        addLiquidity(otherHalf, newBalance);
    }
    
    function addLiquidity(uint256 tokenAmount, uint256 ethAmount) private {
        // Approve token transfer to cover all possible scenarios
        _approve(address(this), address(uniswapV2Router), tokenAmount);
        
        // Add the liquidity
        uniswapV2Router.addLiquidityETH{value: ethAmount}(
            address(this),
            tokenAmount,
            0, // Slippage is unavoidable
            0, // Slippage is unavoidable
            owner(),
            block.timestamp
        );
    }
    
    function _transfer(address from, address to, uint256 amount) private {
        uint tradeType = 0;
        bool takeFee = true;
        
        require(from != address(0), "ERC20: transfer from the zero address");
        require(amount > 0, "Transfer amount must be greater than zero");
        
        // Market status flag
        if (!marketActive) {
            require(premarketUser[from], "Cannot trade before the market opening");
        }
        
        // Normal transaction
        if (!isInternalTransaction) {
            // Buy
            if (automatedMarketMakerPairs[from]) {
                tradeType = 1;
                
                if (limitActive && !premarketUser[to]) {
                    require(amount <= maxBuyTx, "Buy amount exceeds limit");
                    require(balanceOf(to) + amount <= maxWallet, "Wallet balance exceeds limit");
                    
                    if (buyTimeLimit) {
                        require(block.timestamp >= userLastBuy[to] + buySecondsLimit, "Buy time limit not reached");
                        userLastBuy[to] = block.timestamp;
                    }
                }
            }
            // Sell
            else if (automatedMarketMakerPairs[to]) {
                tradeType = 2;
                
                if (limitActive && !premarketUser[from]) {
                    require(amount <= maxSellTx, "Sell amount exceeds limit");
                }
                
                // Liquidity generator for tokenomics
                if (swapAndLiquifyEnabled && 
                    balanceOf(uniswapV2Pair) > 0 &&
                    startTimeForSwap + intervalSecondsForSwap <= block.timestamp) {
                    startTimeForSwap = block.timestamp;
                    
                    uint256 contractTokenBalance = balanceOf(address(this));
                    if (contractTokenBalance > 0) {
                        swapAndLiquify(contractTokenBalance);
                    }
                }
            }
            
            // Send converted BNB from fees to respective wallets
            if (moveBnbToWallets) {
                uint256 remainingBnb = address(this).balance;
                if (remainingBnb > minimumWeiForTokenomics) {
                    sendToWallet(remainingBnb);
                }
            }
        }
        
        // If any account belongs to excludedFromFees account then remove the fee
        if (excludedFromFees[from] || excludedFromFees[to]) {
            takeFee = false;
        }
        
        // Transfer tokens
        _tokenTransfer(from, to, amount, takeFee, tradeType);
    }
    
    function _tokenTransfer(address sender, address recipient, uint256 amount, bool takeFee, uint tradeType) 
        private 
        checkDisableFees(takeFee, tradeType, sender) 
    {
        if (_isExcluded[sender] && !_isExcluded[recipient]) {
            _transferFromExcluded(sender, recipient, amount);
        } else if (!_isExcluded[sender] && _isExcluded[recipient]) {
            _transferToExcluded(sender, recipient, amount);
        } else if (!_isExcluded[sender] && !_isExcluded[recipient]) {
            _transferStandard(sender, recipient, amount);
        } else if (_isExcluded[sender] && _isExcluded[recipient]) {
            _transferBothExcluded(sender, recipient, amount);
        } else {
            _transferStandard(sender, recipient, amount);
        }
    }
    
    function _transferStandard(address sender, address recipient, uint256 tAmount) private {
        (uint256 rAmount, uint256 rTransferAmount, uint256 rFee, uint256 tTransferAmount, uint256 tFee, 
         uint256 tMarketing, uint256 tDevelopment, uint256 tNftTreasury, uint256 tBuyback) = _getValues(tAmount);
        
        _rOwned[sender] -= rAmount;
        _rOwned[recipient] += rTransferAmount;
        
        _takeMarketing(tMarketing);
        _takeDevelopment(tDevelopment);
        _takeNftTreasury(tNftTreasury);
        _takeBuyback(tBuyback);
        _reflectFee(rFee, tFee);
        
        emit Transfer(sender, recipient, tTransferAmount);
    }
    
    function _transferToExcluded(address sender, address recipient, uint256 tAmount) private {
        (uint256 rAmount, uint256 rTransferAmount, uint256 rFee, uint256 tTransferAmount, uint256 tFee, 
         uint256 tMarketing, uint256 tDevelopment, uint256 tNftTreasury, uint256 tBuyback) = _getValues(tAmount);
        
        _rOwned[sender] -= rAmount;
        _tOwned[recipient] += tTransferAmount;
        _rOwned[recipient] += rTransferAmount;
        
        _takeMarketing(tMarketing);
        _takeDevelopment(tDevelopment);
        _takeNftTreasury(tNftTreasury);
        _takeBuyback(tBuyback);
        _reflectFee(rFee, tFee);
        
        emit Transfer(sender, recipient, tTransferAmount);
    }
    
    function _transferFromExcluded(address sender, address recipient, uint256 tAmount) private {
        (uint256 rAmount, uint256 rTransferAmount, uint256 rFee, uint256 tTransferAmount, uint256 tFee, 
         uint256 tMarketing, uint256 tDevelopment, uint256 tNftTreasury, uint256 tBuyback) = _getValues(tAmount);
        
        _tOwned[sender] -= tAmount;
        _rOwned[sender] -= rAmount;
        _rOwned[recipient] += rTransferAmount;
        
        _takeMarketing(tMarketing);
        _takeDevelopment(tDevelopment);
        _takeNftTreasury(tNftTreasury);
        _takeBuyback(tBuyback);
        _reflectFee(rFee, tFee);
        
        emit Transfer(sender, recipient, tTransferAmount);
    }
    
    function _transferBothExcluded(address sender, address recipient, uint256 tAmount) private {
        (uint256 rAmount, uint256 rTransferAmount, uint256 rFee, uint256 tTransferAmount, uint256 tFee, 
         uint256 tMarketing, uint256 tDevelopment, uint256 tNftTreasury, uint256 tBuyback) = _getValues(tAmount);
        
        _tOwned[sender] -= tAmount;
        _rOwned[sender] -= rAmount;
        _tOwned[recipient] += tTransferAmount;
        _rOwned[recipient] += rTransferAmount;
        
        _takeMarketing(tMarketing);
        _takeDevelopment(tDevelopment);
        _takeNftTreasury(tNftTreasury);
        _takeBuyback(tBuyback);
        _reflectFee(rFee, tFee);
        
        emit Transfer(sender, recipient, tTransferAmount);
    }
    
    // Admin functions
    function KKMigration(address[] memory _address, uint256[] memory _amount) external onlyOwner {
        require(_address.length == _amount.length, "Address and amount arrays must have same length");
        
        for (uint i = 0; i < _amount.length; i++) {
            address adr = _address[i];
            uint amnt = _amount[i] * 10 ** decimals();
            
            (uint256 rAmount, uint256 rTransferAmount, , , , , , , ) = _getValues(amnt);
            
            _rOwned[owner()] -= rAmount;
            _rOwned[adr] += rTransferAmount;
            
            emit Transfer(owner(), adr, amnt);
        }
    }
    
    function setMarketActive(bool _marketActive) external onlyOwner {
        marketActive = _marketActive;
        if (_marketActive) {
            marketActiveAt = block.timestamp;
        }
    }
    
    function setSwapAndLiquifyEnabled(bool _enabled) external onlyOwner {
        swapAndLiquifyEnabled = _enabled;
        emit SwapSystemChanged(_enabled, intervalSecondsForSwap);
    }
    
    function setLimits(uint _maxBuyTx, uint _maxSellTx, uint _maxWallet) external onlyOwner {
        maxBuyTx = _maxBuyTx;
        maxSellTx = _maxSellTx;
        maxWallet = _maxWallet;
        emit LimitChanged(_maxSellTx, _maxBuyTx, _maxWallet);
    }
    
    function setWallets(address _marketing, address _development, address _nftTreasury, address _buyback) external onlyOwner {
        marketingWallet = _marketing;
        developmentWallet = _development;
        nftTreasuryWallet = _nftTreasury;
        buybackWallet = _buyback;
    }
    
    function setPremarketUser(address account, bool status) external onlyOwner {
        premarketUser[account] = status;
    }
    
    function setAutomatedMarketMakerPair(address pair, bool value) external onlyOwner {
        automatedMarketMakerPairs[pair] = value;
    }
    
    function setSwapInterval(uint256 _interval) external onlyOwner {
        intervalSecondsForSwap = _interval;
    }
    
    function setBuyTimeLimit(bool _buyTimeLimit, uint _buySecondsLimit) external onlyOwner {
        buyTimeLimit = _buyTimeLimit;
        buySecondsLimit = _buySecondsLimit;
    }
    
    function setLimitActive(bool _limitActive) external onlyOwner {
        limitActive = _limitActive;
    }
    
    // Emergency functions
    function emergencyWithdraw() external onlyOwner {
        payable(owner()).transfer(address(this).balance);
    }
    
    function emergencyTokenWithdraw(address tokenAddress) external onlyOwner {
        IERC20 token = IERC20(tokenAddress);
        uint256 balance = token.balanceOf(address(this));
        token.transfer(owner(), balance);
    }
}
