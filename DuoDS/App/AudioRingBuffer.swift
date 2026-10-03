import Foundation
import Synchronization

/// Lock-free single-producer / single-consumer byte ring buffer.
/// The emulation thread writes, the audio render callback reads.
final class AudioRingBuffer {
    private let storage: UnsafeMutableRawPointer
    private let capacity: Int
    // Monotonic byte counters; the difference is the readable size.
    private let readCount = Atomic<Int>(0)
    private let writeCount = Atomic<Int>(0)

    init?(preferredBufferSize: Int) {
        guard preferredBufferSize > 0 else { return nil }
        capacity = preferredBufferSize
        storage = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 16)
    }

    deinit { storage.deallocate() }

    var availableBytesForReading: Int {
        writeCount.load(ordering: .acquiring) - readCount.load(ordering: .relaxed)
    }

    var availableBytesForWriting: Int {
        capacity - (writeCount.load(ordering: .relaxed) - readCount.load(ordering: .acquiring))
    }

    /// Writes as many bytes as fit; overflowing samples are dropped.
    @discardableResult
    func write(_ source: UnsafeRawPointer, size: Int) -> Int {
        let count = min(size, availableBytesForWriting)
        guard count > 0 else { return 0 }
        let written = writeCount.load(ordering: .relaxed)
        copy(count, from: source, toRingOffset: written % capacity)
        writeCount.store(written + count, ordering: .releasing)
        return count
    }

    /// Reads up to `preferredSize` bytes and returns how many were copied.
    func read(into destination: UnsafeMutableRawPointer, preferredSize: Int) -> Int {
        let count = min(preferredSize, availableBytesForReading)
        guard count > 0 else { return 0 }
        let read = readCount.load(ordering: .relaxed)
        let offset = read % capacity
        let firstPart = min(count, capacity - offset)
        destination.copyMemory(from: storage + offset, byteCount: firstPart)
        if firstPart < count {
            (destination + firstPart).copyMemory(from: storage, byteCount: count - firstPart)
        }
        readCount.store(read + count, ordering: .releasing)
        return count
    }

    private func copy(_ count: Int, from source: UnsafeRawPointer, toRingOffset offset: Int) {
        let firstPart = min(count, capacity - offset)
        (storage + offset).copyMemory(from: source, byteCount: firstPart)
        if firstPart < count {
            storage.copyMemory(from: source + firstPart, byteCount: count - firstPart)
        }
    }
}
