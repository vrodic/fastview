import Foundation

/// RGB pixels as floats (0...255), row-major, top-left origin.
public struct RGBImage {
    public var width: Int
    public var height: Int
    public var pixels: [Float]

    public init(width: Int, height: Int, pixels: [Float]) {
        self.width = width
        self.height = height
        self.pixels = pixels
    }
}

/// Fills the hole of an image from the rest of it: multi-scale PatchMatch
/// (nearest-neighbour patch search) with patch voting, coarse to fine.
public enum PatchMatchInpainter {
    private static let radius = 3          // 7x7 patches
    /// The pyramid goes down until the hole is about this many pixels across, so the
    /// coarsest fill is decided by its surroundings rather than by the starting guess.
    private static let coarsestHoleSide = 6

    /// `hole` is one byte per pixel, non-zero where pixels are filled in.
    /// Pixels outside the hole are returned unchanged.
    public static func inpaint(_ image: RGBImage, hole: [UInt8], isCancelled: () -> Bool = { false }) -> RGBImage {
        var levels: [(image: RGBImage, hole: [UInt8])] = [(image, hole)]
        while holeExtent(levels[levels.count - 1].hole, width: levels[levels.count - 1].image.width) > coarsestHoleSide,
              min(levels[levels.count - 1].image.width, levels[levels.count - 1].image.height) > 4 * radius + 2,
              levels.count < 10 {
            levels.append(downsample(levels[levels.count - 1].image, levels[levels.count - 1].hole))
        }

        var current = levels[levels.count - 1].image
        diffuseFill(&current, hole: levels[levels.count - 1].hole)
        var nnf: [Int32]? = nil

        for levelIndex in stride(from: levels.count - 1, through: 0, by: -1) {
            if isCancelled() { break }
            let level = levels[levelIndex]
            var img = level.image
            if levelIndex != levels.count - 1 {
                // Known pixels come from this level; the hole starts from the upsampled coarser fill.
                let up = upsample(current, toWidth: img.width, height: img.height)
                for i in 0..<(img.width * img.height) where level.hole[i] != 0 {
                    img.pixels[i * 3] = up.pixels[i * 3]
                    img.pixels[i * 3 + 1] = up.pixels[i * 3 + 1]
                    img.pixels[i * 3 + 2] = up.pixels[i * 3 + 2]
                }
            }
            let iterations = levelIndex == 0 ? 3 : (levelIndex == levels.count - 1 ? 12 : 6)
            guard let solved = solveLevel(&img, hole: level.hole, previousNNF: nnf, previousWidth: current.width, previousHeight: current.height, iterations: iterations, isFinest: levelIndex == 0, isCancelled: isCancelled) else {
                // No known patch to copy from: keep the diffused fill.
                diffuseFill(&img, hole: level.hole)
                current = img
                nnf = nil
                continue
            }
            nnf = solved
            current = img
        }
        return current
    }

    // MARK: - One pyramid level

