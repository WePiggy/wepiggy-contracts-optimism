pragma solidity 0.6.12;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IPiggyBreeder {
    function stake(uint256 _pid, uint256 _amount) external;

    function unStake(uint256 _pid, uint256 _amount) external;

    function claim(uint256 _pid) external;

    function emergencyWithdraw(uint256 _pid) external;
}

//对侧链的资金管理
contract MainnetFundingManager is Ownable {

    using SafeMath for uint256;

    string public name;
    IERC20 public piggy;
    IPiggyBreeder public piggyBreeder;

    uint public totalUnLockedAmount;
    mapping(address => uint) public unLocked;
    uint public totalLockedAmount;
    mapping(address => uint) public locked;

    event StakeTokenToPiggyBreeder(IERC20 token, uint pid, uint amount);
    event ClaimWpcFromPiggyBreeder(uint pid);
    event UnLocked(address user, uint unLockedAmount, uint allUnLockedAmount);
    event Locked(address user, uint lockedAmount, uint allLockedAmount);
    event OnChangeSuccess(address user, uint lockedAmount, uint allLockedAmount);

    constructor(string memory _name, IPiggyBreeder _piggyBreeder, IERC20 _piggy) public {
        name = _name;
        piggyBreeder = _piggyBreeder;
        piggy = _piggy;
    }

    // 抵押 MOCK ERC20 代币到PiggyBreeder
    function _stakeTokenToPiggyBreeder(IERC20 token, uint pid) public onlyOwner {
        uint amount = token.balanceOf(address(this));
        token.approve(address(piggyBreeder), amount);
        piggyBreeder.stake(pid, amount);
        emit StakeTokenToPiggyBreeder(token, pid, amount);
    }

    // 从PiggyBreeder领取WPC
    function _claimWpcFromPiggyBreeder(uint pid) public onlyOwner {

        uint _beforeBalance = piggy.balanceOf(address(this));
        piggyBreeder.claim(pid);
        uint _afterBalance = piggy.balanceOf(address(this));

        emit ClaimWpcFromPiggyBreeder(pid);
    }

    //解锁。为了从 侧链->主网
    //在给用户转账前，先调用此方法解锁。为了方便中心化服务比较 侧链上合约的用户锁定金额 与 此合约的解锁金额
    function _changeFromSidechainToMainnet(uint256 _amount) public {

        address _user = msg.sender;

        uint balance = piggy.balanceOf(address(this));
        require(balance >= _amount, "balance must bigger than _amount");
        require(balance >= totalUnLockedAmount.add(_amount), "balance must bigger than totalUnLockedAmount");

        unLocked[_user] = unLocked[_user].add(_amount);
        totalUnLockedAmount = totalUnLockedAmount.add(_amount);

        emit UnLocked(_user, _amount, unLocked[_user]);
    }


    // transfer WPC 给用户
    // 只能转解锁的金额。在转账前会有中心化应用判断金额
    function _transfer(address _user, uint256 _amount) public onlyOwner {

        uint unLockAmount = unLocked[_user];
        require(unLockAmount >= _amount, "unLockAmount must bigger than _amount");

        //先扣除unLockedAmount，然后再进行转账
        unLocked[_user] = unLockAmount.sub(_amount);
        totalUnLockedAmount = totalUnLockedAmount.sub(_amount);

        piggy.transfer(_user, _amount);
    }

    //锁定。为了从 主网->侧链
    function _changeFromMainnetToSidechain(uint256 _amount) public {

        address _user = msg.sender;

        //将代币转到此合约
        piggy.transferFrom(_user, address(this), _amount);

        //记录锁定的值
        locked[_user] = locked[_user].add(_amount);
        totalLockedAmount = totalLockedAmount.add(_amount);

        emit Locked(_user, _amount, locked[_user]);
    }

    // 当侧链上转账成功以后，调用此方法。
    function _onChangeSuccess(address _user, uint256 _amount) public onlyOwner {

        locked[_user] = locked[_user].sub(_amount);
        totalLockedAmount = totalLockedAmount.sub(_amount);

        emit OnChangeSuccess(_user, _amount, locked[_user]);

    }


    function transfer(address _to, uint256 _amount) public onlyOwner {
        uint256 piggyBal = piggy.balanceOf(address(this));
        if (_amount > piggyBal) {
            piggy.transfer(_to, piggyBal);
        } else {
            piggy.transfer(_to, _amount);
        }
    }

}
