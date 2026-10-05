//
//  ZmodemCRC.swift
//  iGhostVT
//

import Foundation

enum ZmodemCRC {
    private static let table16: [UInt16] = {
        var table = [UInt16](repeating: 0, count: 256)
        for index in 0 ..< 256 {
            var crc = UInt16(index) << 8
            for _ in 0 ..< 8 {
                crc = (crc & 0x8000) != 0 ? (crc << 1) ^ 0x1021 : (crc << 1)
            }
            table[index] = crc
        }
        return table
    }()

    @inline(__always)
    static func update16(_ crc: UInt16, _ byte: UInt8) -> UInt16 {
        (crc << 8) ^ table16[Int((crc >> 8) ^ UInt16(byte)) & 0xFF]
    }

    static func crc16<S: Sequence>(_ bytes: S) -> UInt16 where S.Element == UInt8 {
        var crc: UInt16 = 0
        for byte in bytes { crc = update16(crc, byte) }
        return crc
    }

    private static let table32: [UInt32] = {
        var table = [UInt32](repeating: 0, count: 256)
        for index in 0 ..< 256 {
            var crc = UInt32(index)
            for _ in 0 ..< 8 {
                crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB8_8320 : (crc >> 1)
            }
            table[index] = crc
        }
        return table
    }()

    @inline(__always)
    static func update32(_ crc: UInt32, _ byte: UInt8) -> UInt32 {
        (crc >> 8) ^ table32[Int((crc ^ UInt32(byte)) & 0xFF)]
    }

    static func crc32<S: Sequence>(_ bytes: S) -> UInt32 where S.Element == UInt8 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes { crc = update32(crc, byte) }
        return crc ^ 0xFFFF_FFFF
    }
}
