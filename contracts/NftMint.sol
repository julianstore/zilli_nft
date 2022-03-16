// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;
import './ZilionixxNFT.sol';

interface INFTMint {
    event StandardTokenCreated(address tokenAddress);

    function setFeeTo(address payable) external;

    function setFeeToSetter(address payable) external;

    function setFeeAmount(uint256) external;
}

contract NFTMint is INFTMint {
    address payable public feeTo;
    address payable public feeToSetter;
    uint256 public feeAmount;
    address public nftAddress;

    event Log(address amount);

    constructor(
        address payable _feeToSetter,
        uint256 _feeAmount,
        address _nftAddress
    ) {
        feeToSetter = _feeToSetter;
        feeTo = feeToSetter;
        feeAmount = _feeAmount;
        nftAddress = _nftAddress;
    }

    function mint(uint256 tokenID) public payable {
        require(msg.value >= feeAmount, 'NFTMINT: Fee is not enough');
        require(ZilionixxNFT(nftAddress).owner() == address(this), 'NFTMINT: NFT owner is not correct!');

        ZilionixxNFT(nftAddress).mint(msg.sender, tokenID);

        bool sent = feeTo.send(msg.value);
        require(sent, 'NFTMINT: Fee transfer failed');
    }

    function setFeeTo(address payable _feeTo) external override {
        require(msg.sender == feeToSetter, 'NFTMINT: FORBIDDEN');
        feeTo = _feeTo;
    }

    function setFeeToSetter(address payable _fyeeToSetter) external override {
        require(msg.sender == feeToSetter, 'NFTMINT: FORBIDDEN');
        feeToSetter = _feeToSetter;
    }

    function setFeeAmount(uint256 _amount) external override {
        require(msg.sender == feeToSetter, 'NFTMINT: FORBIDDEN');
        feeAmount = _amount;
    }
}
