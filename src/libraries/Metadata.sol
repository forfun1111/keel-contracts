// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Bounded JSON validation. Required literal keys: description, image, links.
/// Links can be an object of string URLs or an array of string URLs. Extra JSON fields are allowed.
library Metadata {
    error InvalidMetadata();

    function validate(string calldata value) internal pure {
        bytes calldata b = bytes(value);
        if (b.length == 0 || b.length > 1024) revert InvalidMetadata();
        uint256 i = _ws(b, 0);
        if (i == b.length || b[i] != "{") revert InvalidMetadata();
        i = _ws(b, i + 1);
        uint256 flags = 0;
        while (i < b.length && b[i] != "}") {
            uint256 keyStart = i;
            i = _string(b, i);
            bytes32 key = keccak256(b[keyStart + 1:i - 1]);
            i = _ws(b, i);
            if (i == b.length || b[i] != ":") revert InvalidMetadata();
            i = _ws(b, i + 1);
            uint256 flag = 0;
            if (key == keccak256("description") || key == keccak256("image")) {
                flag = key == keccak256("description") ? 1 : 2;
                uint256 start = i;
                i = _string(b, i);
                if (i == start + 2) revert InvalidMetadata();
            } else if (key == keccak256("links")) {
                flag = 4;
                i = _links(b, i);
            } else {
                i = _value(b, i, 0);
            }
            if (flags & flag != 0) revert InvalidMetadata();
            flags |= flag;
            i = _ws(b, i);
            if (i == b.length) revert InvalidMetadata();
            if (b[i] == "}") break;
            if (b[i] != ",") revert InvalidMetadata();
            i = _ws(b, i + 1);
            if (i == b.length || b[i] == "}") revert InvalidMetadata();
        }
        if (flags != 7 || i == b.length || _ws(b, i + 1) != b.length) revert InvalidMetadata();
    }

    function _links(bytes calldata b, uint256 i) private pure returns (uint256) {
        if (i == b.length || (b[i] != "{" && b[i] != "[")) revert InvalidMetadata();
        bool object = b[i] == "{";
        bytes1 end = object ? bytes1("}") : bytes1("]");
        i = _ws(b, i + 1);
        if (i < b.length && b[i] == end) return i + 1;
        while (i < b.length) {
            if (object) {
                i = _ws(b, _string(b, i));
                if (i == b.length || b[i] != ":") revert InvalidMetadata();
                i = _ws(b, i + 1);
            }
            i = _ws(b, _string(b, i));
            if (i == b.length) revert InvalidMetadata();
            if (b[i] == end) return i + 1;
            if (b[i] != ",") revert InvalidMetadata();
            i = _ws(b, i + 1);
        }
        revert InvalidMetadata();
    }

    function _value(bytes calldata b, uint256 i, uint256 depth) private pure returns (uint256) {
        if (i == b.length || depth > 8) revert InvalidMetadata();
        if (b[i] == '"') return _string(b, i);
        if (b[i] == "{" || b[i] == "[") {
            bool object = b[i] == "{";
            bytes1 end = object ? bytes1("}") : bytes1("]");
            i = _ws(b, i + 1);
            if (i < b.length && b[i] == end) return i + 1;
            while (i < b.length) {
                if (object) {
                    i = _ws(b, _string(b, i));
                    if (i == b.length || b[i] != ":") revert InvalidMetadata();
                    i = _ws(b, i + 1);
                }
                i = _ws(b, _value(b, i, depth + 1));
                if (i == b.length) revert InvalidMetadata();
                if (b[i] == end) return i + 1;
                if (b[i] != ",") revert InvalidMetadata();
                i = _ws(b, i + 1);
            }
            revert InvalidMetadata();
        }
        if (b[i] == "t" && i + 4 <= b.length && keccak256(b[i:i + 4]) == keccak256("true")) return i + 4;
        if (b[i] == "f" && i + 5 <= b.length && keccak256(b[i:i + 5]) == keccak256("false")) return i + 5;
        if (b[i] == "n" && i + 4 <= b.length && keccak256(b[i:i + 4]) == keccak256("null")) return i + 4;
        if (b[i] == "-") ++i;
        if (i == b.length || !_digit(b[i])) revert InvalidMetadata();
        if (b[i] == "0") ++i;
        else while (i < b.length && _digit(b[i])) ++i;
        if (i < b.length && b[i] == ".") {
            ++i;
            if (i == b.length || !_digit(b[i])) revert InvalidMetadata();
            while (i < b.length && _digit(b[i])) ++i;
        }
        if (i < b.length && (b[i] == "e" || b[i] == "E")) {
            ++i;
            if (i < b.length && (b[i] == "+" || b[i] == "-")) ++i;
            if (i == b.length || !_digit(b[i])) revert InvalidMetadata();
            while (i < b.length && _digit(b[i])) ++i;
        }
        return i;
    }

    function _string(bytes calldata b, uint256 i) private pure returns (uint256) {
        if (i == b.length || b[i] != '"') revert InvalidMetadata();
        ++i;
        while (i < b.length) {
            bytes1 c = b[i++];
            if (c == '"') return i;
            if (uint8(c) < 0x20) revert InvalidMetadata();
            if (c == "\\") {
                if (i == b.length) revert InvalidMetadata();
                c = b[i++];
                if (c == "u") {
                    if (i + 4 > b.length) revert InvalidMetadata();
                    for (uint256 j = 0; j < 4; ++j) {
                        c = b[i++];
                        if (!_digit(c) && !(c >= "a" && c <= "f") && !(c >= "A" && c <= "F")) {
                            revert InvalidMetadata();
                        }
                    }
                } else if (
                    c != '"' && c != "\\" && c != "/" && c != "b" && c != "f" && c != "n" && c != "r"
                        && c != "t"
                ) {
                    revert InvalidMetadata();
                }
            } else if (uint8(c) >= 0x80) {
                i = _utf8(b, i - 1);
            }
        }
        revert InvalidMetadata();
    }

    function _utf8(bytes calldata b, uint256 start) private pure returns (uint256) {
        uint8 lead = uint8(b[start]);
        if (lead < 0xc2 || lead > 0xf4) revert InvalidMetadata();
        uint256 size = lead < 0xe0 ? 2 : (lead < 0xf0 ? 3 : 4);
        if (start + size > b.length) revert InvalidMetadata();
        uint8 second = uint8(b[start + 1]);
        if (
            (lead == 0xe0 && second < 0xa0) || (lead == 0xed && second >= 0xa0)
                || (lead == 0xf0 && second < 0x90) || (lead == 0xf4 && second >= 0x90)
        ) revert InvalidMetadata();
        for (uint256 j = 1; j < size; ++j) {
            uint8 continuation = uint8(b[start + j]);
            if (continuation < 0x80 || continuation > 0xbf) revert InvalidMetadata();
        }
        return start + size;
    }

    function _digit(bytes1 c) private pure returns (bool) {
        return c >= "0" && c <= "9";
    }

    function _ws(bytes calldata b, uint256 i) private pure returns (uint256) {
        while (i < b.length && (b[i] == " " || b[i] == "\t" || b[i] == "\r" || b[i] == "\n")) ++i;
        return i;
    }
}
