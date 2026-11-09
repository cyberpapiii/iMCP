import Foundation

/// Unsigned big-integer arithmetic, sized for SRP-6a and nothing else.
///
/// This is deliberately not a general-purpose bignum. It carries exactly the
/// operations the SRP exchange needs and no more. Apple's SRP-6a needs RFC 5054
/// padding and leaves the username out of `x`, so stock SRP packages would need
/// a fork, and the usual one pulls in a BoringSSL `BIGNUM` wrapper. Fixed-width
/// 2048-bit modexp, checked against published vectors, adds no dependency.
///
/// Limbs are little-endian and normalized, so the representation of a value is
/// unique and `==` is exact.
struct BigUInt: Equatable, Sendable {
    private(set) var limbs: [UInt64]

    init() {
        limbs = []
    }

    init(_ value: UInt64) {
        limbs = value == 0 ? [] : [value]
    }

    init(limbs: [UInt64]) {
        var normalized = limbs
        while normalized.last == 0 { normalized.removeLast() }
        self.limbs = normalized
    }

    /// Big-endian, leading zero bytes ignored.
    init<Bytes: Collection>(bigEndianBytes bytes: Bytes) where Bytes.Element == UInt8 {
        var packed: [UInt64] = []
        packed.reserveCapacity(bytes.count / 8 + 1)
        var limb: UInt64 = 0
        var filled = 0
        for byte in bytes.reversed() {
            limb |= UInt64(byte) << (8 * filled)
            filled += 1
            if filled == 8 {
                packed.append(limb)
                limb = 0
                filled = 0
            }
        }
        if filled > 0 { packed.append(limb) }
        self.init(limbs: packed)
    }

    init(hexadecimal text: String) {
        var bytes: [UInt8] = []
        var pending = text.count % 2 == 0 ? "" : "0"
        for character in text {
            pending.append(character)
            if pending.count == 2 {
                bytes.append(UInt8(pending, radix: 16) ?? 0)
                pending = ""
            }
        }
        self.init(bigEndianBytes: bytes)
    }

    var isZero: Bool { limbs.isEmpty }

    var bitWidth: Int {
        guard let top = limbs.last else { return 0 }
        return limbs.count * 64 - top.leadingZeroBitCount
    }

    func bit(at index: Int) -> Bool {
        let limbIndex = index / 64
        guard limbIndex < limbs.count else { return false }
        return (limbs[limbIndex] >> UInt64(index % 64)) & 1 == 1
    }

    /// Minimal big-endian encoding. Zero encodes as no bytes at all, matching
    /// the reference SRP implementations whose transcript hashes this feeds.
    var bigEndianBytes: Data {
        guard !limbs.isEmpty else { return Data() }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(limbs.count * 8)
        for limb in limbs.reversed() {
            for shift in stride(from: 56, through: 0, by: -8) {
                bytes.append(UInt8(truncatingIfNeeded: limb >> UInt64(shift)))
            }
        }
        if let firstSignificant = bytes.firstIndex(where: { $0 != 0 }) {
            bytes.removeFirst(firstSignificant)
        }
        return Data(bytes)
    }

    /// Left-padded to `count` bytes. RFC 5054 hashes operands at the modulus
    /// width, so a short value must be padded rather than hashed as-is.
    func bigEndianBytes(paddedTo count: Int) -> Data {
        let minimal = bigEndianBytes
        guard minimal.count < count else { return minimal }
        return Data(repeating: 0, count: count - minimal.count) + minimal
    }

    static func compare(_ lhs: BigUInt, _ rhs: BigUInt) -> Int {
        if lhs.limbs.count != rhs.limbs.count {
            return lhs.limbs.count < rhs.limbs.count ? -1 : 1
        }
        for index in stride(from: lhs.limbs.count - 1, through: 0, by: -1)
        where lhs.limbs[index] != rhs.limbs[index] {
            return lhs.limbs[index] < rhs.limbs[index] ? -1 : 1
        }
        return 0
    }

    static func + (lhs: BigUInt, rhs: BigUInt) -> BigUInt {
        var sum: [UInt64] = []
        sum.reserveCapacity(max(lhs.limbs.count, rhs.limbs.count) + 1)
        var carry: UInt64 = 0
        for index in 0 ..< max(lhs.limbs.count, rhs.limbs.count) {
            let left = index < lhs.limbs.count ? lhs.limbs[index] : 0
            let right = index < rhs.limbs.count ? rhs.limbs[index] : 0
            let (partial, firstOverflow) = left.addingReportingOverflow(right)
            let (total, secondOverflow) = partial.addingReportingOverflow(carry)
            sum.append(total)
            carry = (firstOverflow ? 1 : 0) + (secondOverflow ? 1 : 0)
        }
        if carry != 0 { sum.append(carry) }
        return BigUInt(limbs: sum)
    }

