// qLOOKS — décodeur LZMA (flux brut + 5 octets de propriétés, comme dans les archives 7z) : sert à lire les en-têtes compressés.
import Foundation

enum LZMA {
    static func decode(props: [UInt8], input: [UInt8], outSize: Int) -> [UInt8]? {
        guard props.count >= 5, outSize >= 0, outSize < 1 << 28, input.count >= 5 else { return nil }
        var d = Int(props[0])
        guard d < 225 else { return nil }
        let lc = d % 9; d /= 9
        let lp = d % 5, pb = d / 5

        var range: UInt32 = 0xFFFF_FFFF
        var code: UInt32 = 0
        var ip = 1                                                     // le premier octet est toujours 0
        for _ in 0..<4 { code = code << 8 | UInt32(input[ip]); ip += 1 }
        var failed = false

        func norm() {
            if range < 1 << 24 {
                range <<= 8
                if ip < input.count { code = code << 8 | UInt32(input[ip]); ip += 1 } else { failed = true; code <<= 8 }
            }
        }
        func bit(_ p: inout [UInt16], _ i: Int) -> Int {
            let v = UInt32(p[i])
            let bound = (range >> 11) &* v
            if code < bound { range = bound; p[i] = UInt16(v + ((2048 - v) >> 5)); norm(); return 0 }
            range -= bound; code -= bound; p[i] = UInt16(v - (v >> 5)); norm(); return 1
        }
        func direct(_ n: Int) -> UInt32 {
            var r: UInt32 = 0
            for _ in 0..<n {
                range >>= 1
                code = code &- range
                let t = 0 &- (code >> 31)
                code = code &+ (range & t)
                r = r << 1 &+ (t &+ 1)
                norm()
            }
            return r
        }
        func tree(_ p: inout [UInt16], _ base: Int, _ bits: Int) -> Int {
            var m = 1
            for _ in 0..<bits { m = m << 1 | bit(&p, base + m) }
            return m - (1 << bits)
        }
        func revTree(_ p: inout [UInt16], _ base: Int, _ bits: Int) -> Int {
            var m = 1, sym = 0
            for i in 0..<bits { let b = bit(&p, base + m); m = m << 1 | b; sym |= b << i }
            return sym
        }

        var isMatch = [UInt16](repeating: 1024, count: 12 << 4)
        var isRep = [UInt16](repeating: 1024, count: 12), isRepG0 = isRep, isRepG1 = isRep, isRepG2 = isRep
        var isRep0Long = [UInt16](repeating: 1024, count: 12 << 4)
        var posSlot = [UInt16](repeating: 1024, count: 4 << 6)
        var posSpecial = [UInt16](repeating: 1024, count: 115)
        var align = [UInt16](repeating: 1024, count: 16)
        var lenChoice = [UInt16](repeating: 1024, count: 2), repChoice = lenChoice
        var lenLow = [UInt16](repeating: 1024, count: 16 << 3), repLow = lenLow
        var lenMid = lenLow, repMid = lenLow
        var lenHigh = [UInt16](repeating: 1024, count: 256), repHigh = lenHigh
        var lit = [UInt16](repeating: 1024, count: 0x300 << (lc + lp))

        var out = [UInt8](); out.reserveCapacity(outSize)
        var state = 0
        var rep0 = 0, rep1 = 0, rep2 = 0, rep3 = 0

        func length(_ choice: inout [UInt16], _ low: inout [UInt16], _ mid: inout [UInt16], _ high: inout [UInt16], _ ps: Int) -> Int {
            if bit(&choice, 0) == 0 { return tree(&low, ps << 3, 3) }
            if bit(&choice, 1) == 0 { return 8 + tree(&mid, ps << 3, 3) }
            return 16 + tree(&high, 0, 8)
        }

        while out.count < outSize, !failed {
            let ps = out.count & ((1 << pb) - 1)
            if bit(&isMatch, (state << 4) + ps) == 0 {
                let prev = out.last.map { Int($0) } ?? 0
                let base = 0x300 * (((out.count & ((1 << lp) - 1)) << lc) + (prev >> (8 - lc)))
                var sym = 1
                if state >= 7 {
                    guard rep0 < out.count else { return nil }
                    var mb = Int(out[out.count - rep0 - 1])
                    while sym < 0x100 {
                        let mbit = (mb >> 7) & 1; mb <<= 1
                        let b = bit(&lit, base + ((1 + mbit) << 8) + sym)
                        sym = sym << 1 | b
                        if mbit != b { break }
                    }
                }
                while sym < 0x100 { sym = sym << 1 | bit(&lit, base + sym) }
                out.append(UInt8(sym & 255))
                state = state < 4 ? 0 : (state < 10 ? state - 3 : state - 6)
                continue
            }
            var len: Int
            if bit(&isRep, state) == 0 {
                rep3 = rep2; rep2 = rep1; rep1 = rep0
                len = length(&lenChoice, &lenLow, &lenMid, &lenHigh, ps)
                state = state < 7 ? 7 : 10
                let lenState = min(len, 3)
                let slot = tree(&posSlot, lenState << 6, 6)
                if slot < 4 { rep0 = slot }
                else {
                    let nb = (slot >> 1) - 1
                    var dist = (2 | (slot & 1)) << nb
                    if slot < 14 {
                        var m = 1, sym = 0
                        for i in 0..<nb { let b = bit(&posSpecial, dist - slot + m); m = m << 1 | b; sym |= b << i }
                        dist += sym
                    } else {
                        dist += Int(direct(nb - 4)) << 4
                        dist += revTree(&align, 0, 4)
                    }
                    rep0 = dist
                    if rep0 == 0xFFFF_FFFF { break }                           // marqueur de fin
                }
            } else {
                if bit(&isRepG0, state) == 0 {
                    if bit(&isRep0Long, (state << 4) + ps) == 0 {
                        state = state < 7 ? 9 : 11
                        guard rep0 < out.count else { return nil }
                        out.append(out[out.count - rep0 - 1]); continue
                    }
                } else {
                    var dist: Int
                    if bit(&isRepG1, state) == 0 { dist = rep1 }
                    else {
                        if bit(&isRepG2, state) == 0 { dist = rep2 } else { dist = rep3; rep3 = rep2 }
                        rep2 = rep1
                    }
                    rep1 = rep0; rep0 = dist
                }
                len = length(&repChoice, &repLow, &repMid, &repHigh, ps)
                state = state < 7 ? 8 : 11
            }
            len += 2
            guard rep0 < out.count else { return nil }
            var n = min(len, outSize - out.count)
            var src = out.count - rep0 - 1
            while n > 0 { out.append(out[src]); src += 1; n -= 1 }
        }
        return failed || out.count != outSize ? nil : out
    }
}
