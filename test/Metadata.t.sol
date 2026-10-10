// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Test} from "forge-std/Test.sol";
import {Metadata} from "../src/libraries/Metadata.sol";

contract MetadataHarness {
    function validate(string calldata metadata) external pure {
        Metadata.validate(metadata);
    }
}

contract MetadataTest is Test {
    MetadataHarness internal parser;

    function setUp() public {
        parser = new MetadataHarness();
    }

    function testRequiredFieldsObjectAndArrayLinksAndExtraJSON() public view {
        parser.validate('{"description":"project","image":"ipfs://image","links":{}}');
        parser.validate(
            ' { "links" : ["https://one", "https://two"], "description":"line\\nquote\\\"\\u1234", "image":"https://image", "extra":{"x":[null,true,false,-1.2e+3]} } '
        );
    }

    function testMalformedAndWrongSchemaRejected() public {
        string[14] memory invalid = [
            string(""),
            "{}",
            '{"description":"x","image":"x","links":{},}',
            '{"description":"x","image":"x","links":{}',
            '{"description":"x","image":"x","links":{}} junk',
            '{"description":"x","image":"x","links":1}',
            '{"description":1,"image":"x","links":{}}',
            '{"description":"x","image":"x","links":{},"description":"y"}',
            '{"description":"x","image":"x","links":[true]}',
            '{"description":"x","image":"x","links":{"a":1}}',
            '{"description":"","image":"x","links":{}}',
            '{"description":"x","image":"x","links":{},"extra":01}',
            '{"description":"\\q","image":"x","links":{}}',
            '{"description":"x","image":"x","links":{},"extra":[1,]}'
        ];
        for (uint256 i = 0; i < invalid.length; ++i) {
            vm.expectRevert(Metadata.InvalidMetadata.selector);
            parser.validate(invalid[i]);
        }
    }

    function testMalformedUTF8RejectedAndUnicodeAccepted() public {
        parser.validate(unicode'{"description":"船⚓","image":"ipfs://image","links":{}}');
        vm.expectRevert(Metadata.InvalidMetadata.selector);
        parser.validate(string(abi.encodePacked('{"description":"', hex"c080", '","image":"i","links":{}}')));
        vm.expectRevert(Metadata.InvalidMetadata.selector);
        parser.validate(
            string(abi.encodePacked('{"description":"', hex"eda080", '","image":"i","links":{}}'))
        );
        vm.expectRevert(Metadata.InvalidMetadata.selector);
        parser.validate(
            string(abi.encodePacked('{"description":"', hex"f4908080", '","image":"i","links":{}}'))
        );
    }

    function testMax1024BytesAndDepthLimit() public {
        bytes memory filler = new bytes(980);
        for (uint256 i = 0; i < filler.length; ++i) {
            filler[i] = "x";
        }
        string memory json = string.concat('{"description":"', string(filler), '","image":"i","links":{}}');
        assertGt(bytes(json).length, 1024 - 10);
        while (bytes(json).length < 1024) json = string.concat(json, " ");
        assertEq(bytes(json).length, 1024);
        parser.validate(json);
        vm.expectRevert(Metadata.InvalidMetadata.selector);
        parser.validate(string.concat(json, " "));
        vm.expectRevert(Metadata.InvalidMetadata.selector);
        parser.validate('{"description":"d","image":"i","links":{},"x":[[[[[[[[[[0]]]]]]]]]]}');
    }
}
