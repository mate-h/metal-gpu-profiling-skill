// A tiny Metal app with labeled passes, for checking that capture, replay and recording work on
// this machine: one compute pass that writes a noise texture, one render pass that draws a
// fullscreen triangle sampling it into an offscreen target. Runs until killed (or for SECONDS).
//
//   MTL_CAPTURE_ENABLED=1 swift run -c release metal-debug-sample
import Foundation
import Metal

let source = """
#include <metal_stdlib>
using namespace metal;

kernel void noise_kernel(texture2d<float, access::write> out [[texture(0)]],
                         constant float &t [[buffer(0)]],
                         uint2 gid [[thread_position_in_grid]]) {
    float2 p = float2(gid) / float2(out.get_width(), out.get_height());
    float v = 0;
    for (int i = 1; i < 48; i++) {
        v += sin(p.x * i * 13.1 + t) * cos(p.y * i * 7.7 - t) / i;
    }
    out.write(float4(v, v * 0.5, 1 - v, 1), gid);
}

struct VOut { float4 pos [[position]]; float2 uv; };

vertex VOut fullscreen_vertex(uint vid [[vertex_id]]) {
    float2 uv = float2((vid << 1) & 2, vid & 2);
    return { float4(uv * 2 - 1, 0, 1), uv };
}

fragment float4 composite_fragment(VOut in [[stage_in]], texture2d<float> noise [[texture(0)]]) {
    constexpr sampler s(filter::linear);
    float4 c = 0;
    for (int i = 0; i < 16; i++) {
        c += noise.sample(s, in.uv + float2(i, -i) * 0.002);
    }
    return c / 16;
}
"""

guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
    fatalError("no Metal device")
}
let library = try device.makeLibrary(source: source, options: nil)
let compute = try device.makeComputePipelineState(function: library.makeFunction(name: "noise_kernel")!)
let rpd = MTLRenderPipelineDescriptor()
rpd.label = "composite"
rpd.vertexFunction = library.makeFunction(name: "fullscreen_vertex")
rpd.fragmentFunction = library.makeFunction(name: "composite_fragment")
rpd.colorAttachments[0].pixelFormat = .rgba8Unorm
let render = try device.makeRenderPipelineState(descriptor: rpd)

let size = 2048
func texture(_ format: MTLPixelFormat, _ usage: MTLTextureUsage) -> MTLTexture {
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: size, height: size, mipmapped: false)
    d.usage = usage; d.storageMode = .private
    return device.makeTexture(descriptor: d)!
}
let noise = texture(.rgba16Float, [.shaderWrite, .shaderRead])
let target = texture(.rgba8Unorm, [.renderTarget])

let limit = Double(ProcessInfo.processInfo.environment["SECONDS"] ?? "") ?? .infinity
let start = Date()
var frame = 0
print("metal-debug-sample pid \(getpid()) on \(device.name)")
while Date().timeIntervalSince(start) < limit {
    autoreleasepool {
        let cb = queue.makeCommandBuffer()!
        cb.label = "frame \(frame)"
        var t = Float(frame) * 0.016
        let ce = cb.makeComputeCommandEncoder()!
        ce.label = "noise_pass"
        ce.setComputePipelineState(compute)
        ce.setTexture(noise, index: 0)
        ce.setBytes(&t, length: 4, index: 0)
        ce.dispatchThreads(MTLSize(width: size, height: size, depth: 1),
                           threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
        ce.endEncoding()
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        let re = cb.makeRenderCommandEncoder(descriptor: pass)!
        re.label = "composite_pass"
        re.setRenderPipelineState(render)
        re.setFragmentTexture(noise, index: 0)
        re.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        re.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        frame += 1
        usleep(4_000)
    }
}
