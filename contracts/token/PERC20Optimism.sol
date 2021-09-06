pragma solidity 0.6.12;

import "./ERC20Interface.sol";
import "./IPToken.sol";

import "../libs/Exponential.sol";
import "../libs/ErrorReporter.sol";

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";


contract PERC20Optimism is IPToken, Exponential, TokenErrorReporter, OwnableUpgradeable {

    using SafeMath for uint256;

    address public underlying;

    function initialize(address underlying_, string memory name_, string memory symbol_, uint8 decimals_, uint256 initialExchangeRateMantissa_) public initializer {
        OwnableUpgradeable.__Ownable_init();
        initialExchangeRateMantissa = initialExchangeRateMantissa_;
        accrualBlockNumber = getBlockNumber();
        borrowIndex = mantissaOne;
        name = name_;
        symbol = symbol_;
        decimals = decimals_;
        underlying = underlying_;
        _notEntered = true;
    }

    /**
     * @notice Transfer `tokens` tokens from `src` to `dst` by `spender`
     * @dev Called by both `transfer` and `transferFrom` internally
     * @param spender The address of the account performing the transfer
     * @param src The address of the source account
     * @param dst The address of the destination account
     * @param tokens The number of tokens to transfer
     * @return Whether or not the transfer succeeded
     */
    function transferTokens(address spender, address src, address dst, uint tokens) internal returns (uint) {
        uint allowed = comptroller.transferAllowed(address(this), src, dst, tokens);
        if (allowed != 0) {
            return failOpaque(Error.COMPTROLLER_REJECTION, FailureInfo.TRANSFER_COMPTROLLER_REJECTION, allowed);
        }
        if (src == dst) {
            return fail(Error.BAD_INPUT, FailureInfo.TRANSFER_NOT_ALLOWED);
        }
        uint startingAllowance = 0;
        if (spender == src) {
            startingAllowance = uint(- 1);
        } else {
            startingAllowance = transferAllowances[src][spender];
        }
        uint allowanceNew = startingAllowance.sub(tokens);
        uint srcTokensNew = accountTokens[src].sub(tokens);
        uint dstTokensNew = accountTokens[dst].add(tokens);
        accountTokens[src] = srcTokensNew;
        accountTokens[dst] = dstTokensNew;
        if (startingAllowance != uint(- 1)) {
            transferAllowances[src][spender] = allowanceNew;
        }
        emit Transfer(src, dst, tokens);
        return 0;
    }

    /**
     * @notice Transfer `amount` tokens from `msg.sender` to `dst`
     * @param dst The address of the destination account
     * @param amount The number of tokens to transfer
     * @return Whether or not the transfer succeeded
     */
    function transfer(address dst, uint256 amount) external override nonReentrant returns (bool) {
        return transferTokens(msg.sender, msg.sender, dst, amount) == 0;
    }

    /**
     * @notice Transfer `amount` tokens from `src` to `dst`
     * @param src The address of the source account
     * @param dst The address of the destination account
     * @param amount The number of tokens to transfer
     * @return Whether or not the transfer succeeded
     */
    function transferFrom(address src, address dst, uint256 amount) external override nonReentrant returns (bool) {
        return transferTokens(msg.sender, src, dst, amount) == 0;
    }

    /**
     * @notice Approve `spender` to transfer up to `amount` from `src`
     * @dev This will overwrite the approval amount for `spender`
     *  and is subject to issues noted [here](https://eips.ethereum.org/EIPS/eip-20#approve)
     * @param spender The address of the account which may transfer tokens
     * @param amount The number of tokens that are approved (-1 means infinite)
     * @return Whether or not the approval succeeded
     */
    function approve(address spender, uint256 amount) external override returns (bool) {
        address src = msg.sender;
        transferAllowances[src][spender] = amount;
        emit Approval(src, spender, amount);
        return true;
    }

    /**
     * @notice Get the current allowance from `owner` for `spender`
     * @param owner The address of the account which owns the tokens to be spent
     * @param spender The address of the account which may transfer tokens
     * @return The number of tokens allowed to be spent (-1 means infinite)
     */
    function allowance(address owner, address spender) external override view returns (uint256) {
        return transferAllowances[owner][spender];
    }

    /**
     * @notice Get the token balance of the `owner`
     * @param owner The address of the account to query
     * @return The number of tokens owned by `owner`
     */
    function balanceOf(address owner) external override view returns (uint256) {
        return accountTokens[owner];
    }

    function balanceOfUnderlying(address owner) external override returns (uint) {
        Exp memory exchangeRate = Exp({mantissa : exchangeRateCurrent()});
        (MathError mErr, uint balance) = mulScalarTruncate(exchangeRate, accountTokens[owner]);
        return balance;
    }

    /**
     * @notice Get a snapshot of the account's balances, and the cached exchange rate
     * @dev This is used by comptroller to more efficiently perform liquidity checks.
     * @param account Address of the account to snapshot
     * @return (possible error, token balance, borrow balance, exchange rate mantissa)
     */
    function getAccountSnapshot(address account) external override view returns (uint, uint, uint, uint) {
        uint pTokenBalance = accountTokens[account];
        uint borrowBalance = borrowBalanceStoredInternal(account);
        uint exchangeRateMantissa = exchangeRateStoredInternal();
        return (0, pTokenBalance, borrowBalance, exchangeRateMantissa);
    }

    /**
     * @dev Function to simply retrieve block number
     *  This exists mainly for inheriting test contracts to stub this result.
     */
    function getBlockNumber() internal view returns (uint) {
        return block.number;
    }

    /**
     * @notice Returns the current per-block borrow interest rate for this cToken
     * @return The borrow interest rate per block, scaled by 1e18
     */
    function borrowRatePerBlock() external override view returns (uint) {
        return interestRateModel.getBorrowRate(getCash(), totalBorrows, totalReserves);
    }

    /**
     * @notice Returns the current per-block supply interest rate for this cToken
     * @return The supply interest rate per block, scaled by 1e18
     */
    function supplyRatePerBlock() external override view returns (uint) {
        return interestRateModel.getSupplyRate(getCash(), totalBorrows, totalReserves, reserveFactorMantissa);
    }

    function totalBorrowsCurrent() external override nonReentrant returns (uint) {
        accrueInterest();
        return totalBorrows;
    }

    function borrowBalanceCurrent(address account) external override nonReentrant returns (uint) {
        accrueInterest();
        return borrowBalanceStored(account);
    }

    /**
     * @notice Return the borrow balance of account based on stored data
     * @param account The address whose balance should be calculated
     * @return The calculated balance
     */
    function borrowBalanceStored(address account) public override view returns (uint) {
        return borrowBalanceStoredInternal(account);
    }


    function borrowInterestBalancePriorInternal(address account) internal view returns (uint) {
        uint borrowBalance = borrowBalanceStoredInternal(account);
        uint interestAmountPrior = borrowBalance.sub(accountBorrows[account].principal);
        return interestAmountPrior;
    }

    /**
     * @notice Return the borrow balance of account based on stored data
     * @param account The address whose balance should be calculated
     * If borrowBalance = 0 then borrowIndex is likely also 0
     * Otherwise: recentBorrowBalance = borrower.borrowBalance * market.borrowIndex / borrower.borrowIndex
     * @return (the calculated balance or 0 if error code is non-zero)
     */
    function borrowBalanceStoredInternal(address account) internal view returns (uint) {
        BorrowSnapshot storage borrowSnapshot = accountBorrows[account];
        if (borrowSnapshot.principal == 0) {
            return 0;
        }
        uint principalTimesIndex = borrowSnapshot.principal.mul(borrowIndex);
        uint result = principalTimesIndex.div(borrowSnapshot.interestIndex);
        return result;
    }

    function exchangeRateCurrent() public override nonReentrant returns (uint) {
        accrueInterest();
        return exchangeRateStored();
    }

    /**
     * @notice Calculates the exchange rate from the underlying to the PToken
     * @dev This function does not accrue interest before calculating the exchange rate
     * @return Calculated exchange rate scaled by 1e18
     */
    function exchangeRateStored() public override view returns (uint) {
        return exchangeRateStoredInternal();
    }

    /**
     * @notice Calculates the exchange rate from the underlying to the CToken
     * If there are no tokens minted:  exchangeRate = initialExchangeRate
     * Otherwise:  exchangeRate = (totalCash + totalBorrows - totalReserves) / totalSupply
     * @dev This function does not accrue interest before calculating the exchange rate
     * @return (calculated exchange rate scaled by 1e18)
     */
    function exchangeRateStoredInternal() internal view returns (uint) {
        uint _totalSupply = totalSupply;
        if (_totalSupply == 0) {
            return initialExchangeRateMantissa;
        } else {
            uint totalCash = getCash();
            uint cashPlusBorrowsMinusReserves = totalCash.add(totalBorrows).sub(totalReserves);
            (MathError mathErr, Exp memory exchangeRate) = getExp(cashPlusBorrowsMinusReserves, _totalSupply);
            require(mathErr == MathError.NO_ERROR, "exchangeRateStoredInternal failed");
            return exchangeRate.mantissa;
        }
    }

    /**
     * @notice Get cash balance of this cToken in the underlying asset
     * @return The quantity of underlying asset owned by this contract
     */
    function getCash() public override view returns (uint) {
        return IEIP20(underlying).balanceOf(address(this));
    }

    /**
     * @notice Applies accrued interest to total borrows and reserves
     * @dev This calculates interest accrued from the last checkpointed block
     *   up to the current block and writes new checkpoint to storage.
     */
    function accrueInterest() public override returns (uint) {
        uint currentBlockNumber = getBlockNumber();
        uint accrualBlockNumberPrior = accrualBlockNumber;
        if (accrualBlockNumberPrior == currentBlockNumber) {
            return uint(Error.NO_ERROR);
        }

        uint cashPrior = getCash();
        uint borrowsPrior = totalBorrows;
        uint reservesPrior = totalReserves;
        uint borrowIndexPrior = borrowIndex;

        uint borrowRateMantissa = interestRateModel.getBorrowRate(cashPrior, borrowsPrior, reservesPrior);
        require(borrowRateMantissa <= borrowRateMaxMantissa, "borrow rate is absurdly high");

        uint blockDelta = currentBlockNumber.sub(accrualBlockNumberPrior);

        MathError mathErr;
        Exp memory simpleInterestFactor;
        uint interestAccumulated;
        uint totalBorrowsNew;
        uint totalReservesNew;
        uint borrowIndexNew;

        (mathErr, simpleInterestFactor) = mulScalar(Exp({mantissa : borrowRateMantissa}), blockDelta);
        if (mathErr != MathError.NO_ERROR) {
            return failOpaque(Error.MATH_ERROR, FailureInfo.ACCRUE_INTEREST_SIMPLE_INTEREST_FACTOR_CALCULATION_FAILED, uint(mathErr));
        }

        (mathErr, interestAccumulated) = mulScalarTruncate(simpleInterestFactor, borrowsPrior);
        if (mathErr != MathError.NO_ERROR) {
            return failOpaque(Error.MATH_ERROR, FailureInfo.ACCRUE_INTEREST_ACCUMULATED_INTEREST_CALCULATION_FAILED, uint(mathErr));
        }

        totalBorrowsNew = interestAccumulated.add(borrowsPrior);

        (mathErr, totalReservesNew) = mulScalarTruncateAddUInt(Exp({mantissa : reserveFactorMantissa}), interestAccumulated, reservesPrior);
        if (mathErr != MathError.NO_ERROR) {
            return failOpaque(Error.MATH_ERROR, FailureInfo.ACCRUE_INTEREST_NEW_TOTAL_RESERVES_CALCULATION_FAILED, uint(mathErr));
        }

        (mathErr, borrowIndexNew) = mulScalarTruncateAddUInt(simpleInterestFactor, borrowIndexPrior, borrowIndexPrior);
        if (mathErr != MathError.NO_ERROR) {
            return failOpaque(Error.MATH_ERROR, FailureInfo.ACCRUE_INTEREST_NEW_BORROW_INDEX_CALCULATION_FAILED, uint(mathErr));
        }

        accrualBlockNumber = currentBlockNumber;
        borrowIndex = borrowIndexNew;
        totalBorrows = totalBorrowsNew;
        totalReserves = totalReservesNew;

        emit AccrueInterest(cashPrior, interestAccumulated, borrowIndexNew, totalBorrowsNew, totalReservesNew);
        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Sender supplies assets into the market and receives cTokens in exchange
     * @dev Accrues interest whether or not the operation succeeds, unless reverted
     * @param mintAmount The amount of the underlying asset to supply
     * @return (uint, uint) An error code (0=success, otherwise a failure, see ErrorReporter.sol), and the actual mint amount.
     */
    function mint(uint mintAmount) external nonReentrant returns (uint) {
        uint err = accrueInterest();
        if (err != 0) {
            return fail(Error(err), FailureInfo.MINT_ACCRUE_INTEREST_FAILED);
        }
        return mintFresh(msg.sender, mintAmount);
    }

    struct MintLocalVars {
        Error err;
        MathError mathErr;
        uint exchangeRateMantissa;
        uint mintTokens;
        uint totalSupplyNew;
        uint accountTokensNew;
        uint actualMintAmount;
    }

    /**
     * @notice User supplies assets into the market and receives cTokens in exchange
     * @dev Assumes interest has already been accrued up to the current block
     * @param minter The address of the account which is supplying the assets
     * @param mintAmount The amount of the underlying asset to supply
     * @return (uint, uint) An error code (0=success, otherwise a failure, see ErrorReporter.sol), and the actual mint amount.
     */
    function mintFresh(address minter, uint mintAmount) internal returns (uint) {
        uint allowed = comptroller.mintAllowed(address(this), minter, mintAmount);
        if (allowed != 0) {
            return failOpaque(Error.COMPTROLLER_REJECTION, FailureInfo.MINT_COMPTROLLER_REJECTION, allowed);
        }
        if (accrualBlockNumber != getBlockNumber()) {
            return fail(Error.MARKET_NOT_FRESH, FailureInfo.MINT_FRESHNESS_CHECK);
        }

        MintLocalVars memory vars;
        vars.exchangeRateMantissa = exchangeRateStoredInternal();
        vars.actualMintAmount = doTransferIn(minter, mintAmount);
        (vars.mathErr, vars.mintTokens) = divScalarByExpTruncate(vars.actualMintAmount, Exp({mantissa : vars.exchangeRateMantissa}));
        require(vars.mathErr == MathError.NO_ERROR, "MINT_EXCHANGE_CALCULATION_FAILED");

        vars.totalSupplyNew = totalSupply.add(vars.mintTokens);
        vars.accountTokensNew = accountTokens[minter].add(vars.mintTokens);

        totalSupply = vars.totalSupplyNew;
        accountTokens[minter] = vars.accountTokensNew;
        emit Mint(minter, vars.actualMintAmount, vars.mintTokens, vars.totalSupplyNew, vars.accountTokensNew);
        emit Transfer(address(this), minter, vars.mintTokens);
        return 0;
    }

    /**
     * @notice Sender redeems cTokens in exchange for the underlying asset
     * @dev Accrues interest whether or not the operation succeeds, unless reverted
     * @param redeemTokens The number of cTokens to redeem into underlying
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function redeem(uint redeemTokens) external nonReentrant returns (uint) {
        uint err = accrueInterest();
        if (err != 0) {
            return fail(Error(err), FailureInfo.REDEEM_ACCRUE_INTEREST_FAILED);
        }
        return redeemFresh(msg.sender, redeemTokens, 0);
    }

    /**
     * @notice Sender redeems cTokens in exchange for a specified amount of underlying asset
     * @dev Accrues interest whether or not the operation succeeds, unless reverted
     * @param redeemAmount The amount of underlying to receive from redeeming cTokens
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function redeemUnderlying(uint redeemAmount) external nonReentrant returns (uint) {
        uint err = accrueInterest();
        if (err != 0) {
            return fail(Error(err), FailureInfo.REDEEM_ACCRUE_INTEREST_FAILED);
        }
        return redeemFresh(msg.sender, 0, redeemAmount);
    }

    struct RedeemLocalVars {
        Error err;
        MathError mathErr;
        uint exchangeRateMantissa;
        uint redeemTokens;
        uint redeemAmount;
        uint totalSupplyNew;
        uint accountTokensNew;
    }

    /**
     * @notice User redeems cTokens in exchange for the underlying asset
     * @dev Assumes interest has already been accrued up to the current block
     * @param redeemer The address of the account which is redeeming the tokens
     * @param redeemTokensIn The number of cTokens to redeem into underlying (only one of redeemTokensIn or redeemAmountIn may be non-zero)
     * @param redeemAmountIn The number of underlying tokens to receive from redeeming cTokens (only one of redeemTokensIn or redeemAmountIn may be non-zero)
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function redeemFresh(address payable redeemer, uint redeemTokensIn, uint redeemAmountIn) internal returns (uint) {
        RedeemLocalVars memory vars;
        vars.exchangeRateMantissa = exchangeRateStoredInternal();
        if (redeemTokensIn > 0) {
            vars.redeemTokens = redeemTokensIn;
            (vars.mathErr, vars.redeemAmount) = mulScalarTruncate(Exp({mantissa : vars.exchangeRateMantissa}), redeemTokensIn);
            if (vars.mathErr != MathError.NO_ERROR) {
                return failOpaque(Error.MATH_ERROR, FailureInfo.REDEEM_EXCHANGE_TOKENS_CALCULATION_FAILED, uint(vars.mathErr));
            }
        } else {
            (vars.mathErr, vars.redeemTokens) = divScalarByExpTruncate(redeemAmountIn, Exp({mantissa : vars.exchangeRateMantissa}));
            if (vars.mathErr != MathError.NO_ERROR) {
                return failOpaque(Error.MATH_ERROR, FailureInfo.REDEEM_EXCHANGE_AMOUNT_CALCULATION_FAILED, uint(vars.mathErr));
            }
            vars.redeemAmount = redeemAmountIn;
        }

        uint allowed = comptroller.redeemAllowed(address(this), redeemer, vars.redeemTokens);
        if (allowed != 0) {
            return failOpaque(Error.COMPTROLLER_REJECTION, FailureInfo.REDEEM_COMPTROLLER_REJECTION, allowed);
        }
        if (accrualBlockNumber != getBlockNumber()) {
            return fail(Error.MARKET_NOT_FRESH, FailureInfo.REDEEM_FRESHNESS_CHECK);
        }

        vars.totalSupplyNew = totalSupply.sub(vars.redeemTokens);
        vars.accountTokensNew = accountTokens[redeemer].sub(vars.redeemTokens);

        if (getCash() < vars.redeemAmount) {
            return fail(Error.TOKEN_INSUFFICIENT_CASH, FailureInfo.REDEEM_TRANSFER_OUT_NOT_POSSIBLE);
        }
        doTransferOut(redeemer, vars.redeemAmount);
        totalSupply = vars.totalSupplyNew;
        accountTokens[redeemer] = vars.accountTokensNew;
        emit Transfer(redeemer, address(this), vars.redeemTokens);
        emit Redeem(redeemer, vars.redeemAmount, vars.redeemTokens, vars.totalSupplyNew, vars.accountTokensNew);
        return 0;
    }

    /**
      * @notice Sender borrows assets from the protocol to their own address
      * @param borrowAmount The amount of the underlying asset to borrow
      * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
      */
    function borrow(uint borrowAmount) external nonReentrant returns (uint) {
        uint err = accrueInterest();
        if (err != 0) {
            return fail(Error(err), FailureInfo.BORROW_ACCRUE_INTEREST_FAILED);
        }
        return borrowFresh(msg.sender, borrowAmount);
    }

    struct BorrowLocalVars {
        MathError mathErr;
        uint accountBorrows;
        uint accountBorrowsNew;
        uint totalBorrowsNew;
        uint interestBalancePrior; //interest balance before now.
    }

    /**
      * @notice Users borrow assets from the protocol to their own address
      * @param borrowAmount The amount of the underlying asset to borrow
      * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
      */
    function borrowFresh(address payable borrower, uint borrowAmount) internal returns (uint) {
        uint allowed = comptroller.borrowAllowed(address(this), borrower, borrowAmount);
        if (allowed != 0) {
            return failOpaque(Error.COMPTROLLER_REJECTION, FailureInfo.BORROW_COMPTROLLER_REJECTION, allowed);
        }
        if (accrualBlockNumber != getBlockNumber()) {
            return fail(Error.MARKET_NOT_FRESH, FailureInfo.BORROW_FRESHNESS_CHECK);
        }
        if (getCash() < borrowAmount) {
            return fail(Error.TOKEN_INSUFFICIENT_CASH, FailureInfo.BORROW_CASH_NOT_AVAILABLE);
        }

        BorrowLocalVars memory vars;
        vars.interestBalancePrior = borrowInterestBalancePriorInternal(borrower);
        vars.accountBorrows = borrowBalanceStoredInternal(borrower);
        vars.accountBorrowsNew = vars.accountBorrows.add(borrowAmount);
        vars.totalBorrowsNew = totalBorrows.add(borrowAmount);

        doTransferOut(borrower, borrowAmount);

        accountBorrows[borrower].principal = vars.accountBorrowsNew;
        accountBorrows[borrower].interestIndex = borrowIndex;
        totalBorrows = vars.totalBorrowsNew;
        emit Borrow(borrower, borrowAmount, vars.accountBorrowsNew, vars.totalBorrowsNew, vars.interestBalancePrior);
        return 0;
    }

    /**
     * @notice Sender repays their own borrow
     * @param repayAmount The amount to repay
     * @return (uint, uint) An error code (0=success, otherwise a failure, see ErrorReporter.sol), and the actual repayment amount.
     */
    function repayBorrow(uint repayAmount) external nonReentrant returns (uint) {
        uint err = accrueInterest();
        if (err != 0) {
            return fail(Error(err), FailureInfo.REPAY_BORROW_ACCRUE_INTEREST_FAILED);
        }
        (err,) = repayBorrowFresh(msg.sender, msg.sender, repayAmount);
        return err;
    }

    /**
     * @notice Sender repays a borrow belonging to borrower
     * @param borrower the account with the debt being payed off
     * @param repayAmount The amount to repay
     * @return (uint, uint) An error code (0=success, otherwise a failure, see ErrorReporter.sol), and the actual repayment amount.
     */
    function repayBorrowBehalf(address borrower, uint repayAmount) external nonReentrant returns (uint) {
        uint err = accrueInterest();
        if (err != 0) {
            return fail(Error(err), FailureInfo.REPAY_BEHALF_ACCRUE_INTEREST_FAILED);
        }
        (err,) = repayBorrowFresh(msg.sender, borrower, repayAmount);
        return err;
    }

    struct RepayBorrowLocalVars {
        Error err;
        MathError mathErr;
        uint repayAmount;
        uint borrowerIndex;
        uint accountBorrows;
        uint accountBorrowsNew;
        uint totalBorrowsNew;
        uint actualRepayAmount;
        uint interestBalancePrior;
    }

    /**
     * @notice Borrows are repaid by another user (possibly the borrower).
     * @param payer the account paying off the borrow
     * @param borrower the account with the debt being payed off
     * @param repayAmount the amount of undelrying tokens being returned
     * @return (uint, uint) An error code (0=success, otherwise a failure, see ErrorReporter.sol), and the actual repayment amount.
     */
    function repayBorrowFresh(address payer, address borrower, uint repayAmount) internal returns (uint, uint) {
        uint allowed = comptroller.repayBorrowAllowed(address(this), payer, borrower, repayAmount);
        if (allowed != 0) {
            return (failOpaque(Error.COMPTROLLER_REJECTION, FailureInfo.REPAY_BORROW_COMPTROLLER_REJECTION, allowed), 0);
        }
        if (accrualBlockNumber != getBlockNumber()) {
            return (fail(Error.MARKET_NOT_FRESH, FailureInfo.REPAY_BORROW_FRESHNESS_CHECK), 0);
        }
        RepayBorrowLocalVars memory vars;
        vars.borrowerIndex = accountBorrows[borrower].interestIndex;
        vars.interestBalancePrior = borrowInterestBalancePriorInternal(borrower);
        vars.accountBorrows = borrowBalanceStoredInternal(borrower);

        if (repayAmount == uint(- 1)) {
            vars.repayAmount = vars.accountBorrows;
        } else {
            vars.repayAmount = repayAmount;
        }
        vars.actualRepayAmount = doTransferIn(payer, vars.repayAmount);

        vars.accountBorrowsNew = vars.accountBorrows.sub(vars.actualRepayAmount);
        vars.totalBorrowsNew = totalBorrows.sub(vars.actualRepayAmount);

        accountBorrows[borrower].principal = vars.accountBorrowsNew;
        accountBorrows[borrower].interestIndex = borrowIndex;
        totalBorrows = vars.totalBorrowsNew;
        emit RepayBorrow(payer, borrower, vars.actualRepayAmount, vars.accountBorrowsNew, vars.totalBorrowsNew, vars.interestBalancePrior);
        return (0, vars.actualRepayAmount);
    }

    /**
     * @notice The sender liquidates the borrowers collateral.
     *  The collateral seized is transferred to the liquidator.
     * @param borrower The borrower of this cToken to be liquidated
     * @param pTokenCollateral The market in which to seize collateral from the borrower
     * @param repayAmount The amount of the underlying borrowed asset to repay
     * @return (uint, uint) An error code (0=success, otherwise a failure, see ErrorReporter.sol), and the actual repayment amount.
     */
    function liquidateBorrow(address borrower, uint repayAmount, IPToken pTokenCollateral) external nonReentrant returns (uint) {
        uint err = accrueInterest();
        if (err != 0) {
            return fail(Error(err), FailureInfo.LIQUIDATE_ACCRUE_BORROW_INTEREST_FAILED);
        }
        err = pTokenCollateral.accrueInterest();
        if (err != 0) {
            return fail(Error(err), FailureInfo.LIQUIDATE_ACCRUE_COLLATERAL_INTEREST_FAILED);
        }
        return liquidateBorrowFresh(msg.sender, borrower, repayAmount, pTokenCollateral);
    }

    /**
     * @notice The liquidator liquidates the borrowers collateral.
     *  The collateral seized is transferred to the liquidator.
     * @param borrower The borrower of this cToken to be liquidated
     * @param liquidator The address repaying the borrow and seizing collateral
     * @param pTokenCollateral The market in which to seize collateral from the borrower
     * @param repayAmount The amount of the underlying borrowed asset to repay
     * @return (uint) An error code (0=success, otherwise a failure, see ErrorReporter.sol)
     */
    function liquidateBorrowFresh(address liquidator, address borrower, uint repayAmount, IPToken pTokenCollateral) internal returns (uint) {
        uint allowed = comptroller.liquidateBorrowAllowed(address(this), address(pTokenCollateral), liquidator, borrower, repayAmount);
        if (allowed != 0) {
            return failOpaque(Error.COMPTROLLER_REJECTION, FailureInfo.LIQUIDATE_COMPTROLLER_REJECTION, allowed);
        }
        if (accrualBlockNumber != getBlockNumber()) {
            return fail(Error.MARKET_NOT_FRESH, FailureInfo.LIQUIDATE_FRESHNESS_CHECK);
        }
        if (pTokenCollateral.accrualBlockNumber() != getBlockNumber()) {
            return fail(Error.MARKET_NOT_FRESH, FailureInfo.LIQUIDATE_COLLATERAL_FRESHNESS_CHECK);
        }
        if (borrower == liquidator) {
            return fail(Error.INVALID_ACCOUNT_PAIR, FailureInfo.LIQUIDATE_LIQUIDATOR_IS_BORROWER);
        }
        if (repayAmount == 0) {
            return fail(Error.INVALID_CLOSE_AMOUNT_REQUESTED, FailureInfo.LIQUIDATE_CLOSE_AMOUNT_IS_ZERO);
        }
        if (repayAmount == uint(- 1)) {
            return fail(Error.INVALID_CLOSE_AMOUNT_REQUESTED, FailureInfo.LIQUIDATE_CLOSE_AMOUNT_IS_UINT_MAX);
        }
        (uint repayBorrowError, uint actualRepayAmount) = repayBorrowFresh(liquidator, borrower, repayAmount);
        if (repayBorrowError != uint(Error.NO_ERROR)) {
            return fail(Error(repayBorrowError), FailureInfo.LIQUIDATE_REPAY_BORROW_FRESH_FAILED);
        }
        (uint amountSeizeError, uint seizeTokens) = comptroller.liquidateCalculateSeizeTokens(address(this), address(pTokenCollateral), actualRepayAmount);
        require(amountSeizeError == uint(Error.NO_ERROR), "LIQUIDATE_COMPTROLLER_CALCULATE_AMOUNT_SEIZE_FAILED");
        require(pTokenCollateral.balanceOf(borrower) >= seizeTokens, "LIQUIDATE_SEIZE_TOO_MUCH");
        uint seizeError;
        if (address(pTokenCollateral) == address(this)) {
            seizeError = seizeInternal(address(this), liquidator, borrower, seizeTokens);
        } else {
            seizeError = pTokenCollateral.seize(liquidator, borrower, seizeTokens);
        }
        require(seizeError == uint(Error.NO_ERROR), "token seizure failed");
        emit LiquidateBorrow(liquidator, borrower, actualRepayAmount, address(pTokenCollateral), seizeTokens);
        return 0;
    }

    /**
     * @notice Transfers collateral tokens (this market) to the liquidator.
     * @dev Will fail unless called by another cToken during the process of liquidation.
     *  Its absolutely critical to use msg.sender as the borrowed cToken and not a parameter.
     * @param liquidator The account receiving seized collateral
     * @param borrower The account having collateral seized
     * @param seizeTokens The number of cTokens to seize
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function seize(address liquidator, address borrower, uint seizeTokens) external override nonReentrant returns (uint) {
        return seizeInternal(msg.sender, liquidator, borrower, seizeTokens);
    }

    /**
     * @notice Transfers collateral tokens (this market) to the liquidator.
     * @dev Called only during an in-kind liquidation, or by liquidateBorrow during the liquidation of another PToken.
     *  Its absolutely critical to use msg.sender as the seizer cToken and not a parameter.
     * @param seizerToken The contract seizing the collateral (i.e. borrowed cToken)
     * @param liquidator The account receiving seized collateral
     * @param borrower The account having collateral seized
     * @param seizeTokens The number of cTokens to seize
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function seizeInternal(address seizerToken, address liquidator, address borrower, uint seizeTokens) internal returns (uint) {
        uint allowed = comptroller.seizeAllowed(address(this), seizerToken, liquidator, borrower, seizeTokens);
        if (allowed != 0) {
            return failOpaque(Error.COMPTROLLER_REJECTION, FailureInfo.LIQUIDATE_SEIZE_COMPTROLLER_REJECTION, allowed);
        }
        if (borrower == liquidator) {
            return fail(Error.INVALID_ACCOUNT_PAIR, FailureInfo.LIQUIDATE_SEIZE_LIQUIDATOR_IS_BORROWER);
        }
        MathError mathErr;
        uint borrowerTokensNew = accountTokens[borrower].sub(seizeTokens);
        uint liquidatorTokensNew = accountTokens[liquidator].add(seizeTokens);
        accountTokens[borrower] = borrowerTokensNew;
        accountTokens[liquidator] = liquidatorTokensNew;
        emit Transfer(borrower, liquidator, seizeTokens);
        return 0;
    }



    /*** Admin Functions ***/

    /**
      * @notice accrues interest and sets a new reserve factor for the protocol using _setReserveFactorFresh
      * @dev Admin function to accrue interest and set a new reserve factor
      * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
      */
    function _setReserveFactor(uint newReserveFactorMantissa) external onlyOwner override nonReentrant returns (uint) {
        uint err = accrueInterest();
        if (err != 0) {
            return fail(Error(err), FailureInfo.SET_RESERVE_FACTOR_ACCRUE_INTEREST_FAILED);
        }
        if (accrualBlockNumber != getBlockNumber()) {
            return fail(Error.MARKET_NOT_FRESH, FailureInfo.SET_RESERVE_FACTOR_FRESH_CHECK);
        }
        if (newReserveFactorMantissa > reserveFactorMaxMantissa) {
            return fail(Error.BAD_INPUT, FailureInfo.SET_RESERVE_FACTOR_BOUNDS_CHECK);
        }
        reserveFactorMantissa = newReserveFactorMantissa;
        return 0;
    }

    /**
     * @notice Accrues interest and reduces reserves by transferring from msg.sender
     * @param addAmount Amount of addition to reserves
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function _addReserves(uint addAmount) external nonReentrant returns (uint) {
        uint error = accrueInterest();
        if (error != 0) {
            return fail(Error(error), FailureInfo.ADD_RESERVES_ACCRUE_INTEREST_FAILED);
        }
        if (accrualBlockNumber != getBlockNumber()) {
            return fail(Error.MARKET_NOT_FRESH, FailureInfo.ADD_RESERVES_FRESH_CHECK);
        }
        uint actualAddAmount = doTransferIn(msg.sender, addAmount);
        uint totalReservesNew = totalReserves + actualAddAmount;
        require(totalReservesNew >= totalReserves, "addAmount error");
        totalReserves = totalReservesNew;
        emit ReservesAdded(msg.sender, actualAddAmount, totalReservesNew);
        return 0;
    }

    /**
     * @notice Accrues interest and reduces reserves by transferring to admin
     * @param reduceAmount Amount of reduction to reserves
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function _reduceReserves(uint reduceAmount) external override nonReentrant returns (uint) {
        uint error = accrueInterest();
        if (error != 0) {
            return fail(Error(error), FailureInfo.REDUCE_RESERVES_ACCRUE_INTEREST_FAILED);
        }
        if (accrualBlockNumber != getBlockNumber()) {
            return fail(Error.MARKET_NOT_FRESH, FailureInfo.REDUCE_RESERVES_FRESH_CHECK);
        }
        if (getCash() < reduceAmount) {
            return fail(Error.TOKEN_INSUFFICIENT_CASH, FailureInfo.REDUCE_RESERVES_CASH_NOT_AVAILABLE);
        }
        if (reduceAmount > totalReserves) {
            return fail(Error.BAD_INPUT, FailureInfo.REDUCE_RESERVES_VALIDATION);
        }
        uint totalReservesNew = totalReserves - reduceAmount;
        require(totalReservesNew <= totalReserves, "reduceAmount error");
        totalReserves = totalReservesNew;
        doTransferOut(payable(owner()), reduceAmount);
        emit ReservesReduced(owner(), reduceAmount, totalReservesNew);
        return 0;
    }

    /**
     * @notice accrues interest and updates the interest rate model using _setInterestRateModelFresh
     * @dev Admin function to accrue interest and update the interest rate model
     * @param _interestRateModel the new interest rate model to use
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function _setInterestRateModel(IInterestRateModel _interestRateModel) public onlyOwner override returns (uint) {
        if (interestRateModel != IInterestRateModel(0)) {
            accrueInterest();
        }
        interestRateModel = _interestRateModel;
        return 0;
    }

    /**
    * @notice Sets a new comptroller for the market
    * @dev Admin function to set a new comptroller
    * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
    */
    function _setComptroller(IComptroller _comptroller) public onlyOwner override returns (uint) {
        comptroller = _comptroller;
        return 0;
    }

    /*** Safe Token ***/

    /**
     * @dev Similar to EIP20 transfer, except it handles a False result from `transferFrom` and reverts in that case.
     *      This will revert due to insufficient balance or insufficient allowance.
     *      This function returns the actual amount received,
     *      which may be less than `amount` if there is a fee attached to the transfer.
     *
     *      Note: This wrapper safely handles non-standard ERC-20 tokens that do not return a value.
     *            See here: https://medium.com/coinmonks/missing-return-value-bug-at-least-130-tokens-affected-d67bf08521ca
     */
    function doTransferIn(address from, uint amount) internal returns (uint) {
        IEIP20 token = IEIP20(underlying);
        uint balanceBefore = token.balanceOf(address(this));
        token.transferFrom(from, address(this), amount);
        bool success;
        assembly {
            switch returndatasize()
            case 0 {
                success := not(0)
            }
            case 32 {
                returndatacopy(0, 0, 32)
                success := mload(0)
            }
            default {
                revert(0, 0)
            }
        }
        require(success, "TOKEN_TRANSFER_IN_FAILED");
        uint balanceAfter = token.balanceOf(address(this));
        require(balanceAfter >= balanceBefore, "TOKEN_TRANSFER_IN_OVERFLOW");
        return balanceAfter - balanceBefore;
    }

    /**
     * @dev Similar to EIP20 transfer, except it handles a False success from `transfer` and returns an explanatory
     *      error code rather than reverting. If caller has not called checked protocol's balance, this may revert due to
     *      insufficient cash held in this contract. If caller has checked protocol's balance prior to this call, and verified
     *      it is >= amount, this should not revert in normal conditions.
     *
     *      Note: This wrapper safely handles non-standard ERC-20 tokens that do not return a value.
     *            See here: https://medium.com/coinmonks/missing-return-value-bug-at-least-130-tokens-affected-d67bf08521ca
     */
    function doTransferOut(address payable to, uint amount) internal {
        IEIP20 token = IEIP20(underlying);
        token.transfer(to, amount);
        bool success;
        assembly {
            switch returndatasize()
            case 0 {
                success := not(0)
            }
            case 32 {
                returndatacopy(0, 0, 32)
                success := mload(0)
            }
            default {
                revert(0, 0)
            }
        }
        require(success, "TOKEN_TRANSFER_OUT_FAILED");
    }


    /*** Reentrancy Guard ***/

    /**
     * @dev Prevents a contract from calling itself, directly or indirectly.
     */
    modifier nonReentrant() {
        require(_notEntered, "re-entered");
        _notEntered = false;
        _;
        _notEntered = true;
    }
}
