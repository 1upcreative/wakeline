import simd

typealias V2 = SIMD2<Float>
typealias V3 = SIMD3<Float>
typealias V4 = SIMD4<Float>
typealias M4 = float4x4

enum Mat {
    /// Right-handed perspective with Metal's 0...1 clip depth.
    static func perspective(fovY: Float, aspect: Float, near: Float, far: Float) -> M4 {
        let y = 1 / tan(fovY * 0.5)
        let z = far / (near - far)
        return M4(columns: (V4(y / aspect, 0, 0, 0), V4(0, y, 0, 0), V4(0, 0, z, -1), V4(0, 0, z * near, 0)))
    }

    static func lookAt(eye: V3, target: V3, up: V3) -> M4 {
        let f = normalize(target - eye)
        let s = normalize(cross(f, up))
        let u = cross(s, f)
        return M4(columns: (V4(s.x, u.x, -f.x, 0), V4(s.y, u.y, -f.y, 0), V4(s.z, u.z, -f.z, 0),
                            V4(-dot(s, eye), -dot(u, eye), dot(f, eye), 1)))
    }

    static func translate(_ t: V3) -> M4 {
        var m = matrix_identity_float4x4
        m.columns.3 = V4(t, 1)
        return m
    }

    static func scale(_ k: Float) -> M4 {
        var m = matrix_identity_float4x4
        m.columns.0.x = k; m.columns.1.y = k; m.columns.2.z = k
        return m
    }

    static func rotateX(_ a: Float) -> M4 {
        let c = cos(a), s = sin(a)
        return M4(columns: (V4(1, 0, 0, 0), V4(0, c, s, 0), V4(0, -s, c, 0), V4(0, 0, 0, 1)))
    }

    static func rotateZ(_ a: Float) -> M4 {
        let c = cos(a), s = sin(a)
        return M4(columns: (V4(c, s, 0, 0), V4(-s, c, 0, 0), V4(0, 0, 1, 0), V4(0, 0, 0, 1)))
    }

    /// Bike basis: model -Z maps onto `forward`, model +Y stays up.
    static func heading(forward f: V3, position p: V3) -> M4 {
        let right = normalize(cross(f, V3(0, 1, 0)))
        return M4(columns: (V4(right, 0), V4(0, 1, 0, 0), V4(-f, 0), V4(p, 1)))
    }
}

@inline(__always) func clampf(_ x: Float, _ a: Float, _ b: Float) -> Float { min(max(x, a), b) }
@inline(__always) func mixf(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }
@inline(__always) func smooth(_ a: Float, _ b: Float, _ x: Float) -> Float {
    let t = clampf((x - a) / (b - a), 0, 1)
    return t * t * (3 - 2 * t)
}
/// Frame-rate independent exponential approach.
@inline(__always) func damp(_ rate: Float, _ dt: Float) -> Float { 1 - exp(-rate * dt) }
