// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../RaffleStorage.sol";

abstract contract RaffleGovernance is RaffleStorage {
    error InvalidFeePercentages();

    event GovernanceTransferred(address oldGov, address newGovernance);
    event FeePercentagedUpdated(
        uint8 platformFeePercent,
        uint8 founderFeePercent,
        uint8 winnerFeePercent
    );
    event PlatformAddressUpdated(address platform);
    event FounderAddressUpdated(address founder);

    function transferGovernance(address newGovernance) external onlyGovernance {
        if (newGovernance == address(0)) revert ZeroAddress();
        address oldGov = governance;
        governance = newGovernance;

        emit GovernanceTransferred(oldGov, newGovernance);
    }

    function setFeePercentages(
        uint8 platformFeePercent_,
        uint8 founderFeePercent_,
        uint8 winnerFeePercent_
    ) external onlyGovernance {
        if (
            platformFeePercent_ + founderFeePercent_ + winnerFeePercent_ != 100
        ) {
            revert InvalidFeePercentages();
        }

        platformFeePercent = platformFeePercent_;
        founderFeePercent = founderFeePercent_;
        winnerFeePercent = winnerFeePercent_;

        emit FeePercentagedUpdated(
            platformFeePercent_,
            founderFeePercent_,
            winnerFeePercent_
        );
    }

    function setPlatformAddress(
        address _platformAddress
    ) external onlyGovernance {
        if (_platformAddress == address(0)) revert ZeroAddress();
        platformAddress = _platformAddress;
        emit PlatformAddressUpdated(_platformAddress);
    }

    function setFounderAddress(
        address _founderAddress
    ) external onlyGovernance {
        if (_founderAddress == address(0)) revert ZeroAddress();
        founderAddress = _founderAddress;
        emit FounderAddressUpdated(_founderAddress);
    }
}
