import Compression
import Foundation

/// 绑定寝室包只允许一个根目录 manifest.json，清单直接在内存中读取。
enum PluginZip {
    private static let localSignature: UInt32 = 0x04034b50
    private static let centralSignature: UInt32 = 0x02014b50
    private static let descriptorSignature: UInt32 = 0x08074b50
    private static let endSignature: UInt32 = 0x06054b50
    private static let name = Array("manifest.json".utf8)
    private static let badZip = PluginError("插件 ZIP 已损坏或包含不支持的文件")

    static func readManifest(_ data: Data, limit: Int) throws -> Data {
        let bytes = Array(data)
        guard let end = endOffset(in: bytes),
              uint16(bytes, end + 4) == 0, uint16(bytes, end + 6) == 0,
              uint16(bytes, end + 8) == 1, uint16(bytes, end + 10) == 1 else {
            throw badZip
        }
        let centralSize = Int(uint32(bytes, end + 12))
        let central = Int(uint32(bytes, end + 16))
        guard centralSize >= 46, central + centralSize == end,
              uint32(bytes, central) == centralSignature,
              uint16(bytes, central + 34) == 0, uint32(bytes, central + 42) == 0 else {
            throw badZip
        }
        let flags = uint16(bytes, central + 8)
        let method = uint16(bytes, central + 10)
        let crc = uint32(bytes, central + 16)
        let compressedSize = Int(uint32(bytes, central + 20))
        let size = Int(uint32(bytes, central + 24))
        let centralNameLength = uint16(bytes, central + 28)
        let centralExtraLength = uint16(bytes, central + 30)
        let centralCommentLength = uint16(bytes, central + 32)
        guard centralNameLength == name.count,
              centralSize == 46 + centralNameLength + centralExtraLength + centralCommentLength,
              bytes[(central + 46)..<(central + 46 + name.count)].elementsEqual(name),
              flags & ~0x080e == 0, method == 0 || method == 8,
              size > 0, size <= limit, compressedSize > 0,
              central >= 30 + name.count,
              0x10 & uint32(bytes, central + 38) == 0 else { throw badZip }

        // Local header and central directory must describe the same one file.
        let hasDescriptor = flags & 8 != 0
        let localNameLength = uint16(bytes, 26)
        let payload = 30 + localNameLength + uint16(bytes, 28)
        let payloadEnd = payload + compressedSize
        guard uint32(bytes, 0) == localSignature, uint16(bytes, 6) == flags,
              uint16(bytes, 8) == method, localNameLength == name.count,
              payloadEnd <= central, bytes[30..<(30 + name.count)].elementsEqual(name) else {
            throw badZip
        }
        let localValues = [uint32(bytes, 14), uint32(bytes, 18), uint32(bytes, 22)]
        let centralValues = [crc, UInt32(compressedSize), UInt32(size)]
        for (local, listed) in zip(localValues, centralValues) {
            guard local == listed || (hasDescriptor && local == 0) else { throw badZip }
        }
        if hasDescriptor {
            let descriptorSize = central - payloadEnd
            guard descriptorSize == 12 || descriptorSize == 16 else { throw badZip }
            if descriptorSize == 16, uint32(bytes, payloadEnd) != descriptorSignature { throw badZip }
            let descriptor = central - 12
            for (index, listed) in centralValues.enumerated() {
                guard uint32(bytes, descriptor + index * 4) == listed else { throw badZip }
            }
        } else if payloadEnd != central {
            throw badZip
        }
        let payloadBytes = Array(bytes[payload..<payloadEnd])
        let decoded = method == 0 ? payloadBytes : try inflate(payloadBytes, expected: size)
        guard decoded.count == size, crc32(decoded) == crc else { throw badZip }
        return Data(decoded)
    }

    private static func endOffset(in bytes: [UInt8]) -> Int? {
        guard bytes.count >= 22 else { return nil }
        let last = bytes.count - 22
        for index in stride(from: last, through: max(0, last - 65_535), by: -1) {
            if uint32(bytes, index) == endSignature,
               index + 22 + uint16(bytes, index + 20) == bytes.count {
                return index
            }
        }
        return nil
    }

    private static func uint16(_ bytes: [UInt8], _ offset: Int) -> Int {
        Int(bytes[offset]) | Int(bytes[offset + 1]) << 8
    }

    private static func uint32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(uint16(bytes, offset)) | UInt32(uint16(bytes, offset + 2)) << 16
    }

    private static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = .max
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc >> 1) ^ (crc & 1 == 0 ? 0 : 0xedb88320)
            }
        }
        return ~crc
    }

    private static func inflate(_ input: [UInt8], expected: Int) throws -> [UInt8] {
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)
            == COMPRESSION_STATUS_OK else { throw badZip }
        defer { compression_stream_destroy(stream) }

        // Keep a spare byte to distinguish an exact result from a truncated output buffer.
        let capacity = expected + 1
        var output = [UInt8](repeating: 0, count: capacity)
        let count = try input.withUnsafeBufferPointer { source in
            try output.withUnsafeMutableBufferPointer { destination in
                guard let sourcePtr = source.baseAddress, let destinationPtr = destination.baseAddress else {
                    throw badZip
                }
                stream.pointee.src_ptr = sourcePtr
                stream.pointee.src_size = input.count
                stream.pointee.dst_ptr = destinationPtr
                stream.pointee.dst_size = capacity
                while stream.pointee.dst_size > 0 {
                    let sourceLeft = stream.pointee.src_size
                    let destinationLeft = stream.pointee.dst_size
                    let status = compression_stream_process(stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                    if status == COMPRESSION_STATUS_END {
                        guard stream.pointee.src_size == 0 else { throw badZip }
                        return capacity - stream.pointee.dst_size
                    }
                    guard status == COMPRESSION_STATUS_OK,
                          stream.pointee.src_size != sourceLeft || stream.pointee.dst_size != destinationLeft else {
                        throw badZip
                    }
                }
                throw badZip
            }
        }
        guard count == expected else { throw badZip }
        return Array(output.prefix(count))
    }
}
