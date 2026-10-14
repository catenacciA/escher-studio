#pragma once
#include "Art.hpp"
#include <Metal/Metal.hpp>
#include <QuartzCore/QuartzCore.hpp>
#include <functional>
#include <string>

namespace escher {
struct Pixels {
    unsigned width = 0, height = 0;
    std::vector<uint8_t> rgba;
};

struct View {
    Vec center, span;  // world units
    double pixels = 1; // drawable pixels per world unit
    double dot = 1;    // drawable pixels per point
    bool original = false, handles = true;
    int selected = -1;
};

// The rectangular repeat unit of the coloured pattern (period: the 2 × 2 supercell), in world
// units.
Vec repeatSize(const State &state);

// Decodes an artwork texture into 8-bit sRGB RGBA; supplied by the platform layer.
using ImageLoader = std::function<Pixels(const Artwork &)>;

class Renderer {
  public:
    Renderer(const std::string &shader, ImageLoader loader);

    MTL::Device *device() const { return device_.get(); }

    const Mesh &mesh() const { return mesh_; }

    const std::vector<Float2> &mapped() const { return mapped_; }

    const Art &art() const { return art_; }

    // Regenerates the undeformed material when the artwork, group, seed or palette changes.
    void setArtwork(const State &state);
    // Maps the mesh on the CPU from cached basis weights; false if it fails the fold check.
    bool evaluate(const State &state, const std::vector<Vec> &loads, std::vector<Float2> &mapped);
    void accept(std::vector<Float2> mapped);
    bool update(const State &state, const std::vector<Vec> &loads);
    // Encodes any pending tile render with the view in one command buffer; does not wait.
    void draw(CA::MetalDrawable *drawable, MTL::RenderPassDescriptor *pass, const View &view,
              const State &state);
    Pixels render(const View &view, unsigned width, unsigned height, const State &state);
    Pixels exportTile(const State &state, unsigned width = 0);
    double flush(); // Renders a pending tile synchronously; returns GPU milliseconds.
    double basisError(const State &state) const;

  private:
    void rebuildBasis(const State &state);
    void encodeCell(MTL::CommandBuffer *commands);
    void encodeView(MTL::RenderCommandEncoder *encoder, const View &view, const State &state);
    NS::SharedPtr<MTL::Device> device_;
    NS::SharedPtr<MTL::CommandQueue> queue_;
    NS::SharedPtr<MTL::ComputePipelineState> compute_;
    NS::SharedPtr<MTL::RenderPipelineState> artPipeline_, tilePipeline_, screenPipeline_,
        offscreenPipeline_;
    NS::SharedPtr<MTL::Buffer> points_, indices_, basis_;
    NS::SharedPtr<MTL::Texture> original_, cell_;
    Mesh mesh_{128};
    Art art_;
    std::vector<Float2> mapped_;
    std::vector<Vec> cachedSources_;
    double cachedSigma_ = -1;
    ImageLoader loader_;
    int cachedGroup_ = -1, artGroup_ = -1, artPalette_ = -1, artArtwork_ = -2;
    uint32_t artSeed_ = 0;
    bool cellDirty_ = true;
    int supercell_ = 2;
};
} // namespace escher
