import CoreGraphics

/// Smoothing and simplification of the pen stroke (SPEC §5.13 "Freehand pen
/// ... smoothed stroke"): smooth, then Ramer–Douglas–Peucker before saving.
/// Pure, no AppKit: operates only on `[CGPoint]` in page space.
enum InkSmoothing {
    /// Simplifies a polyline with Ramer–Douglas–Peucker: drops the points
    /// that deviate less than `tolerance` from the chord between the two
    /// endpoints of the stretch that contains them. The endpoints of the
    /// original stroke are always kept (point count reduced, endpoints kept).
    static func simplify(_ points: [CGPoint], tolerance: CGFloat) -> [CGPoint] {
        guard points.count > 2, tolerance > 0 else { return points }
        var keep = [Bool](repeating: false, count: points.count)
        keep[0] = true
        keep[points.count - 1] = true
        simplifySegment(points, from: 0, to: points.count - 1, tolerance: tolerance, keep: &keep)
        return points.indices.filter { keep[$0] }.map { points[$0] }
    }

    private static func simplifySegment(_ points: [CGPoint], from: Int, to: Int, tolerance: CGFloat, keep: inout [Bool]) {
        guard to > from + 1 else { return }
        var maxDistance: CGFloat = 0
        var splitIndex = from
        for index in (from + 1) ..< to {
            let distance = AnnotationGeometry.distance(from: points[index], toSegment: points[from], points[to])
            if distance > maxDistance {
                maxDistance = distance
                splitIndex = index
            }
        }
        guard maxDistance > tolerance else { return }
        keep[splitIndex] = true
        simplifySegment(points, from: from, to: splitIndex, tolerance: tolerance, keep: &keep)
        simplifySegment(points, from: splitIndex, to: to, tolerance: tolerance, keep: &keep)
    }

    /// Catmull-Rom smoothing: resamples each segment of the simplified
    /// polyline into `samplesPerSegment` intermediate points, for a soft
    /// stroke instead of an angular one (SPEC "smoothed stroke"). Called
    /// after `simplify`, before building the annotation
    /// (`AnnotationController`).
    static func smooth(_ points: [CGPoint], samplesPerSegment: Int = 8) -> [CGPoint] {
        guard points.count > 2 else { return points }
        var result: [CGPoint] = [points[0]]
        for index in 0 ..< (points.count - 1) {
            let p0 = index > 0 ? points[index - 1] : points[index]
            let p1 = points[index]
            let p2 = points[index + 1]
            let p3 = index + 2 < points.count ? points[index + 2] : p2
            for step in 1 ... samplesPerSegment {
                let t = CGFloat(step) / CGFloat(samplesPerSegment)
                result.append(catmullRom(p0, p1, p2, p3, t))
            }
        }
        return result
    }

    private static func catmullRom(_ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint, _ t: CGFloat) -> CGPoint {
        let t2 = t * t
        let t3 = t2 * t
        func component(_ a: CGFloat, _ b: CGFloat, _ c: CGFloat, _ d: CGFloat) -> CGFloat {
            0.5 * ((2 * b) + (-a + c) * t + (2 * a - 5 * b + 4 * c - d) * t2 + (-a + 3 * b - 3 * c + d) * t3)
        }
        return CGPoint(x: component(p0.x, p1.x, p2.x, p3.x), y: component(p0.y, p1.y, p2.y, p3.y))
    }
}
