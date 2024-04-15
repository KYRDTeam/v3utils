// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "v3-periphery/interfaces/INonfungiblePositionManager.sol" as univ3;
import "v3-periphery/interfaces/external/IWETH9.sol";

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";

interface INonfungiblePositionManager is univ3.INonfungiblePositionManager {
    /// @notice mintParams for algebra v1
    struct AlgebraV1MintParams {
        address token0;
        address token1;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
    }

    /// @notice Creates a new position wrapped in a NFT
    /// @dev Call this when the pool does exist and is initialized. Note that if the pool is created but not initialized
    /// a method does not exist, i.e. the pool is assumed to be initialized.
    /// @param params The params necessary to mint a position, encoded as `MintParams` in calldata
    /// @return tokenId The ID of the token that represents the minted position
    /// @return liquidity The amount of liquidity for this position
    /// @return amount0 The amount of token0
    /// @return amount1 The amount of token1
    function mint(AlgebraV1MintParams calldata params)
        external
        payable
        returns (
            uint256 tokenId,
            uint128 liquidity,
            uint256 amount0,
            uint256 amount1
        );

    /// @return Returns the address of WNativeToken
    function WNativeToken() external view returns (address);
}

/// @title v3Utils v1.0
/// @notice Utility functions for Uniswap V3 positions
/// This is a completely ownerless/stateless contract - does not hold any ERC20 or NFTs.
/// It can be simply redeployed when new / better functionality is implemented
contract V3Utils is IERC721Receiver {

    using SafeCast for uint256;

    /// @notice Krystal Exchange Proxy
    address immutable public swapRouter;

    // error types
    error Unauthorized();
    error WrongContract();
    error SelfSend();
    error NotSupportedWhatToDo();
    error SameToken();
    error SwapFailed();
    error AmountError();
    error SlippageError();
    error CollectError();
    error TransferError();
    error EtherSendFailed();
    error TooMuchEtherSent();
    error NoEtherToken();
    error NotWETH();

    // events
    event CompoundFees(uint256 indexed tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);
    event ChangeRange(uint256 indexed tokenId, uint256 newTokenId);
    event WithdrawAndCollectAndSwap(uint256 indexed tokenId, address token, uint256 amount);
    event Swap(address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut);
    event SwapAndMint(uint256 indexed tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);
    event SwapAndIncreaseLiquidity(uint256 indexed tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);

    /// @notice Constructor
    /// @param _swapRouter Krystal Exchange Proxy
    constructor(address _swapRouter) {
        swapRouter = _swapRouter;
    }

    /// @notice Action which should be executed on provided NFT
    enum WhatToDo {
        CHANGE_RANGE,
        WITHDRAW_AND_COLLECT_AND_SWAP,
        COMPOUND_FEES
    }

    /// @notice protocol to provide lp
    enum Protocol {
        UNI_V3,
        ALGEBRA_V1
    }

    /// @notice Complete description of what should be executed on provided NFT - different fields are used depending on specified WhatToDo 
    struct Instructions {
        // what action to perform on provided Uniswap v3 position
        WhatToDo whatToDo;

        // protocol to provide lp
        Protocol protocol;

        // target token for swaps (if this is address(0) no swaps are executed)
        address targetToken;

        // for removing liquidity slippage
        uint256 amountRemoveMin0;
        uint256 amountRemoveMin1;

        // amountIn0 is used for swap and also as minAmount0 for decreased liquidity + collected fees
        uint256 amountIn0;
        // if token0 needs to be swapped to targetToken - set values
        uint256 amountOut0Min;
        bytes swapData0; // encoded data from 0x api call (address,bytes) - allowanceTarget,data

        // amountIn1 is used for swap and also as minAmount1 for decreased liquidity + collected fees
        uint256 amountIn1;
        // if token1 needs to be swapped to targetToken - set values
        uint256 amountOut1Min;
        bytes swapData1; // encoded data from 0x api call (address,bytes) - allowanceTarget,data

        // collect fee amount for COMPOUND_FEES / CHANGE_RANGE / WITHDRAW_AND_COLLECT_AND_SWAP (if uint256(128).max - ALL)
        uint128 feeAmount0;
        uint128 feeAmount1;

        // for creating new positions with CHANGE_RANGE
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        
        // remove liquidity amount for COMPOUND_FEES (in this case should be probably 0) / CHANGE_RANGE / WITHDRAW_AND_COLLECT_AND_SWAP
        uint128 liquidity;

        // for adding liquidity slippage
        uint256 amountAddMin0;
        uint256 amountAddMin1;

        // for all uniswap deadlineable functions
        uint256 deadline;

        // left over tokens will be sent to this address
        address recipient;

        // recipient of newly minted nft (the incoming NFT will ALWAYS be returned to from)
        address recipientNFT;

        // if tokenIn or tokenOut is WETH - unwrap
        bool unwrap;

        // data sent with returned token to IERC721Receiver (optional) 
        bytes returnData;

        // data sent with minted token to IERC721Receiver (optional)
        bytes swapAndMintReturnData;
    }

    struct ReturnLeftoverTokensParams{
        IWETH9 weth;
        address to;
        IERC20 token0;
        IERC20 token1;
        uint256 total0;
        uint256 total1;
        uint256 added0;
        uint256 added1;
        bool unwrap;
    }

    /// @notice Execute instruction by pulling approved NFT instead of direct safeTransferFrom call from owner
    /// @param tokenId Token to process
    /// @param instructions Instructions to execute
    function execute(INonfungiblePositionManager _nfpm, uint256 tokenId, Instructions calldata instructions) external
    {
        // must be approved beforehand
        _nfpm.safeTransferFrom(
            msg.sender,
            address(this),
            tokenId,
            abi.encode(instructions)
        );
    }

    /// @notice ERC721 callback function. Called on safeTransferFrom and does manipulation as configured in encoded Instructions parameter. 
    /// At the end the NFT (and any newly minted NFT) is returned to sender. The leftover tokens are sent to instructions.recipient.
    function onERC721Received(address, address from, uint256 tokenId, bytes calldata data) external override returns (bytes4) {

        INonfungiblePositionManager nfpm = INonfungiblePositionManager(msg.sender);
        // not allowed to send to itself
        if (from == address(this)) {
            revert SelfSend();
        }

        Instructions memory instructions = abi.decode(data, (Instructions));

        (address token0,address token1,uint128 liquidity) = _getPosition(nfpm, instructions.protocol, tokenId);

        uint256 amount0;
        uint256 amount1;
        if (instructions.liquidity != 0) {
            (amount0, amount1) = _decreaseLiquidity(nfpm, tokenId, instructions.liquidity, instructions.deadline, instructions.amountRemoveMin0, instructions.amountRemoveMin1);
        }
        (amount0, amount1) = _collectFees(nfpm, tokenId, IERC20(token0), IERC20(token1), instructions.feeAmount0 == type(uint128).max ? type(uint128).max : (amount0 + instructions.feeAmount0).toUint128(), instructions.feeAmount1 == type(uint128).max ? type(uint128).max : (amount1 + instructions.feeAmount1).toUint128());
        
        // check if enough tokens are available for swaps
        if (amount0 < instructions.amountIn0 || amount1 < instructions.amountIn1) {
            revert AmountError();
        }

        if (instructions.whatToDo == WhatToDo.COMPOUND_FEES) {
            if (instructions.targetToken == token0) {
                (liquidity, amount0, amount1) = _swapAndIncrease(SwapAndIncreaseLiquidityParams(instructions.protocol, nfpm, tokenId, amount0, amount1, instructions.recipient, instructions.deadline, IERC20(token1), instructions.amountIn1, instructions.amountOut1Min, instructions.swapData1, 0, 0, "", instructions.amountAddMin0, instructions.amountAddMin1), IERC20(token0), IERC20(token1), instructions.unwrap);
            } else if (instructions.targetToken == token1) {
                (liquidity, amount0, amount1) = _swapAndIncrease(SwapAndIncreaseLiquidityParams(instructions.protocol, nfpm, tokenId, amount0, amount1, instructions.recipient, instructions.deadline, IERC20(token0), 0, 0, "", instructions.amountIn0, instructions.amountOut0Min, instructions.swapData0, instructions.amountAddMin0, instructions.amountAddMin1), IERC20(token0), IERC20(token1), instructions.unwrap);
            } else {
                // no swap is done here
                (liquidity,amount0, amount1) = _swapAndIncrease(SwapAndIncreaseLiquidityParams(instructions.protocol, nfpm, tokenId, amount0, amount1, instructions.recipient, instructions.deadline, IERC20(address(0)), 0, 0, "", 0, 0, "", instructions.amountAddMin0, instructions.amountAddMin1), IERC20(token0), IERC20(token1), instructions.unwrap);
            }
            emit CompoundFees(tokenId, liquidity, amount0, amount1);            
        } else if (instructions.whatToDo == WhatToDo.CHANGE_RANGE) {

            uint256 newTokenId;

            if (instructions.targetToken == token0) {
                (newTokenId,,,) = _swapAndMint(SwapAndMintParams(instructions.protocol, nfpm, IERC20(token0), IERC20(token1), instructions.fee, instructions.tickLower, instructions.tickUpper, amount0, amount1, instructions.recipient, instructions.recipientNFT, instructions.deadline, IERC20(token1), instructions.amountIn1, instructions.amountOut1Min, instructions.swapData1, 0, 0, "", instructions.amountAddMin0, instructions.amountAddMin1, instructions.swapAndMintReturnData), instructions.unwrap);
            } else if (instructions.targetToken == token1) {
                (newTokenId,,,) = _swapAndMint(SwapAndMintParams(instructions.protocol, nfpm, IERC20(token0), IERC20(token1), instructions.fee, instructions.tickLower, instructions.tickUpper, amount0, amount1, instructions.recipient, instructions.recipientNFT, instructions.deadline, IERC20(token0), 0, 0, "", instructions.amountIn0, instructions.amountOut0Min, instructions.swapData0, instructions.amountAddMin0, instructions.amountAddMin1, instructions.swapAndMintReturnData), instructions.unwrap);
            } else {
                // no swap is done here
                (newTokenId,,,) = _swapAndMint(SwapAndMintParams(instructions.protocol, nfpm, IERC20(token0), IERC20(token1), instructions.fee, instructions.tickLower, instructions.tickUpper, amount0, amount1, instructions.recipient, instructions.recipientNFT, instructions.deadline, IERC20(address(0)), 0, 0, "", 0, 0, "", instructions.amountAddMin0, instructions.amountAddMin1, instructions.swapAndMintReturnData), instructions.unwrap);
            }

            emit ChangeRange(tokenId, newTokenId);
        } else if (instructions.whatToDo == WhatToDo.WITHDRAW_AND_COLLECT_AND_SWAP) {
            IWETH9 weth = _getWeth9(nfpm, instructions.protocol);
            uint256 targetAmount;
            if (token0 != instructions.targetToken) {
                (uint256 amountInDelta, uint256 amountOutDelta) = _swap(IERC20(token0), IERC20(instructions.targetToken), amount0, instructions.amountOut0Min, instructions.swapData0);
                if (amountInDelta < amount0) {
                    _transferToken(weth, instructions.recipient, IERC20(token0), amount0 - amountInDelta, instructions.unwrap);
                }
                targetAmount += amountOutDelta;
            } else {
                targetAmount += amount0; 
            }
            if (token1 != instructions.targetToken) {
                (uint256 amountInDelta, uint256 amountOutDelta) = _swap(IERC20(token1), IERC20(instructions.targetToken), amount1, instructions.amountOut1Min, instructions.swapData1);
                if (amountInDelta < amount1) {
                    _transferToken(weth, instructions.recipient, IERC20(token1), amount1 - amountInDelta, instructions.unwrap);
                }
                targetAmount += amountOutDelta;
            } else {
                targetAmount += amount1; 
            }

            // send complete target amount
            if (targetAmount != 0 && instructions.targetToken != address(0)) {
                _transferToken(weth, instructions.recipient, IERC20(instructions.targetToken), targetAmount, instructions.unwrap);
            }

            emit WithdrawAndCollectAndSwap(tokenId, instructions.targetToken, targetAmount);
        } else {
            revert NotSupportedWhatToDo();
        }
        
        // return token to owner (this line guarantees that token is returned to originating owner)
        nfpm.safeTransferFrom(address(this), from, tokenId, instructions.returnData);

        return IERC721Receiver.onERC721Received.selector;
    }

    /// @notice Params for swap() function
    struct SwapParams {
        IWETH9 weth;
        IERC20 tokenIn;
        IERC20 tokenOut;
        uint256 amountIn;
        uint256 minAmountOut;
        address recipient; // recipient of tokenOut and leftover tokenIn (if any leftover)
        bytes swapData;
        bool unwrap; // if tokenIn or tokenOut is WETH - unwrap
    }

    /// @notice Swaps amountIn of tokenIn for tokenOut - returning at least minAmountOut
    /// @param params Swap configuration
    /// If tokenIn is wrapped native token - both the token or the wrapped token can be sent (the sum of both must be equal to amountIn)
    /// Optionally unwraps any wrapped native token and returns native token instead
    function swap(SwapParams calldata params) external payable returns (uint256 amountOut) {

        if (params.tokenIn == params.tokenOut) {
            revert SameToken();
        }

        _prepareAdd(params.weth, params.tokenIn, IERC20(address(0)), IERC20(address(0)), params.amountIn, 0, 0);

        uint256 amountInDelta;
        (amountInDelta, amountOut) = _swap(params.tokenIn, params.tokenOut, params.amountIn, params.minAmountOut, params.swapData);

        // send swapped amount of tokenOut
        if (amountOut != 0) {
            _transferToken(params.weth, params.recipient, params.tokenOut, amountOut, params.unwrap);
        }

        // if not all was swapped - return leftovers of tokenIn
        uint256 leftOver = params.amountIn - amountInDelta;
        if (leftOver != 0) {
            _transferToken(params.weth, params.recipient, params.tokenIn, leftOver, params.unwrap);
        }
    }

    /// @notice Params for swapAndMint() function
    struct SwapAndMintParams {
        Protocol protocol;
        INonfungiblePositionManager nfpm;

        IERC20 token0;
        IERC20 token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;

        // how much is provided of token0 and token1
        uint256 amount0;
        uint256 amount1;
        address recipient; // recipient of leftover tokens
        address recipientNFT; // recipient of nft
        uint256 deadline;

        // source token for swaps (maybe either address(0), token0, token1 or another token)
        // if swapSourceToken is another token than token0 or token1 -> amountIn0 + amountIn1 of swapSourceToken are expected to be available
        IERC20 swapSourceToken;

        // if swapSourceToken needs to be swapped to token0 - set values
        uint256 amountIn0;
        uint256 amountOut0Min;
        bytes swapData0;

        // if swapSourceToken needs to be swapped to token1 - set values
        uint256 amountIn1;
        uint256 amountOut1Min;
        bytes swapData1;

        // min amount to be added after swap
        uint256 amountAddMin0;
        uint256 amountAddMin1;

        // data to be sent along newly created NFT when transfered to recipientNFT (sent to IERC721Receiver callback)
        bytes returnData;
    }

    /// @notice Does 1 or 2 swaps from swapSourceToken to token0 and token1 and adds as much as possible liquidity to a newly minted position.
    /// @param params Swap and mint configuration
    /// Newly minted NFT and leftover tokens are returned to recipient
    function swapAndMint(SwapAndMintParams calldata params) external payable returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1) {
        if (params.token0 == params.token1) {
            revert SameToken();
        }
        IWETH9 weth = _getWeth9(params.nfpm, params.protocol);
        _prepareAdd(weth, params.token0, params.token1, params.swapSourceToken, params.amount0, params.amount1, params.amountIn0 + params.amountIn1);
        (tokenId, liquidity, amount0, amount1) = _swapAndMint(params, msg.value != 0);
    }

    /// @notice Params for swapAndIncreaseLiquidity() function
    struct SwapAndIncreaseLiquidityParams {
        Protocol protocol;
        INonfungiblePositionManager nfpm;
        uint256 tokenId;

        // how much is provided of token0 and token1
        uint256 amount0;
        uint256 amount1;
        address recipient; // recipient of leftover tokens
        uint256 deadline;
        
        // source token for swaps (maybe either address(0), token0, token1 or another token)
        // if swapSourceToken is another token than token0 or token1 -> amountIn0 + amountIn1 of swapSourceToken are expected to be available
        IERC20 swapSourceToken;

        // if swapSourceToken needs to be swapped to token0 - set values
        uint256 amountIn0;
        uint256 amountOut0Min;
        bytes swapData0;

        // if swapSourceToken needs to be swapped to token1 - set values
        uint256 amountIn1;
        uint256 amountOut1Min;
        bytes swapData1;

        // min amount to be added after swap
        uint256 amountAddMin0;
        uint256 amountAddMin1;
    }

    /// @notice Does 1 or 2 swaps from swapSourceToken to token0 and token1 and adds as much as possible liquidity to any existing position (no need to be position owner).
    /// @param params Swap and increase liquidity configuration
    // Sends any leftover tokens to recipient.
    function swapAndIncreaseLiquidity(SwapAndIncreaseLiquidityParams calldata params) external payable returns (uint128 liquidity, uint256 amount0, uint256 amount1) {
        address owner = params.nfpm.ownerOf(params.tokenId);
        require(owner == msg.sender, "sender is not owner of position");
        (address token0,address token1,) = _getPosition(params.nfpm, params.protocol, params.tokenId);
        IWETH9 weth = _getWeth9(params.nfpm, params.protocol);
        _prepareAdd(weth, IERC20(token0), IERC20(token1), params.swapSourceToken, params.amount0, params.amount1, params.amountIn0 + params.amountIn1);
        (liquidity, amount0, amount1) = _swapAndIncrease(params, IERC20(token0), IERC20(token1), msg.value != 0);
    }

    // checks if required amounts are provided and are exact - wraps any provided ETH as WETH
    // if less or more provided reverts
    function _prepareAdd(IWETH9 weth, IERC20 token0, IERC20 token1, IERC20 otherToken, uint256 amount0, uint256 amount1, uint256 amountOther) internal
    {
        uint256 amountAdded0;
        uint256 amountAdded1;
        uint256 amountAddedOther;

        // wrap ether sent
        if (msg.value != 0) {
            weth.deposit{ value: msg.value }();

            if (address(weth) == address(token0)) {
                amountAdded0 = msg.value;
                if (amountAdded0 > amount0) {
                    revert TooMuchEtherSent();
                }
            } else if (address(weth) == address(token1)) {
                amountAdded1 = msg.value;
                if (amountAdded1 > amount1) {
                    revert TooMuchEtherSent();
                }
            } else if (address(weth) == address(otherToken)) {
                amountAddedOther = msg.value;
                if (amountAddedOther > amountOther) {
                    revert TooMuchEtherSent();
                }
            } else {
                revert NoEtherToken();
            }
        }

        // get missing tokens (fails if not enough provided)
        if (amount0 > amountAdded0) {
            uint256 balanceBefore = token0.balanceOf(address(this));
            SafeERC20.safeTransferFrom(token0, msg.sender, address(this), amount0 - amountAdded0);
            uint256 balanceAfter = token0.balanceOf(address(this));
            if (balanceAfter - balanceBefore != amount0 - amountAdded0) {
                revert TransferError(); // reverts for fee-on-transfer tokens
            }
        }
        if (amount1 > amountAdded1) {
            uint256 balanceBefore = token1.balanceOf(address(this));
            SafeERC20.safeTransferFrom(token1, msg.sender, address(this), amount1 - amountAdded1);
            uint256 balanceAfter = token1.balanceOf(address(this));
            if (balanceAfter - balanceBefore != amount1 - amountAdded1) {
                revert TransferError(); // reverts for fee-on-transfer tokens
            }
        }
        if (amountOther > amountAddedOther && address(otherToken) != address(0) && token0 != otherToken && token1 != otherToken) {
            uint256 balanceBefore = otherToken.balanceOf(address(this));
            SafeERC20.safeTransferFrom(otherToken, msg.sender, address(this), amountOther - amountAddedOther);
            uint256 balanceAfter = otherToken.balanceOf(address(this));
            if (balanceAfter - balanceBefore != amountOther - amountAddedOther) {
                revert TransferError(); // reverts for fee-on-transfer tokens
            }
        }
    }

    // swap and mint logic
    function _swapAndMint(SwapAndMintParams memory params, bool unwrap) internal returns (uint256 tokenId, uint128 liquidity, uint256 added0, uint256 added1) {
        (uint256 total0, uint256 total1) = _swapAndPrepareAmounts(params, unwrap);
        IWETH9 weth;
        if (params.protocol == Protocol.UNI_V3) {
            // mint is done to address(this) because it is not a safemint and safeTransferFrom needs to be done manually afterwards
            (tokenId,liquidity,added0,added1) = _mintUniv3(params, total0, total1);
            weth = IWETH9(params.nfpm.WETH9());
        } else if (params.protocol == Protocol.ALGEBRA_V1) {
            // mint is done to address(this) because it is not a safemint and safeTransferFrom needs to be done manually afterwards
            (tokenId,liquidity,added0,added1) = _mintAlgebraV1(params, total0, total1);
            weth = IWETH9(params.nfpm.WNativeToken());
        } else {
            revert("Invalid protocol");
        }
        params.nfpm.safeTransferFrom(address(this), params.recipientNFT, tokenId, params.returnData);
        emit SwapAndMint(tokenId, liquidity, added0, added1);

        _returnLeftoverTokens(ReturnLeftoverTokensParams(weth, params.recipient, params.token0, params.token1, total0, total1, added0, added1, unwrap));
    }

    function _mintUniv3(SwapAndMintParams memory params, uint256 total0, uint256 total1) internal returns (
        uint256 tokenId,
        uint128 liquidity,
        uint256 amount0,
        uint256 amount1
    ) {
        INonfungiblePositionManager.MintParams memory mintParams = 
            univ3.INonfungiblePositionManager.MintParams(
                address(params.token0), 
                address(params.token1), 
                params.fee, 
                params.tickLower,
                params.tickUpper,
                total0,
                total1, 
                params.amountAddMin0,
                params.amountAddMin1,
                address(this), // is sent to real recipient aftwards
                params.deadline
            );

        // mint is done to address(this) because it is not a safemint and safeTransferFrom needs to be done manually afterwards
        return params.nfpm.mint(mintParams);
    }

    function _mintAlgebraV1(SwapAndMintParams memory params, uint256 total0, uint256 total1) internal returns (
        uint256 tokenId,
        uint128 liquidity,
        uint256 amount0,
        uint256 amount1
    ) {
        INonfungiblePositionManager.AlgebraV1MintParams memory mintParams = 
            INonfungiblePositionManager.AlgebraV1MintParams(
                address(params.token0), 
                address(params.token1), 
                params.tickLower,
                params.tickUpper,
                total0,
                total1, 
                params.amountAddMin0,
                params.amountAddMin1,
                address(this), // is sent to real recipient aftwards
                params.deadline
            );

        // mint is done to address(this) because it is not a safemint and safeTransferFrom needs to be done manually afterwards
        return params.nfpm.mint(mintParams);
    }

    // swap and increase logic
    function _swapAndIncrease(SwapAndIncreaseLiquidityParams memory params, IERC20 token0, IERC20 token1, bool unwrap) internal returns (uint128 liquidity, uint256 added0, uint256 added1) {
        (uint256 total0, uint256 total1) = _swapAndPrepareAmounts(
            SwapAndMintParams(params.protocol, params.nfpm, token0, token1, 0, 0, 0, params.amount0, params.amount1, params.recipient, params.recipient, params.deadline, params.swapSourceToken, params.amountIn0, params.amountOut0Min, params.swapData0, params.amountIn1, params.amountOut1Min, params.swapData1, params.amountAddMin0, params.amountAddMin1, ""), unwrap);

        INonfungiblePositionManager.IncreaseLiquidityParams memory increaseLiquidityParams = 
            univ3.INonfungiblePositionManager.IncreaseLiquidityParams(
                params.tokenId, 
                total0, 
                total1, 
                params.amountAddMin0,
                params.amountAddMin1, 
                params.deadline
            );

        (liquidity, added0, added1) = params.nfpm.increaseLiquidity(increaseLiquidityParams);

        emit SwapAndIncreaseLiquidity(params.tokenId, liquidity, added0, added1);
        IWETH9 weth = _getWeth9(params.nfpm, params.protocol);
        _returnLeftoverTokens(ReturnLeftoverTokensParams(weth, params.recipient, token0, token1, total0, total1, added0, added1, unwrap));
    }

    // swaps available tokens and prepares max amounts to be added to nfpm
    function _swapAndPrepareAmounts(SwapAndMintParams memory params, bool unwrap) internal returns (uint256 total0, uint256 total1) {
        if (params.swapSourceToken == params.token0) { 
            if (params.amount0 < params.amountIn1) {
                revert AmountError();
            }
            (uint256 amountInDelta, uint256 amountOutDelta) = _swap(params.token0, params.token1, params.amountIn1, params.amountOut1Min, params.swapData1);
            total0 = params.amount0 - amountInDelta;
            total1 = params.amount1 + amountOutDelta;
        } else if (params.swapSourceToken == params.token1) { 
            if (params.amount1 < params.amountIn0) {
                revert AmountError();
            }
            (uint256 amountInDelta, uint256 amountOutDelta) = _swap(params.token1, params.token0, params.amountIn0, params.amountOut0Min, params.swapData0);
            total1 = params.amount1 - amountInDelta;
            total0 = params.amount0 + amountOutDelta;
        } else if (address(params.swapSourceToken) != address(0)) {

            (uint256 amountInDelta0, uint256 amountOutDelta0) = _swap(params.swapSourceToken, params.token0, params.amountIn0, params.amountOut0Min, params.swapData0);
            (uint256 amountInDelta1, uint256 amountOutDelta1) = _swap(params.swapSourceToken, params.token1, params.amountIn1, params.amountOut1Min, params.swapData1);
            total0 = params.amount0 + amountOutDelta0;
            total1 = params.amount1 + amountOutDelta1;

            // return third token leftover if any
            uint256 leftOver = params.amountIn0 + params.amountIn1 - amountInDelta0 - amountInDelta1;

            if (leftOver != 0) {
                IWETH9 weth = _getWeth9(params.nfpm, params.protocol);
                _transferToken(weth, params.recipient, params.swapSourceToken, leftOver, unwrap);
            }
        } else {
            total0 = params.amount0;
            total1 = params.amount1;
        }

        if (total0 != 0) {
            params.token0.approve(address(params.nfpm), total0);
        }
        if (total1 != 0) {
            params.token1.approve(address(params.nfpm), total1);
        }
    }

    // returns leftover token balances
    // viewed
    function _returnLeftoverTokens(ReturnLeftoverTokensParams memory params) internal {

        uint256 left0 = params.total0 - params.added0;
        uint256 left1 = params.total1 - params.added1;

        // return leftovers
        if (left0 != 0) {
            _transferToken(params.weth, params.to, params.token0, left0, params.unwrap);
        }
        if (left1 != 0) {
            _transferToken(params.weth, params.to, params.token1, left1, params.unwrap);
        }
    }

    // transfers token (or unwraps WETH and sends ETH)
    // viewed
    function _transferToken(IWETH9 weth, address to, IERC20 token, uint256 amount, bool unwrap) internal {
        if (address(weth) == address(token) && unwrap) {
            weth.withdraw(amount);
            (bool sent, ) = to.call{value: amount}("");
            if (!sent) {
                revert EtherSendFailed();
            }
        } else {
            SafeERC20.safeTransfer(token, to, amount);
        }
    }

    // general swap function which uses external router with off-chain calculated swap instructions
    // does slippage check with amountOutMin param
    // returns token amounts deltas after swap
    function _swap(IERC20 tokenIn, IERC20 tokenOut, uint256 amountIn, uint256 amountOutMin, bytes memory swapData) internal returns (uint256 amountInDelta, uint256 amountOutDelta) {
        if (amountIn != 0 && swapData.length != 0 && address(tokenOut) != address(0)) {
            uint256 balanceInBefore = tokenIn.balanceOf(address(this));
            uint256 balanceOutBefore = tokenOut.balanceOf(address(this));

            // approve needed amount
            tokenIn.approve(swapRouter, amountIn);
            // execute swap
            (bool success,) = swapRouter.call(swapData);
            if (!success) {
                revert SwapFailed();
            }

            // reset approval
            tokenIn.approve(swapRouter, 0);

            uint256 balanceInAfter = tokenIn.balanceOf(address(this));
            uint256 balanceOutAfter = tokenOut.balanceOf(address(this));

            amountInDelta = balanceInBefore - balanceInAfter;
            amountOutDelta = balanceOutAfter - balanceOutBefore;

            // amountMin slippage check
            if (amountOutDelta < amountOutMin) {
                revert SlippageError();
            }

            // event for any swap with exact swapped value
            emit Swap(address(tokenIn), address(tokenOut), amountInDelta, amountOutDelta);
        }
    }

    // decreases liquidity from uniswap v3 position
    // viewed
    function _decreaseLiquidity(INonfungiblePositionManager nfpm, uint256 tokenId, uint128 liquidity, uint256 deadline, uint256 token0Min, uint256 token1Min) internal returns (uint256 amount0, uint256 amount1) {
        if (liquidity != 0) {
            (amount0, amount1) = nfpm.decreaseLiquidity(
                univ3.INonfungiblePositionManager.DecreaseLiquidityParams(
                    tokenId, 
                    liquidity, 
                    token0Min, 
                    token1Min,
                    deadline
                )
            );
        }
    }

    // collects specified amount of fees from uniswap v3 position
    // viewed
    function _collectFees(INonfungiblePositionManager nfpm, uint256 tokenId, IERC20 token0, IERC20 token1, uint128 collectAmount0, uint128 collectAmount1) internal returns (uint256 amount0, uint256 amount1) {
        uint256 balanceBefore0 = token0.balanceOf(address(this));
        uint256 balanceBefore1 = token1.balanceOf(address(this));
        (amount0, amount1) = nfpm.collect(
            univ3.INonfungiblePositionManager.CollectParams(tokenId, address(this), collectAmount0, collectAmount1)
        );
        uint256 balanceAfter0 = token0.balanceOf(address(this));
        uint256 balanceAfter1 = token1.balanceOf(address(this));

        // reverts for fee-on-transfer tokens
        if (balanceAfter0 - balanceBefore0 != amount0) {
            revert CollectError();
        }
        if (balanceAfter1 - balanceBefore1 != amount1) {
            revert CollectError();
        }
    }

    function _getWeth9(INonfungiblePositionManager nfpm, Protocol protocol) view internal returns (IWETH9 weth) {
        if (protocol == Protocol.UNI_V3) {
            weth = IWETH9(nfpm.WETH9());
        } else if (protocol == Protocol.ALGEBRA_V1) {
            weth = IWETH9(nfpm.WNativeToken());
        } else {
            revert("invalid protocol");
        }
    }

    function _getPosition(INonfungiblePositionManager nfpm, Protocol protocol, uint256 tokenId) internal returns (address token0, address token1, uint128 liquidity) {
        (bool success, bytes memory data) = address(nfpm).call(abi.encodeWithSignature("positions(uint256)", tokenId));
        if (!success) {
            revert("v3utils: call get position failed");
        }
        if (protocol == Protocol.UNI_V3) {
            (,, token0, token1,,,, liquidity,,,,) = abi.decode(data, (uint96,address,address,address,uint24,int24,int24,uint128,uint256,uint256,uint128,uint128));
        } else if (protocol == Protocol.ALGEBRA_V1) {
            (,, token0, token1,,, liquidity,,,,) = abi.decode(data, (uint96,address,address,address,int24,int24,uint128,uint256,uint256,uint128,uint128));
        }
    }

    // needed for WETH unwrapping
    receive() external payable{}
}