    /// Runs EM iterations (PatchMatch search, then voting) on one level; returns the nearest-neighbour field.
    private static func solveLevel(_ img: inout RGBImage, hole: [UInt8], previousNNF: [Int32]?, previousWidth: Int, previousHeight: Int, iterations: Int, isFinest: Bool, isCancelled: () -> Bool) -> [Int32]? {
        let w = img.width, h = img.height, r = radius
        guard w > 2 * r + 1, h > 2 * r + 1 else { return nil }

        // Target patches: centres within `r` of the hole. Sources: patches entirely known and inside the image.
        let target = dilate(hole, width: w, height: h, radius: r)
        var sources: [Int32] = []
        var isSource = [Bool](repeating: false, count: w * h)
        for y in r..<(h - r) {
            for x in r..<(w - r) where target[y * w + x] == 0 {
                isSource[y * w + x] = true
                sources.append(Int32(y * w + x))
            }
        }
        guard !sources.isEmpty else { return nil }

        var targets: [Int32] = []
        for i in 0..<(w * h) where target[i] != 0 { targets.append(Int32(i)) }

        var rng = SystemRandomNumberGenerator()
        var nnf = [Int32](repeating: -1, count: w * h)
        var cost = [Float](repeating: .greatestFiniteMagnitude, count: w * h)

        // Initialise from the coarser level's field where it lands on a source, otherwise at random.
        for t in targets {
            let p = Int(t)
            var q = -1
            if let prev = previousNNF {
                let px = min(previousWidth - 1, (p % w) / 2), py = min(previousHeight - 1, (p / w) / 2)
                let pq = Int(prev[py * previousWidth + px])
                if pq >= 0 {
                    let qx = (pq % previousWidth) * 2 + (p % w) % 2
                    let qy = (pq / previousWidth) * 2 + (p / w) % 2
                    if qx < w, qy < h, isSource[qy * w + qx] { q = qy * w + qx }
                }
            }
            if q < 0 { q = Int(sources[Int.random(in: 0..<sources.count, using: &rng)]) }
            nnf[p] = Int32(q)
        }

        for iteration in 0..<iterations {
            if isCancelled() { return nnf }
            img.pixels.withUnsafeBufferPointer { px in
                for t in targets { cost[Int(t)] = distance(px, w: w, h: h, p: Int(t), q: Int(nnf[Int(t)]), cutoff: .greatestFiniteMagnitude) }

                for pass in 0..<2 {
                    let forward = (iteration + pass) % 2 == 0
                    let step = forward ? 1 : -1
                    var k = forward ? 0 : targets.count - 1
                    while k >= 0 && k < targets.count {
                        let p = Int(targets[k])
                        let x = p % w, y = p / w
                        var best = Int(nnf[p]), bestCost = cost[p]

                        // Propagation: the neighbour's match, shifted by one.
                        for (nx, ny) in [(x - step, y), (x, y - step)] where nx >= 0 && nx < w && ny >= 0 && ny < h {
                            let nq = Int(nnf[ny * w + nx])
                            guard nq >= 0 else { continue }
                            let qx = nq % w + (x - nx), qy = nq / w + (y - ny)
                            guard qx >= 0, qx < w, qy >= 0, qy < h else { continue }
                            let q = qy * w + qx
                            guard isSource[q], q != best else { continue }
                            let c = distance(px, w: w, h: h, p: p, q: q, cutoff: bestCost)
                            if c < bestCost { best = q; bestCost = c }
                        }

                        // Random search in shrinking windows around the current match.
                        var searchRadius = max(w, h)
                        while searchRadius >= 1 {
                            let bx = best % w, by = best / w
                            let qx = min(w - 1 - r, max(r, bx + Int.random(in: -searchRadius...searchRadius, using: &rng)))
                            let qy = min(h - 1 - r, max(r, by + Int.random(in: -searchRadius...searchRadius, using: &rng)))
                            let q = qy * w + qx
                            if isSource[q], q != best {
                                let c = distance(px, w: w, h: h, p: p, q: q, cutoff: bestCost)
                                if c < bestCost { best = q; bestCost = c }
                            }
                            searchRadius /= 2
                        }

                        nnf[p] = Int32(best)
                        cost[p] = bestCost
                        k += step
                    }
                }
            }
            // The last pass at full size favours the closest matches, keeping texture sharp.
            vote(&img, hole: hole, nnf: nnf, cost: cost, percentile: isFinest && iteration == iterations - 1 ? 0.1 : 0.75)
        }
        return nnf
    }

    /// Sum of squared differences between the patches centred at `p` and `q`, stopping once over `cutoff`.
    /// Parts of the target patch outside the image are skipped (`q` is always a full patch).
    @inline(__always)
    private static func distance(_ px: UnsafeBufferPointer<Float>, w: Int, h: Int, p: Int, q: Int, cutoff: Float) -> Float {
        let r = radius
        let x = p % w, y = p / w
        let dq = q - p
        var sum: Float = 0
        for dy in -r...r {
            let ty = y + dy
            if ty < 0 || ty >= h { continue }
            for dx in -r...r {
                let tx = x + dx
                if tx < 0 || tx >= w { continue }
                let a = (ty * w + tx) * 3
                let b = a + dq * 3
                let d0 = px[a] - px[b], d1 = px[a + 1] - px[b + 1], d2 = px[a + 2] - px[b + 2]
                sum += d0 * d0 + d1 * d1 + d2 * d2
            }
            if sum > cutoff { return sum }
        }
        return sum
    }