    /// Requires `lhs >= rhs`; SRP never subtracts in the other direction.
    static func - (lhs: BigUInt, rhs: BigUInt) -> BigUInt {
        var difference: [UInt64] = []
        difference.reserveCapacity(lhs.limbs.count)
        var borrow: UInt64 = 0
        for index in 0 ..< lhs.limbs.count {
            let right = index < rhs.limbs.count ? rhs.limbs[index] : 0
            let (partial, firstUnderflow) = lhs.limbs[index].subtractingReportingOverflow(right)
            let (total, secondUnderflow) = partial.subtractingReportingOverflow(borrow)
            difference.append(total)
            borrow = (firstUnderflow ? 1 : 0) + (secondUnderflow ? 1 : 0)
        }
        return BigUInt(limbs: difference)
    }

    static func * (lhs: BigUInt, rhs: BigUInt) -> BigUInt {
        guard !lhs.isZero, !rhs.isZero else { return BigUInt() }
        var product = [UInt64](repeating: 0, count: lhs.limbs.count + rhs.limbs.count)
        for i in 0 ..< lhs.limbs.count {
            var carry: UInt64 = 0
            for j in 0 ..< rhs.limbs.count {
                // The running total cannot exceed 2^128 - 1, so the high word
                // never overflows and no second carry word is needed.
                var (high, low) = lhs.limbs[i].multipliedFullWidth(by: rhs.limbs[j])
                var overflow = false
                (low, overflow) = low.addingReportingOverflow(product[i + j])
                if overflow { high &+= 1 }
                (low, overflow) = low.addingReportingOverflow(carry)
                if overflow { high &+= 1 }
                product[i + j] = low
                carry = high
            }
            product[i + rhs.limbs.count] = carry
        }
        return BigUInt(limbs: product)
    }
}

/// Modular arithmetic against a fixed odd modulus, in the Montgomery domain.
///
/// Montgomery rather than schoolbook division because SRP needs a few thousand
/// modular multiplications per sign-in and this removes division from all of
/// them. The modulus is fixed for the lifetime of the value, so the
/// precomputation is paid once.
struct SRPModulus {
    let modulus: BigUInt
    /// Byte width of the modulus. RFC 5054 pads hash operands to this.
    let byteCount: Int

    private let limbCount: Int
    private let n: [UInt64]
    /// -N^-1 mod 2^64, the CIOS reduction multiplier.
    private let n0inv: UInt64
    /// R mod N: the Montgomery form of one.
    private let one: [UInt64]
    /// R^2 mod N: multiplying by this converts into the Montgomery domain.
    private let rSquared: [UInt64]

    init?(modulus: BigUInt) {
        // Montgomery reduction needs an odd modulus. Doubling up from one
        // needs a modulus greater than one to reduce against.
        guard let low = modulus.limbs.first, low % 2 == 1,
            BigUInt.compare(modulus, BigUInt(1)) > 0
        else { return nil }
        self.modulus = modulus
        self.limbCount = modulus.limbs.count
        self.byteCount = modulus.bigEndianBytes.count
        self.n = modulus.limbs

        // Newton's method on the ring of integers mod 2^64: five doublings take
        // a correct single-bit inverse out to all 64 bits.
        var inverse: UInt64 = 1
        for _ in 0 ..< 6 { inverse = inverse &* (2 &- low &* inverse) }
        self.n0inv = 0 &- inverse

        // R mod N and R^2 mod N by repeated doubling from one. Doubling is
        // cheaper to write correctly than a division, and both run once.
        var rMod = [UInt64](repeating: 0, count: limbCount)
        rMod[0] = 1
        for _ in 0 ..< (limbCount * 64) {
            rMod = Self.doubled(rMod, modulus: n)
        }
        self.one = rMod

        var squared = rMod
        for _ in 0 ..< (limbCount * 64) {
            squared = Self.doubled(squared, modulus: n)
        }
        self.rSquared = squared
    }

    /// Doubles a value already reduced mod `modulus`.
    private static func doubled(_ value: [UInt64], modulus: [UInt64]) -> [UInt64] {
        var shifted = value
        var carry: UInt64 = 0
        for index in 0 ..< shifted.count {
            let next = shifted[index] >> 63
            shifted[index] = (shifted[index] << 1) | carry
            carry = next
        }
        if carry != 0 || compare(shifted, modulus) >= 0 {
            shifted = subtract(shifted, modulus)
        }
        return shifted
    }

    private static func compare(_ lhs: [UInt64], _ rhs: [UInt64]) -> Int {
        for index in stride(from: lhs.count - 1, through: 0, by: -1) where lhs[index] != rhs[index] {
            return lhs[index] < rhs[index] ? -1 : 1
        }
        return 0
    }

