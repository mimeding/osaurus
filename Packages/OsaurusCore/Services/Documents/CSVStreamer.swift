//
//  CSVStreamer.swift
//  osaurus
//
//  Streaming variant of `CSVAdapter` for files that don't fit in the
//  in-memory cap — multi-GB bank exports, long-running event logs, etc.
//  Emits one `CSVRecord` per row via an `AsyncThrowingStream` so callers
//  can back-pressure and cancel rather than paying for the whole file up
//  front. The agent tool surface is the obvious consumer; the chat
//  attachment path stays on the eager `CSVAdapter` because it needs the
//  whole table to render.
//
//  The byte -> scalar -> parser pipeline reuses `CSVParser.Machine`, so
//  quoted-field / embedded-newline / escape semantics match the batch
//  adapter exactly. The only difference is that rows flush out as soon
//  as they complete rather than waiting for the file to end.
//

import Foundation

public struct CSVStreamer: DocumentFormatStreamer {
    public let formatId = "csv"

    public init() {}

    public func stream(url: URL) -> AsyncThrowingStream<CSVRecord, Error> {
        let delimiter: Character = url.pathExtension.lowercased() == "tsv" ? "\t" : ","

        return AsyncThrowingStream { continuation in
            Task {
                do {
                    try Self.drain(url: url, delimiter: delimiter, into: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Internals

    private static let chunkSize = 64 * 1024

    /// Reads `url` in 64 KB chunks, feeds bytes through the shared
    /// CSV state machine, and yields completed rows one at a time.
    /// Throws on I/O failure or Task cancellation.
    private static func drain(
        url: URL,
        delimiter: Character,
        into continuation: AsyncThrowingStream<CSVRecord, Error>.Continuation
    ) throws {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw DocumentAdapterError.readFailed(underlying: error.localizedDescription)
        }
        defer { try? handle.close() }

        var machine = CSVParser.Machine(delimiter: delimiter)
        var leftoverBytes = Data()
        var didStripBOM = false
        var lineNumber = 0

        while true {
            let chunk = handle.readData(ofLength: chunkSize)
            if chunk.isEmpty { break }

            var buffer = leftoverBytes
            buffer.append(chunk)

            if !didStripBOM {
                didStripBOM = true
                if buffer.count >= 3, buffer[0] == 0xEF, buffer[1] == 0xBB, buffer[2] == 0xBF {
                    buffer = buffer.subdata(in: 3 ..< buffer.count)
                }
            }

            // Split on the last valid UTF-8 boundary so we don't feed a
            // partial multi-byte scalar into the parser. Anything after
            // the last boundary becomes leftover for the next chunk.
            let (decodable, tail) = Self.splitAtUTF8Boundary(buffer)
            leftoverBytes = tail

            if let text = String(data: decodable, encoding: .utf8) {
                for scalar in text.unicodeScalars {
                    machine.consume(scalar)
                }
            } else if let text = String(data: decodable, encoding: .isoLatin1) {
                for scalar in text.unicodeScalars {
                    machine.consume(scalar)
                }
            } else {
                throw DocumentAdapterError.readFailed(underlying: "could not decode CSV chunk")
            }

            for row in machine.drainRows() {
                lineNumber += 1
                continuation.yield(CSVRecord(lineNumber: lineNumber, cells: row))
                try Task.checkCancellation()
            }
        }

        // Flush trailing data (last scalar + final row when no trailing newline).
        if !leftoverBytes.isEmpty {
            let tail =
                String(data: leftoverBytes, encoding: .utf8)
                ?? String(data: leftoverBytes, encoding: .isoLatin1)
            if let text = tail {
                for scalar in text.unicodeScalars { machine.consume(scalar) }
            }
        }
        machine.finish()
        for row in machine.drainRows() {
            lineNumber += 1
            continuation.yield(CSVRecord(lineNumber: lineNumber, cells: row))
        }
    }

    /// Finds the last byte position where a valid UTF-8 scalar ends and
    /// returns the prefix (decodable) + suffix (carry over to next read).
    /// Falls back to the whole buffer when no multi-byte lead byte is in
    /// the final 3 bytes — that means the last scalar is ASCII and
    /// already complete.
    static func splitAtUTF8Boundary(_ data: Data) -> (decodable: Data, tail: Data) {
        guard data.count >= 4 else { return (data, Data()) }
        let maxScan = min(data.count, 4)
        for offset in 1 ... maxScan {
            let byte = data[data.count - offset]
            // Bytes `10xxxxxx` are continuation bytes; `11xxxxxx` are
            // lead bytes; single-byte ASCII is `0xxxxxxx`.
            if byte & 0b1100_0000 == 0b1000_0000 {
                continue  // continuation; keep scanning
            }
            if byte & 0b1000_0000 == 0 {
                return (data, Data())  // ASCII final byte; safe to decode as-is
            }
            // Multi-byte lead byte. How many continuation bytes does it
            // claim? 2-byte lead is `110x`, 3-byte is `1110`, 4-byte is
            // `11110`. Expected-length minus what we've already scanned
            // tells us how many bytes we're still short.
            let leadMask = byte
            let expected: Int
            if leadMask & 0b1111_0000 == 0b1111_0000 {
                expected = 4
            } else if leadMask & 0b1110_0000 == 0b1110_0000 {
                expected = 3
            } else if leadMask & 0b1100_0000 == 0b1100_0000 {
                expected = 2
            } else {
                // Malformed lead byte; treat everything as decodable and
                // let the String initializer fail closed.
                return (data, Data())
            }
            if expected <= offset {
                return (data, Data())  // full scalar is inside the buffer
            }
            // Short; carry the partial scalar to the next read.
            let boundary = data.count - offset
            return (data.subdata(in: 0 ..< boundary), data.subdata(in: boundary ..< data.count))
        }
        return (data, Data())
    }
}