    /// Each hole pixel becomes the weighted mean of what every patch covering it copies there.
    private static func vote(_ img: inout RGBImage, hole: [UInt8], nnf: [Int32], cost: [Float], percentile: Double) {
        let w = img.width, h = img.height, r = radius
        // Similarity weights exp(-d / 2σ²), σ² from a percentile of the match distances (Wexler et al.).
        var dists: [Float] = []
        for i in 0..<(w * h) where nnf[i] >= 0 { dists.append(cost[i]) }
        dists.sort()
        let sigma2 = max(1, dists.isEmpty ? 1 : dists[min(dists.count - 1, Int(Double(dists.count) * percentile))])
        var out = img.pixels
        img.pixels.withUnsafeBufferPointer { px in
            for y in 0..<h {
                for x in 0..<w where hole[y * w + x] != 0 {
                    var acc0: Float = 0, acc1: Float = 0, acc2: Float = 0, wsum: Float = 0
                    for dy in -r...r {
                        let py = y + dy
                        if py < 0 || py >= h { continue }
                        for dx in -r...r {
                            let pxx = x + dx
                            if pxx < 0 || pxx >= w { continue }
                            let p = py * w + pxx
                            let q = Int(nnf[p])
                            if q < 0 { continue }
                            let sx = q % w - dx, sy = q / w - dy
                            let s = (sy * w + sx) * 3
                            let weight = exp(-cost[p] / (2 * sigma2))
                            acc0 += px[s] * weight
                            acc1 += px[s + 1] * weight
                            acc2 += px[s + 2] * weight
                            wsum += weight
                        }
                    }
                    if wsum > 0 {
                        let i = (y * w + x) * 3
                        out[i] = acc0 / wsum
                        out[i + 1] = acc1 / wsum
                        out[i + 2] = acc2 / wsum
                    }
                }
            }
        }
        img.pixels = out
    }

    // MARK: - Helpers

    /// Longer side of the hole's bounding box.
    private static func holeExtent(_ hole: [UInt8], width w: Int) -> Int {
        var minX = Int.max, maxX = -1, minY = Int.max, maxY = -1
        for i in hole.indices where hole[i] != 0 {
            minX = min(minX, i % w); maxX = max(maxX, i % w)
            minY = min(minY, i / w); maxY = max(maxY, i / w)
        }
        return maxX < 0 ? 0 : max(maxX - minX, maxY - minY) + 1
    }