    private static func subtract(_ lhs: [UInt64], _ rhs: [UInt64]) -> [UInt64] {
        var difference = [UInt64](repeating: 0, count: lhs.count)
        var borrow: UInt64 = 0
        for index in 0 ..< lhs.count {
            let (partial, firstUnderflow) = lhs[index].subtractingReportingOverflow(rhs[index])
            let (total, secondUnderflow) = partial.subtractingReportingOverflow(borrow)
            difference[index] = total
            borrow = (firstUnderflow ? 1 : 0) + (secondUnderflow ? 1 : 0)
        }
        return difference
    }

    private func padded(_ value: BigUInt) -> [UInt64] {
        var limbs = value.limbs
        limbs.append(contentsOf: repeatElement(0, count: limbCount - limbs.count))
        return limbs
    }

    /// CIOS Montgomery multiplication: returns `a * b * R^-1 mod N`.
    ///
    /// The loops run on unsafe buffers rather than on the arrays directly. A
    /// sign-in performs a few thousand of these, each one two `limbCount`
    /// squared inner steps, and in a debug build the bounds and exclusivity
    /// checks on array subscripts cost more than the arithmetic they guard.
    private func montgomeryMultiply(_ a: [UInt64], _ b: [UInt64]) -> [UInt64] {
        let count = limbCount
        var t = [UInt64](repeating: 0, count: count + 2)
        var needsSubtraction = false

        a.withUnsafeBufferPointer { a in
            b.withUnsafeBufferPointer { b in
                n.withUnsafeBufferPointer { n in
                    t.withUnsafeMutableBufferPointer { t in
                        for i in 0 ..< count {
                            let ai = a[i]
                            var carry: UInt64 = 0
                            for j in 0 ..< count {
                                var (high, low) = ai.multipliedFullWidth(by: b[j])
                                var overflow = false
                                (low, overflow) = low.addingReportingOverflow(t[j])
                                if overflow { high &+= 1 }
                                (low, overflow) = low.addingReportingOverflow(carry)
                                if overflow { high &+= 1 }
                                t[j] = low
                                carry = high
                            }
                            var overflow = false
                            (t[count], overflow) = t[count].addingReportingOverflow(carry)
                            t[count + 1] &+= overflow ? 1 : 0

                            let m = t[0] &* n0inv
                            carry = 0
                            for j in 0 ..< count {
                                var (high, low) = m.multipliedFullWidth(by: n[j])
                                var innerOverflow = false
                                (low, innerOverflow) = low.addingReportingOverflow(t[j])
                                if innerOverflow { high &+= 1 }
                                (low, innerOverflow) = low.addingReportingOverflow(carry)
                                if innerOverflow { high &+= 1 }
                                t[j] = low
                                carry = high
                            }
                            (t[count], overflow) = t[count].addingReportingOverflow(carry)
                            t[count + 1] &+= overflow ? 1 : 0

                            for j in 0 ... count { t[j] = t[j + 1] }
                            t[count + 1] = 0
                        }
                        needsSubtraction = t[count] != 0
                    }
                }
            }
        }

        var result = Array(t[0 ..< count])
        if needsSubtraction || Self.compare(result, n) >= 0 {
            result = Self.subtract(result, n)
        }
        return result
    }

    /// `(lhs * rhs) mod N`, both operands already reduced.
    func multiply(_ lhs: BigUInt, _ rhs: BigUInt) -> BigUInt {
        let montgomeryLeft = montgomeryMultiply(padded(lhs), rSquared)
        return BigUInt(limbs: montgomeryMultiply(montgomeryLeft, padded(rhs)))
    }

    /// `(lhs - rhs) mod N`, both operands already reduced.
    func subtract(_ lhs: BigUInt, _ rhs: BigUInt) -> BigUInt {
        if BigUInt.compare(lhs, rhs) >= 0 { return lhs - rhs }
        return modulus - (rhs - lhs)
    }

    /// `base^exponent mod N`. `base` must already be reduced; `exponent` has no
    /// width limit, which matters because SRP's is `a + u * x`.
    func power(_ base: BigUInt, _ exponent: BigUInt) -> BigUInt {
        guard exponent.bitWidth > 0 else { return BigUInt(1) }
        let montgomeryBase = montgomeryMultiply(padded(base), rSquared)
        var result = one
        for index in stride(from: exponent.bitWidth - 1, through: 0, by: -1) {
            result = montgomeryMultiply(result, result)
            if exponent.bit(at: index) {
                result = montgomeryMultiply(result, montgomeryBase)
            }
        }
        var plain = [UInt64](repeating: 0, count: limbCount)
        plain[0] = 1
        return BigUInt(limbs: montgomeryMultiply(result, plain))
    }
}
