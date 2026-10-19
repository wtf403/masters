import Foundation

/// Metal Shading Language source for the window warp.
///
/// The shader is compiled at runtime rather than bundled as a `.metal` file. The
/// reason is practical: a bundled library is compiled by the build system, which
/// needs the Metal toolchain component installed, and it makes the shader impossible
/// to build on a machine that has Xcode but not that component. Compiling from source
/// keeps one copy of the shader, needs no build-system support, and costs a few
/// milliseconds once at startup. Moving it back to a bundled library is a small change
/// once the toolchain is guaranteed present.
enum WarpShader {
    static let source = #"""
    #include <metal_stdlib>
    using namespace metal;

    // Uniforms shared with Swift. Every field is a float4 or float4x4 so the Swift
    // and Metal structs have identical layout without manual padding.
    struct WarpUniforms {
        // Off-axis projection for the current eye position, in the screen frame.
        float4x4 projection;
        // Head position in the screen frame, metres. w unused.
        float4 head;
        // xy = screen half width and half height in metres, z = near plane, w = far plane.
        float4 screen;
        // x = content plane distance in metres, y = parallax scale, z = parallax clamp,
        // w = 1 when a depth texture is bound, 0 otherwise.
        float4 params;
        // x = debug mode (0 off, 2 depth, 3 full screen), yzw unused.
        float4 debug;
    };

    struct VertexOut {
        float4 position [[position]];
        float2 uv;
    };

    // Unit quad corners in {-1, 1} for a four-vertex triangle strip.
    static inline float2 quadCorner(uint vertexID) {
        return float2(float((vertexID << 1) & 2), float(vertexID & 2)) - 1.0;
    }

    // Projected-plane path.
    //
    // The content is a rectangle placed `planeDistance` behind the screen and grown so
    // that it exactly covers the screen rectangle when the viewer is centred. Drawing
    // it with the off-axis projection makes the screen a window onto that plane: the
    // visible portion is whatever the frustum admits, so moving the head reveals a
    // different part of the image with correct perspective.
    vertex VertexOut planeVertex(uint vertexID [[vertex_id]],
                                 constant WarpUniforms &u [[buffer(0)]]) {
        float2 corner = quadCorner(vertexID);
        float eyeDistance = max(u.head.z, 0.001);
        float planeDistance = max(u.params.x, 0.001);
        // Grow the plane so its intersection with the screen rectangle is the image.
        float grow = (eyeDistance + planeDistance) / eyeDistance;
        float3 point = float3(corner * u.screen.xy * grow, -planeDistance);

        VertexOut out;
        out.position = u.projection * float4(point - u.head.xyz, 1.0);
        out.uv = corner * 0.5 + 0.5;
        return out;
    }

    // Fragment-warp path: the quad is the screen itself, so it always fills the display
    // and the displacement happens in the texture lookup. This is the cheap reference
    // implementation, kept for comparison against the projected-plane path.
    vertex VertexOut warpVertex(uint vertexID [[vertex_id]]) {
        float2 corner = quadCorner(vertexID);
        VertexOut out;
        out.position = float4(corner, 0.0, 1.0);
        out.uv = corner * 0.5 + 0.5;
        return out;
    }

    // Displacement applied to the sampled coordinate.
    //
    // Undisplaced at zero head offset, growing as the viewer moves off centre and as
    // the content sits closer. The magnitude is clamped so the warp cannot pull texture
    // from beyond the image and tear the edges.
    static inline float2 warpOffset(constant WarpUniforms &u, float depthSample) {
        float z = u.params.x;
        if (u.params.w > 0.5) {
            z = mix(u.screen.w, u.screen.z, depthSample);
        }
        z = max(z, 0.001);
        float2 offset = (u.head.xy / z) * u.params.y;
        float limit = max(u.params.z, 0.0);
        return clamp(offset, float2(-limit), float2(limit));
    }

    static inline float4 shade(VertexOut in,
                               texture2d<float> colour,
                               texture2d<float> depth,
                               constant WarpUniforms &u,
                               sampler s,
                               float2 uv) {
        // Depth view: show the depth track as greyscale, near is white.
        if (u.debug.x > 1.5 && u.debug.x < 2.5 && u.params.w > 0.5) {
            float d = depth.sample(s, in.uv).r;
            return float4(d, d, d, 1.0);
        }
        return colour.sample(s, uv);
    }

    fragment float4 planeFragment(VertexOut in [[stage_in]],
                                  texture2d<float> colour [[texture(0)]],
                                  texture2d<float> depth [[texture(1)]],
                                  constant WarpUniforms &u [[buffer(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float2 uv = in.uv;
        if (u.params.w > 0.5) {
            uv += warpOffset(u, depth.sample(s, in.uv).r);
        }
        return shade(in, colour, depth, u, s, uv);
    }

    fragment float4 warpFragment(VertexOut in [[stage_in]],
                                 texture2d<float> colour [[texture(0)]],
                                 texture2d<float> depth [[texture(1)]],
                                 constant WarpUniforms &u [[buffer(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float d = u.params.w > 0.5 ? depth.sample(s, in.uv).r : 1.0;
        float2 uv = in.uv + warpOffset(u, d);
        return shade(in, colour, depth, u, s, uv);
    }
    """#
}