    /// Square max filter of a byte mask.
    static func dilate(_ mask: [UInt8], width w: Int, height h: Int, radius r: Int) -> [UInt8] {
        guard r > 0 else { return mask }
        var horizontal = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            // Two sweeps: distance to the nearest set pixel to the left and to the right.
            var dist = Int.max / 2
            for x in 0..<w {
                dist = mask[y * w + x] != 0 ? 0 : dist + 1
                if dist <= r { horizontal[y * w + x] = 1 }
            }
            dist = Int.max / 2
            for x in stride(from: w - 1, through: 0, by: -1) {
                dist = mask[y * w + x] != 0 ? 0 : dist + 1
                if dist <= r { horizontal[y * w + x] = 1 }
            }
        }
        var out = [UInt8](repeating: 0, count: w * h)
        for x in 0..<w {
            var dist = Int.max / 2
            for y in 0..<h {
                dist = horizontal[y * w + x] != 0 ? 0 : dist + 1
                if dist <= r { out[y * w + x] = 1 }
            }
            dist = Int.max / 2
            for y in stride(from: h - 1, through: 0, by: -1) {
                dist = horizontal[y * w + x] != 0 ? 0 : dist + 1
                if dist <= r { out[y * w + x] = 1 }
            }
        }
        return out
    }

    /// Halves the image, averaging known pixels only; a coarse pixel is hole if any of its pixels is.
    private static func downsample(_ img: RGBImage, _ hole: [UInt8]) -> (image: RGBImage, hole: [UInt8]) {
        let w = (img.width + 1) / 2, h = (img.height + 1) / 2
        var pixels = [Float](repeating: 0, count: w * h * 3)
        var outHole = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                var s0: Float = 0, s1: Float = 0, s2: Float = 0, n: Float = 0
                var anyHole = false
                for sy in (2 * y)..<min(img.height, 2 * y + 2) {
                    for sx in (2 * x)..<min(img.width, 2 * x + 2) {
                        let i = sy * img.width + sx
                        if hole[i] != 0 { anyHole = true; continue }
                        s0 += img.pixels[i * 3]; s1 += img.pixels[i * 3 + 1]; s2 += img.pixels[i * 3 + 2]
                        n += 1
                    }
                }
                let o = y * w + x
                if anyHole { outHole[o] = 1 }
                if n > 0 {
                    pixels[o * 3] = s0 / n; pixels[o * 3 + 1] = s1 / n; pixels[o * 3 + 2] = s2 / n
                }
            }
        }
        return (RGBImage(width: w, height: h, pixels: pixels), outHole)
    }

    /// Bilinear resize.
    static func upsample(_ img: RGBImage, toWidth w: Int, height h: Int) -> RGBImage {
        var pixels = [Float](repeating: 0, count: w * h * 3)
        let sx = Float(img.width) / Float(w), sy = Float(img.height) / Float(h)
        for y in 0..<h {
            let fy = max(0, (Float(y) + 0.5) * sy - 0.5)
            let y0 = min(img.height - 1, Int(fy)), y1 = min(img.height - 1, y0 + 1)
            let ty = fy - Float(y0)
            for x in 0..<w {
                let fx = max(0, (Float(x) + 0.5) * sx - 0.5)
                let x0 = min(img.width - 1, Int(fx)), x1 = min(img.width - 1, x0 + 1)
                let tx = fx - Float(x0)
                for c in 0..<3 {
                    let a = img.pixels[(y0 * img.width + x0) * 3 + c], b = img.pixels[(y0 * img.width + x1) * 3 + c]
                    let d = img.pixels[(y1 * img.width + x0) * 3 + c], e = img.pixels[(y1 * img.width + x1) * 3 + c]
                    pixels[(y * w + x) * 3 + c] = (a * (1 - tx) + b * tx) * (1 - ty) + (d * (1 - tx) + e * tx) * ty
                }
            }
        }
        return RGBImage(width: w, height: h, pixels: pixels)
    }

    /// Fills the hole from its edge inwards with the mean of already-filled neighbours.
    private static func diffuseFill(_ img: inout RGBImage, hole: [UInt8]) {
        let w = img.width, h = img.height
        var filled = hole.map { $0 == 0 }
        var remaining = filled.filter { !$0 }.count
        while remaining > 0 {
            var next = filled
            var progressed = false
            for y in 0..<h {
                for x in 0..<w where !filled[y * w + x] {
                    var s0: Float = 0, s1: Float = 0, s2: Float = 0, n: Float = 0
                    for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] where nx >= 0 && nx < w && ny >= 0 && ny < h && filled[ny * w + nx] {
                        let i = (ny * w + nx) * 3
                        s0 += img.pixels[i]; s1 += img.pixels[i + 1]; s2 += img.pixels[i + 2]; n += 1
                    }
                    if n > 0 {
                        let i = (y * w + x) * 3
                        img.pixels[i] = s0 / n; img.pixels[i + 1] = s1 / n; img.pixels[i + 2] = s2 / n
                        next[y * w + x] = true
                        remaining -= 1
                        progressed = true
                    }
                }
            }
            filled = next
            if !progressed { break }
        }
    }
}
