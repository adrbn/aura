#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

/// Shows the layer as blocks of `size` points, each the colour of its centre. Used by the
/// onboarding's "library found" screen, where the covers sharpen as the size falls to 1.
[[ stitchable ]] half4 auraPixellate(float2 position, SwiftUI::Layer layer, float size) {
    if (size <= 1.0) { return layer.sample(position); }
    float2 centre = floor(position / size) * size + size * 0.5;
    return layer.sample(centre);
}
