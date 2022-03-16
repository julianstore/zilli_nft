pragma solidity =0.8.0;
pragma experimental ABIEncoderV2;

import '@openzeppelin/contracts/utils/math/SafeMath.sol';
import '@openzeppelin/contracts/utils/math/Math.sol';
import '@openzeppelin/contracts/access/Ownable.sol';
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import '@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol';
import '@openzeppelin/contracts/security/Pausable.sol';
import '@openzeppelin/contracts/utils/structs/EnumerableSet.sol';
import './ZilionixxStakingPowerToken.sol';
import './ZilionixxNFT.sol';
import './libraries/QuickSortUtils.sol';
import './libraries/RandomGenUtils.sol';
import './interfaces/IZilionixxMaster.sol';

contract ZilionixxNFTMaster is ERC721Holder, Ownable, Pausable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;
    using Address for address;
    using EnumerableSet for EnumerableSet.UintSet;

    // Info of each user.
    struct UserInfo {
        uint256 amount;
        uint256 rewardDebt;
    }

    struct ZilionixxNFTInfo {
        uint256 level;
        uint256 stakingPowerMultiple;
        uint256 bakeAmount;
        uint256 stakingPowerAmount;
    }
    uint256 accBakePerShare; // Accumulated BAKEs per share, times 1e12. See below.
    uint256 public constant accBakePerShareMultiple = 1E12;
    uint256 public lastRewardBlock;
    // total has deposit to ZilionixxMaster stakingPower
    uint256 public totalStakingPower;
    // start from 1, not zero tokenId, zero for using harvest
    uint256 public mintNFTCount = 1;
    uint256 private _fee = 10;
    address public feeAddr; // fee address.
    address public grimexToken;
    address public zilionixxStakingPowerToken;
    ZilionixxNFT public ZilionixxNFT;
    IZilionixxMaster public zilionixxMaster;
    mapping(address => UserInfo) private _userInfoMap;
    mapping(address => EnumerableSet.UintSet) private _stakingTokens;
    mapping(uint256 => ZilionixxNFTInfo) public ZilionixxNFTInfoMap;
    mapping(uint256 => uint256[]) public nftItemsMap;

    event Synthesis(address indexed user, uint256 indexed tokenId, uint256 amount);
    event Decomposition(address indexed user, uint256 indexed tokenId, uint256 amount);
    event FeeAddressTransferred(address indexed previousOwner, address indexed newOwner);
    event Stake(address indexed user, uint256 indexed tokenId, uint256 amount);
    event Unstake(address indexed user, uint256 indexed tokenId, uint256 amount);
    event EmergencyUnstake(address indexed user, uint256 indexed tokenId, uint256 amount);
    event EmergencyUnstakeAll(address indexed user);
    event UpdateFee(address indexed user, uint256 indexed oldFee, uint256 newFee);

    constructor(
        address _zilionixxStakingPowerToken,
        address _grimexToken,
        address _ZilionixxNFT,
        address _zilionixxMaster,
        address _feeAddr
    ) public {
        zilionixxStakingPowerToken = _zilionixxStakingPowerToken;
        grimexToken = _grimexToken;
        ZilionixxNFT = ZilionixxNFT(_ZilionixxNFT);
        zilionixxMaster = IZilionixxMaster(_zilionixxMaster);
        feeAddr = _feeAddr;
        emit FeeAddressTransferred(address(0), feeAddr);
    }

    function approveZilionixxMasterForSpendStakingPowerToken() public {
        IERC20(zilionixxStakingPowerToken).approve(address(zilionixxMaster), 2**256 - 1);
    }

    function nextSeed(uint256 seed) private pure returns (uint256) {
        return seed.sub(12345678901234);
    }

    function synthesis(uint256 _amount) public {
        require(_amount >= 1E22, 'ZilionixxNFTMaster: synthesis, amount too small');
        uint256 feeAmount = _amount.mul(_fee).div(100);
        uint256 amount = _amount.sub(feeAmount);
        IERC20(grimexToken).safeTransferFrom(address(msg.sender), feeAddr, feeAmount);
        IERC20(grimexToken).safeTransferFrom(address(msg.sender), address(this), amount);

        uint256 currentSeed = _amount;
        uint256 level = 0;
        if (_amount >= 2E22 && _amount < 5E22) {
            level = 1;
        } else if (_amount >= 5E22 && _amount < 10E22) {
            level = 2;
        } else if (_amount >= 10E22) {
            level = 3;
        }
        uint256 maxItems = level + 3;
        uint256[] memory tempItems = new uint256[](maxItems);
        for (uint256 i = 0; i < maxItems; ++i) {
            tempItems[i] = RandomGenUtils.randomGen(currentSeed, 400000);
            currentSeed = nextSeed(currentSeed);
        }
        nftItemsMap[mintNFTCount] = tempItems;
        uint256 stakingPowerMultiple = QuickSortUtils.sort(tempItems)[maxItems - 3].add(100000);
        uint256 stakingPowerAmount = _amount.mul(stakingPowerMultiple).div(100000);
        ZilionixxNFTInfoMap[mintNFTCount] = ZilionixxNFTInfo({
            level: level,
            stakingPowerMultiple: stakingPowerMultiple,
            stakingPowerAmount: stakingPowerAmount,
            bakeAmount: amount
        });
        ZilionixxNFT.mint(address(msg.sender), mintNFTCount);
        ZilionixxStakingPowerToken(zilionixxStakingPowerToken).mint(address(this), stakingPowerAmount);
        emit Synthesis(msg.sender, mintNFTCount, _amount);
        mintNFTCount++;
    }

    function decomposition(uint256 tokenId) public {
        require(
            ZilionixxNFT.ownerOf(tokenId) == msg.sender,
            'ZilionixxNFTMaster: decomposition, caller is not the owner'
        );
        ZilionixxNFTInfo storage dishInfo = ZilionixxNFTInfoMap[tokenId];
        IERC20(grimexToken).safeTransfer(address(msg.sender), dishInfo.bakeAmount);
        ZilionixxStakingPowerToken(zilionixxStakingPowerToken).burn(dishInfo.stakingPowerAmount);
        ZilionixxNFT.burn(tokenId);
        emit Decomposition(msg.sender, tokenId, dishInfo.bakeAmount);
        delete ZilionixxNFTInfoMap[tokenId];
    }

    // View function to see pending BAKEs on frontend.
    function pendingBake(address _user) external view returns (uint256) {
        UserInfo memory userInfo = _userInfoMap[_user];
        uint256 _accBakePerShare = accBakePerShare;
        if (totalStakingPower != 0) {
            uint256 totalPendingBake = zilionixxMaster.pendingBake(zilionixxStakingPowerToken, address(this));
            _accBakePerShare = _accBakePerShare.add(
                totalPendingBake.mul(accBakePerShareMultiple).div(totalStakingPower)
            );
        }
        return userInfo.amount.mul(_accBakePerShare).div(accBakePerShareMultiple).sub(userInfo.rewardDebt);
    }

    function updateStaking() public {
        if (block.number <= lastRewardBlock) {
            return;
        }
        if (totalStakingPower == 0) {
            lastRewardBlock = block.number;
            return;
        }
        (, uint256 lastRewardDebt) = zilionixxMaster.poolUserInfoMap(zilionixxStakingPowerToken, address(this));
        zilionixxMaster.deposit(zilionixxStakingPowerToken, 0);
        (, uint256 newRewardDebt) = zilionixxMaster.poolUserInfoMap(zilionixxStakingPowerToken, address(this));
        accBakePerShare = accBakePerShare.add(
            newRewardDebt.sub(lastRewardDebt).mul(accBakePerShareMultiple).div(totalStakingPower)
        );
        lastRewardBlock = block.number;
    }

    function stake(uint256 tokenId) public whenNotPaused {
        UserInfo storage userInfo = _userInfoMap[msg.sender];
        ZilionixxNFTInfo memory dishInfo = ZilionixxNFTInfoMap[tokenId];
        updateStaking();
        if (userInfo.amount != 0) {
            uint256 pending = userInfo.amount.mul(accBakePerShare).div(accBakePerShareMultiple).sub(
                userInfo.rewardDebt
            );
            if (pending != 0) {
                safeBakeTransfer(msg.sender, pending);
            }
        }
        if (tokenId != 0) {
            ZilionixxNFT.safeTransferFrom(address(msg.sender), address(this), tokenId);
            userInfo.amount = userInfo.amount.add(dishInfo.stakingPowerAmount);
            _stakingTokens[msg.sender].add(tokenId);
            zilionixxMaster.deposit(zilionixxStakingPowerToken, dishInfo.stakingPowerAmount);
            totalStakingPower = totalStakingPower.add(dishInfo.stakingPowerAmount);
        }
        userInfo.rewardDebt = userInfo.amount.mul(accBakePerShare).div(accBakePerShareMultiple);
        if (tokenId != 0) {
            emit Stake(msg.sender, tokenId, dishInfo.stakingPowerAmount);
        }
    }

    function unstake(uint256 tokenId) public {
        require(_stakingTokens[msg.sender].contains(tokenId), 'ZilionixxNFTMaster: UNSTAKE FORBIDDEN');
        UserInfo storage userInfo = _userInfoMap[msg.sender];
        ZilionixxNFTInfo memory dishInfo = ZilionixxNFTInfoMap[tokenId];
        updateStaking();
        uint256 pending = userInfo.amount.mul(accBakePerShare).div(accBakePerShareMultiple).sub(userInfo.rewardDebt);
        if (pending != 0) {
            safeBakeTransfer(msg.sender, pending);
        }
        userInfo.amount = userInfo.amount.sub(dishInfo.stakingPowerAmount);
        _stakingTokens[msg.sender].remove(tokenId);
        ZilionixxNFT.safeTransferFrom(address(this), address(msg.sender), tokenId);
        zilionixxMaster.withdraw(zilionixxStakingPowerToken, dishInfo.stakingPowerAmount);
        totalStakingPower = totalStakingPower.sub(dishInfo.stakingPowerAmount);
        userInfo.rewardDebt = userInfo.amount.mul(accBakePerShare).div(accBakePerShareMultiple);
        emit Unstake(msg.sender, tokenId, dishInfo.stakingPowerAmount);
    }

    function unstakeAll() public {
        EnumerableSet.UintSet storage stakingTokens = _stakingTokens[msg.sender];
        uint256 length = stakingTokens.length();
        for (uint256 i = 0; i < length; ++i) {
            unstake(stakingTokens.at(0));
        }
    }

    function pauseStake() public onlyOwner whenNotPaused {
        _pause();
    }

    function unpauseStake() public onlyOwner whenPaused {
        _unpause();
    }

    function updateFee(uint256 fee) public onlyOwner {
        emit UpdateFee(msg.sender, _fee, fee);
        _fee = fee;
    }

    function emergencyUnstakeAll() public onlyOwner whenPaused {
        zilionixxMaster.emergencyWithdraw(zilionixxStakingPowerToken);
        emit EmergencyUnstakeAll(msg.sender);
    }

    function emergencyUnstake(uint256 tokenId) public {
        require(_stakingTokens[msg.sender].contains(tokenId), 'ZilionixxNFTMaster: EMERGENCY UNSTAKE FORBIDDEN');
        UserInfo storage userInfo = _userInfoMap[msg.sender];
        ZilionixxNFTInfo memory dishInfo = ZilionixxNFTInfoMap[tokenId];
        userInfo.amount = userInfo.amount.sub(dishInfo.stakingPowerAmount);
        _stakingTokens[msg.sender].remove(tokenId);
        ZilionixxNFT.safeTransferFrom(address(this), address(msg.sender), tokenId);
        totalStakingPower = totalStakingPower.sub(dishInfo.stakingPowerAmount);
        userInfo.rewardDebt = userInfo.amount.mul(accBakePerShare).div(accBakePerShareMultiple);
        emit EmergencyUnstake(msg.sender, tokenId, dishInfo.stakingPowerAmount);
    }

    function safeBakeTransfer(address _to, uint256 _amount) internal {
        uint256 bakeBal = IERC20(grimexToken).balanceOf(address(this));
        if (_amount > bakeBal) {
            IERC20(grimexToken).transfer(_to, bakeBal);
        } else {
            IERC20(grimexToken).transfer(_to, _amount);
        }
    }

    function setFeeAddr(address _feeAddr) external {
        require(msg.sender == feeAddr, 'ZilionixxNFTMaster: FORBIDDEN');
        feeAddr = _feeAddr;
        emit FeeAddressTransferred(msg.sender, feeAddr);
    }

    function getUserInfo(address user)
        public
        view
        returns (
            uint256,
            uint256,
            uint256
        )
    {
        UserInfo memory userInfo = _userInfoMap[user];
        return (userInfo.amount, userInfo.rewardDebt, _stakingTokens[user].length());
    }

    function getDishInfo(uint256 tokenId) public view returns (ZilionixxNFTInfo memory, uint256[] memory) {
        return (ZilionixxNFTInfoMap[tokenId], nftItemsMap[tokenId]);
    }

    function tokenOfStakerByIndex(address staker, uint256 index) public view returns (uint256) {
        return _stakingTokens[staker].at(index);
    }
}
