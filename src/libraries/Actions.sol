// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity 0.8.14;

import { DataTypes } from "./DataTypes.sol";
import { Constants } from "./Constants.sol";
import { ActionEvents } from "./ActionEvents.sol";
import { LibString } from "./LibString.sol";
import { ISubscribeNFT } from "../interfaces/ISubscribeNFT.sol";
import { IEssenceNFT } from "../interfaces/IEssenceNFT.sol";
import { BeaconProxy } from "openzeppelin-contracts/contracts/proxy/beacon/BeaconProxy.sol";
import { ISubscribeMiddleware } from "../interfaces/ISubscribeMiddleware.sol";
import { IEssenceMiddleware } from "../interfaces/IEssenceMiddleware.sol";


library Actions {
    function createProfile(
        uint256 id,
        uint256 _totalCount,
        DataTypes.CreateProfileParams calldata params,
        mapping(uint256 => DataTypes.ProfileStruct) storage _profileById,
        mapping(bytes32 => uint256) storage _profileIdByHandleHash,
        mapping(uint256 => string) storage _metadataById,
        mapping(address => uint256) storage _addressToPrimaryProfile
    ) external {
        bytes32 handleHash = keccak256(bytes(params.handle));

        _profileById[_totalCount].handle = params.handle;
        _profileById[_totalCount].avatar = params.avatar;

        _profileIdByHandleHash[handleHash] = _totalCount;
        _metadataById[_totalCount] = params.metadata;

        emit ActionEvents.CreateProfile(
            params.to,
            id,
            params.handle,
            params.avatar,
            params.metadata
        );

        if (_addressToPrimaryProfile[params.to] == 0) {
            _addressToPrimaryProfile[params.to] = id;
            emit ActionEvents.SetPrimaryProfile(params.to, id);
        }
    }

    function subscribe(
        DataTypes.SubscribeData calldata data,
        mapping(uint256 => DataTypes.SubscribeStruct)
            storage _subscribeByProfileId,
        mapping(uint256 => DataTypes.ProfileStruct) storage _profileById
    ) external returns (uint256[] memory result) {
        require(data.profileIds.length > 0, "NO_PROFILE_IDS");
        require(
            data.profileIds.length == data.preDatas.length &&
                data.preDatas.length == data.postDatas.length,
            "LENGTH_MISMATCH"
        );

        result = new uint256[](data.profileIds.length);

        for (uint256 i = 0; i < data.profileIds.length; i++) {
            address subscribeNFT = _subscribeByProfileId[data.profileIds[i]]
                .subscribeNFT;
            address subscribeMw = _subscribeByProfileId[data.profileIds[i]]
                .subscribeMw;
            // lazy deploy subscribe NFT
            if (subscribeNFT == address(0)) {
                subscribeNFT = _deploySubscribeNFT(
                    data.subBeacon,
                    data.profileIds[i],
                    _subscribeByProfileId,
                    _profileById
                );
            }
            // run middleware before subscribe
            if (subscribeMw != address(0)) {
                ISubscribeMiddleware(subscribeMw).preProcess(
                    data.profileIds[i],
                    data.sender,
                    subscribeNFT,
                    data.preDatas[i]
                );
            }
            result[i] = ISubscribeNFT(subscribeNFT).mint(data.sender);
            if (subscribeMw != address(0)) {
                ISubscribeMiddleware(subscribeMw).postProcess(
                    data.profileIds[i],
                    data.sender,
                    subscribeNFT,
                    data.postDatas[i]
                );
            }
        }

        emit ActionEvents.Subscribe(
            data.sender,
            data.profileIds,
            data.preDatas,
            data.postDatas
        );
        return result;
    }

    function _deploySubscribeNFT(
        address subBeacon,
        uint256 profileId,
        mapping(uint256 => DataTypes.SubscribeStruct)
            storage _subscribeByProfileId,
        mapping(uint256 => DataTypes.ProfileStruct) storage _profileById
    ) internal returns (address) {
        address subscribeNFT = address(
            new BeaconProxy(
                subBeacon,
                abi.encodeWithSelector(
                    ISubscribeNFT.initialize.selector,
                    profileId,
                    string(
                        abi.encodePacked(
                            _profileById[profileId].handle,
                            Constants._SUBSCRIBE_NFT_NAME_SUFFIX
                        )
                    ),
                    string(
                        abi.encodePacked(
                            LibString.toUpper(_profileById[profileId].handle),
                            Constants._SUBSCRIBE_NFT_SYMBOL_SUFFIX
                        )
                    )
                )
            )
        );
        _subscribeByProfileId[profileId].subscribeNFT = subscribeNFT;
        emit ActionEvents.DeploySubscribeNFT(profileId, subscribeNFT);
        return subscribeNFT;
    }

    function collect(
        DataTypes.CollectData calldata data,
        mapping(uint256 => mapping(uint256 => DataTypes.EssenceStruct))
            storage _essenceByIdByProfileId
    ) external returns (uint256) {
        require(
            bytes(
                _essenceByIdByProfileId[data.profileId][data.essenceId].tokenURI
            ).length != 0,
            "ESSENCE_NOT_REGISTERED"
        );
        address essenceNFT = _essenceByIdByProfileId[data.profileId][
            data.essenceId
        ].essenceNFT;
        address essenceMw = _essenceByIdByProfileId[data.profileId][
            data.essenceId
        ].essenceMw;

        // lazy deploy essence NFT
        if (essenceNFT == address(0)) {
            bytes memory initData = abi.encodeWithSelector(
                IEssenceNFT.initialize.selector,
                data.profileId,
                data.essenceId,
                _essenceByIdByProfileId[data.profileId][data.essenceId].name,
                _essenceByIdByProfileId[data.profileId][data.essenceId].symbol
            );
            essenceNFT = address(new BeaconProxy(data.essBeacon, initData));
            _essenceByIdByProfileId[data.profileId][data.essenceId]
                .essenceNFT = essenceNFT;
            emit ActionEvents.DeployEssenceNFT(
                data.profileId,
                data.essenceId,
                essenceNFT
            );
        }
        // run middleware before collectign essence
        if (essenceMw != address(0)) {
            IEssenceMiddleware(essenceMw).preProcess(
                data.profileId,
                data.essenceId,
                data.collector,
                essenceNFT,
                data.preData
            );
        }
        uint256 tokenId = IEssenceNFT(essenceNFT).mint(data.collector);
        if (essenceMw != address(0)) {
            IEssenceMiddleware(essenceMw).postProcess(
                data.profileId,
                data.essenceId,
                data.collector,
                essenceNFT,
                data.postData
            );
        }

        emit ActionEvents.CollectEssence(
            data.collector,
            data.profileId,
            data.preData,
            data.postData
        );
        return tokenId;
    }

    function registerEssence(
        DataTypes.RegisterEssenceData calldata data,
        mapping(uint256 => DataTypes.ProfileStruct) storage _profileById,
        mapping(uint256 => mapping(uint256 => DataTypes.EssenceStruct))
            storage _essenceByIdByProfileId
    ) external returns (uint256) {
        uint256 id = ++_profileById[data.profileId].essenceCount;
        _essenceByIdByProfileId[data.profileId][id].name = data.name;
        _essenceByIdByProfileId[data.profileId][id].symbol = data.symbol;
        _essenceByIdByProfileId[data.profileId][id].tokenURI = data
            .essenceTokenURI;
        bytes memory returnData;
        if (data.essenceMw != address(0)) {
            _essenceByIdByProfileId[data.profileId][id].essenceMw = data
                .essenceMw;
            returnData = IEssenceMiddleware(data.essenceMw).prepare(
                data.profileId,
                id,
                data.prepareData
            );
        }
        emit ActionEvents.RegisterEssence(
            data.profileId,
            id,
            data.name,
            data.symbol,
            data.essenceTokenURI,
            data.essenceMw,
            returnData
        );
        return id;
    }
}
