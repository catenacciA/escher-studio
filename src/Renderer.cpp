#define NS_PRIVATE_IMPLEMENTATION
#define MTL_PRIVATE_IMPLEMENTATION
#define CA_PRIVATE_IMPLEMENTATION
#include "Renderer.hpp"
#include <algorithm>
#include <cmath>
#include <cstring>
#include <stdexcept>

namespace escher {
namespace {
// Layouts mirror resources/Deform.metal.
struct GpuOp {
    float A[4], Ainv[4], t[2], pad[2];
};

struct GpuGroup {
    float M[4], Minv[4];
    uint32_t count, hex;
    float sigma;
    uint32_t pad;
    GpuOp ops[12];
};

struct GpuStyle {
    float centre[24][4];
    int32_t shift[24][4];
    uint32_t color[24][4];
    float tones[6][4];
    float ink[4], paper[4], eye[2][4], line[4];
};

struct GpuView {
    float center[2], span[2], pixels, dot;
    uint32_t original, handles;
    int32_t selected;
    float period;
    uint32_t pad[2];
    float targets[8][4];
};

static_assert(sizeof(GpuGroup) == 48 + 12 * 48, "Group layout");
static_assert(sizeof(GpuStyle) == 3 * 24 * 16 + 6 * 16 + 5 * 16, "Style layout");
static_assert(sizeof(GpuView) == 176, "View layout");

std::string errorMessage(NS::Error *e) {
    return e ? e->localizedDescription()->utf8String() : "Unknown Metal error";
}

NS::String *str(const char *s) {
    return NS::String::string(s, NS::UTF8StringEncoding);
}

void put(float *out, Mat m) {
    out[0] = float(m.a);
    out[1] = float(m.b);
    out[2] = float(m.c);
    out[3] = float(m.d);
}

float linear(float c) {
    return c <= .04045f ? c / 12.92f : std::pow((c + .055f) / 1.055f, 2.4f);
}

void put(float *out, Rgb c) {
    out[0] = linear(c.r);
    out[1] = linear(c.g);
    out[2] = linear(c.b);
    out[3] = 1;
}

GpuGroup gpuGroup(const State &state) {
    const Group &g = groups()[state.group];
    GpuGroup out{};
    Mat m = cellBasis(state);
    put(out.M, m);
    put(out.Minv, inverse(m));
    out.count = uint32_t(g.ops.size());
    out.hex = g.lattice == Lattice::Hexagonal;
    out.sigma = float(state.sigma);
    for (size_t k = 0; k < g.ops.size(); ++k) {
        put(out.ops[k].A, g.ops[k].A);
        put(out.ops[k].Ainv, inverse(g.ops[k].A));
        out.ops[k].t[0] = float(g.ops[k].t.x);
        out.ops[k].t[1] = float(g.ops[k].t.y);
    }
    return out;
}

const unsigned resolution = 2048; // texels across the 2 × 2 supercell

NS::SharedPtr<MTL::Texture> texture(MTL::Device *d, unsigned width, unsigned height, bool mips) {
    auto desc = NS::TransferPtr(MTL::TextureDescriptor::alloc()->init());
    desc->setWidth(width);
    desc->setHeight(height);
    desc->setPixelFormat(MTL::PixelFormatRGBA8Unorm_sRGB);
    desc->setStorageMode(MTL::StorageModeShared);
    desc->setUsage(MTL::TextureUsageRenderTarget | MTL::TextureUsageShaderRead);
    desc->setMipmapLevelCount(mips ? unsigned(std::log2(std::max(width, height))) + 1 : 1);
    auto t = NS::TransferPtr(d->newTexture(desc.get()));
    if (!t)
        throw std::runtime_error("Could not allocate a texture.");
    return t;
}

void check(MTL::CommandBuffer *c, const char *what) {
    c->commit();
    c->waitUntilCompleted();
    if (c->status() != MTL::CommandBufferStatusCompleted)
        throw std::runtime_error(std::string(what) + ": " + errorMessage(c->error()));
}
} // namespace

Vec repeatSize(const State &state) {
    // The shortest horizontal and vertical vectors of the supercell lattice nZ².
    const Mat m = cellBasis(state);
    const int n = supercell(state);
    Vec size{0, 0};
    for (int j = -8; j <= 8; ++j)
        for (int i = -8; i <= 8; ++i) {
            Vec v = m * Vec{double(n * i), double(n * j)};
            if (std::abs(v.y) < 1e-5 && v.x > 1e-5 && (size.x == 0 || v.x < size.x))
                size.x = v.x;
            if (std::abs(v.x) < 1e-5 && v.y > 1e-5 && (size.y == 0 || v.y < size.y))
                size.y = v.y;
        }
    return size;
}

Renderer::Renderer(const std::string &shader, ImageLoader loader) : loader_(std::move(loader)) {
    device_ = NS::TransferPtr(MTL::CreateSystemDefaultDevice());
    if (!device_)
        throw std::runtime_error("Metal is unavailable. Escher Studio needs a Metal-capable Mac.");
    queue_ = NS::TransferPtr(device_->newCommandQueue());
    NS::Error *error = nullptr;
    auto options = NS::TransferPtr(MTL::CompileOptions::alloc()->init());
    options->setFastMathEnabled(false);
    auto library = NS::TransferPtr(device_->newLibrary(str(shader.c_str()), options.get(), &error));
    if (!library)
        throw std::runtime_error("Shader compilation: " + errorMessage(error));
    auto f = NS::TransferPtr(library->newFunction(str("build_basis")));
    compute_ = NS::TransferPtr(device_->newComputePipelineState(f.get(), &error));
    if (!compute_)
        throw std::runtime_error(errorMessage(error));
    auto pipeline = [&](const char *vertex, const char *fragment, MTL::PixelFormat format) {
        auto desc = NS::TransferPtr(MTL::RenderPipelineDescriptor::alloc()->init());
        auto v = NS::TransferPtr(library->newFunction(str(vertex))),
             p = NS::TransferPtr(library->newFunction(str(fragment)));
        desc->setVertexFunction(v.get());
        desc->setFragmentFunction(p.get());
        desc->colorAttachments()->object(0)->setPixelFormat(format);
        auto result = NS::TransferPtr(device_->newRenderPipelineState(desc.get(), &error));
        if (!result)
            throw std::runtime_error(errorMessage(error));
        return result;
    };
    artPipeline_ = pipeline("screen_vertex", "art_fragment", MTL::PixelFormatRGBA8Unorm_sRGB);
    tilePipeline_ = pipeline("tile_vertex", "tile_fragment", MTL::PixelFormatRGBA8Unorm_sRGB);
    screenPipeline_ = pipeline("screen_vertex", "screen_fragment", MTL::PixelFormatBGRA8Unorm_sRGB);
    offscreenPipeline_ =
        pipeline("screen_vertex", "screen_fragment", MTL::PixelFormatRGBA8Unorm_sRGB);
    points_ = NS::TransferPtr(device_->newBuffer(
        mesh_.points.data(), mesh_.points.size() * sizeof(Float2), MTL::ResourceStorageModeShared));
    indices_ = NS::TransferPtr(device_->newBuffer(mesh_.indices.data(),
                                                  mesh_.indices.size() * sizeof(uint32_t),
                                                  MTL::ResourceStorageModeShared));
    original_ = texture(device_.get(), resolution, resolution, true);
    cell_ = texture(device_.get(), resolution, resolution, true);
    mapped_ = mesh_.points;
    setArtwork(State{});
}

void Renderer::setArtwork(const State &state) {
    if (state.artwork >= 0) {
        if (state.artwork == artArtwork_ && state.group == artGroup_)
            return;
        Pixels image = loader_(artworks()[state.artwork]);
        if (image.width != resolution || image.height != resolution ||
            image.rgba.size() != size_t(resolution) * resolution * 4)
            throw std::runtime_error("Artwork texture must be " + std::to_string(resolution) +
                                     " pixels square: " + artworks()[state.artwork].texture);
        original_->replaceRegion(MTL::Region(0, 0, resolution, resolution), 0, image.rgba.data(),
                                 resolution * 4);
        auto c = queue_->commandBuffer();
        auto blit = c->blitCommandEncoder();
        blit->generateMipmaps(original_.get());
        blit->endEncoding();
        check(c, "Artwork upload failed");
        art_ = Art{};
        supercell_ = artworks()[state.artwork].supercell;
        artArtwork_ = state.artwork;
        artGroup_ = state.group;
        cachedGroup_ = -1;
        mapped_ = mesh_.points;
        cellDirty_ = true;
        return;
    }
    if (artArtwork_ == -1 && state.group == artGroup_ && state.seed == artSeed_ &&
        state.palette == artPalette_)
        return;
    art_ = makeArt(state);
    supercell_ = 2;
    artArtwork_ = -1;
    artGroup_ = state.group;
    artSeed_ = state.seed;
    artPalette_ = state.palette;
    const Palette &palette = palettes()[std::clamp(state.palette, 0, int(palettes().size()) - 1)];
    GpuGroup group = gpuGroup(state);
    const Group &g = groups()[state.group];
    GpuStyle style{};
    for (size_t i = 0; i < art_.sites.size(); ++i) {
        const Site &site = art_.sites[i];
        auto orbit = orbits(g, site.position);
        for (size_t k = 0; k < g.ops.size(); ++k) {
            Vec c = g.ops[k](site.position);
            size_t at = i * maxOps + k;
            style.centre[at][0] = float(c.x);
            style.centre[at][1] = float(c.y);
            style.centre[at][2] = float(orbit[k].op);
            style.shift[at][0] = orbit[k].mx;
            style.shift[at][1] = orbit[k].my;
            for (int p = 0; p < 4; ++p)
                style.color[at][p] = uint32_t(art_.color[at * 4 + p]);
        }
        style.eye[i][0] = float(site.eye.x);
        style.eye[i][1] = float(site.eye.y);
        style.eye[i][2] = site.symmetric ? 0 : float(site.inradius * .2);
        style.eye[i][3] = float(site.inradius * (site.symmetric ? .07 : .085));
    }
    for (int i = 0; i < 6; ++i)
        put(style.tones[i], palette.tones[i]);
    put(style.ink, palette.ink);
    put(style.paper, palette.paper);
    style.line[0] = float(std::max(art_.inradius * .028, .0028));
    style.line[1] = 2.0f / resolution * .75f;
    style.line[2] = float(art_.sites.size());

    auto pass = MTL::RenderPassDescriptor::renderPassDescriptor();
    auto color = pass->colorAttachments()->object(0);
    color->setTexture(original_.get());
    color->setLoadAction(MTL::LoadActionDontCare);
    color->setStoreAction(MTL::StoreActionStore);
    auto c = queue_->commandBuffer();
    auto e = c->renderCommandEncoder(pass);
    e->setRenderPipelineState(artPipeline_.get());
    e->setFragmentBytes(&group, sizeof(group), 0);
    e->setFragmentBytes(&style, sizeof(style), 1);
    e->drawPrimitives(MTL::PrimitiveTypeTriangle, NS::UInteger(0), NS::UInteger(3));
    e->endEncoding();
    auto blit = c->blitCommandEncoder();
    blit->generateMipmaps(original_.get());
    blit->endEncoding();
    check(c, "Artwork render failed");
    cachedGroup_ = -1;
    mapped_ = mesh_.points;
    cellDirty_ = true;
}

void Renderer::rebuildBasis(const State &state) {
    bool same = cachedGroup_ == state.group && cachedSigma_ == state.sigma &&
                cachedSources_.size() == state.handles.size();
    if (same)
        for (size_t i = 0; i < cachedSources_.size(); ++i)
            if (length(cachedSources_[i] - state.handles[i].source) > 1e-12) {
                same = false;
                break;
            }
    if (same)
        return;
    cachedSources_.clear();
    for (auto h : state.handles)
        cachedSources_.push_back(h.source);
    cachedSigma_ = state.sigma;
    cachedGroup_ = state.group;
    if (state.handles.empty()) {
        basis_.reset();
        return;
    }
    std::vector<Float2> handles;
    for (auto h : state.handles)
        handles.push_back({float(h.source.x), float(h.source.y)});
    auto input = NS::TransferPtr(device_->newBuffer(handles.data(), handles.size() * sizeof(Float2),
                                                    MTL::ResourceStorageModeShared));
    uint32_t count = uint32_t(mesh_.points.size()), total = count * uint32_t(handles.size());
    GpuGroup group = gpuGroup(state);
    basis_ = NS::TransferPtr(
        device_->newBuffer(total * sizeof(float) * 4, MTL::ResourceStorageModeShared));
    auto c = queue_->commandBuffer();
    auto e = c->computeCommandEncoder();
    e->setComputePipelineState(compute_.get());
    e->setBuffer(points_.get(), 0, 0);
    e->setBuffer(input.get(), 0, 1);
    e->setBuffer(basis_.get(), 0, 2);
    e->setBytes(&count, sizeof(count), 3);
    e->setBytes(&group, sizeof(group), 4);
    e->setBytes(&total, sizeof(total), 5);
    e->dispatchThreads(MTL::Size(total, 1, 1), MTL::Size(256, 1, 1));
    e->endEncoding();
    check(c, "Deformation compute failed");
}

bool Renderer::evaluate(const State &state, const std::vector<Vec> &loads,
                        std::vector<Float2> &candidate) {
    if (loads.size() != state.handles.size() || state.group != artGroup_ ||
        (state.artwork >= 0) != (artArtwork_ >= 0) ||
        (state.artwork >= 0 && state.artwork != artArtwork_))
        return false;
    rebuildBasis(state);
    candidate = mesh_.points;
    const size_t n = candidate.size();
    auto b = basis_ ? static_cast<const float *>(basis_->contents()) : nullptr;
    for (size_t j = 0; j < loads.size(); ++j) {
        const float ax = float(loads[j].x), ay = float(loads[j].y);
        const float *w = b + j * n * 4;
        for (size_t i = 0; i < n; ++i, w += 4) {
            candidate[i].x += w[0] * ax + w[1] * ay;
            candidate[i].y += w[2] * ax + w[3] * ay;
        }
    }
    return mesh_.valid(candidate);
}

void Renderer::accept(std::vector<Float2> mapped) {
    mapped_ = std::move(mapped);
    cellDirty_ = true;
}

bool Renderer::update(const State &state, const std::vector<Vec> &loads) {
    std::vector<Float2> candidate;
    if (!evaluate(state, loads, candidate))
        return false;
    accept(std::move(candidate));
    return true;
}

void Renderer::encodeCell(MTL::CommandBuffer *c) {
    if (!cellDirty_)
        return;
    cellDirty_ = false;

    struct Vertex {
        Float2 source, mapped;
    };

    std::vector<Vertex> vertices(mapped_.size());
    for (size_t i = 0; i < vertices.size(); ++i)
        vertices[i] = {mesh_.points[i], mapped_[i]};
    auto buffer = NS::TransferPtr(device_->newBuffer(
        vertices.data(), vertices.size() * sizeof(Vertex), MTL::ResourceStorageModeShared));
    auto pass = MTL::RenderPassDescriptor::renderPassDescriptor();
    auto color = pass->colorAttachments()->object(0);
    color->setTexture(cell_.get());
    color->setLoadAction(MTL::LoadActionClear);
    color->setClearColor(MTL::ClearColor(0, 0, 0, 1));
    color->setStoreAction(MTL::StoreActionStore);
    auto e = c->renderCommandEncoder(pass);
    e->setRenderPipelineState(tilePipeline_.get());
    e->setVertexBuffer(buffer.get(), 0, 0);
    uint32_t n = uint32_t(supercell_);
    e->setVertexBytes(&n, sizeof(n), 1);
    e->setFragmentTexture(original_.get(), 0);
    e->drawIndexedPrimitives(MTL::PrimitiveTypeTriangle, mesh_.indices.size(), MTL::IndexTypeUInt32,
                             indices_.get(), 0, (n + 2) * (n + 2));
    e->endEncoding();
    auto blit = c->blitCommandEncoder();
    blit->generateMipmaps(cell_.get());
    blit->endEncoding();
}

void Renderer::encodeView(MTL::RenderCommandEncoder *e, const View &view, const State &state) {
    GpuView v{};
    v.center[0] = float(view.center.x);
    v.center[1] = float(view.center.y);
    v.span[0] = float(view.span.x);
    v.span[1] = float(view.span.y);
    v.pixels = float(view.pixels);
    v.dot = float(view.dot);
    v.original = view.original;
    v.selected = view.selected;
    v.period = float(supercell_);
    if (view.handles && !view.original) {
        v.handles = uint32_t(std::min(state.handles.size(), maxHandles));
        for (uint32_t i = 0; i < v.handles; ++i) {
            v.targets[i][0] = float(state.handles[i].target.x);
            v.targets[i][1] = float(state.handles[i].target.y);
        }
    }
    GpuGroup group = gpuGroup(state);
    e->setFragmentBytes(&v, sizeof(v), 0);
    e->setFragmentBytes(&group, sizeof(group), 1);
    e->setFragmentTexture(cell_.get(), 0);
    e->setFragmentTexture(original_.get(), 1);
    e->drawPrimitives(MTL::PrimitiveTypeTriangle, NS::UInteger(0), NS::UInteger(3));
}

void Renderer::draw(CA::MetalDrawable *drawable, MTL::RenderPassDescriptor *pass, const View &view,
                    const State &state) {
    if (!drawable || !pass)
        return;
    auto c = queue_->commandBuffer();
    encodeCell(c);
    auto e = c->renderCommandEncoder(pass);
    e->setRenderPipelineState(screenPipeline_.get());
    encodeView(e, view, state);
    e->endEncoding();
    c->presentDrawable(drawable);
    c->commit();
}

double Renderer::flush() {
    auto c = queue_->commandBuffer();
    encodeCell(c);
    check(c, "Tile render failed");
    return (c->GPUEndTime() - c->GPUStartTime()) * 1000;
}

Pixels Renderer::render(const View &view, unsigned width, unsigned height, const State &state) {
    auto target = texture(device_.get(), width, height, false);
    auto pass = MTL::RenderPassDescriptor::renderPassDescriptor();
    auto color = pass->colorAttachments()->object(0);
    color->setTexture(target.get());
    color->setLoadAction(MTL::LoadActionDontCare);
    color->setStoreAction(MTL::StoreActionStore);
    auto c = queue_->commandBuffer();
    encodeCell(c);
    auto e = c->renderCommandEncoder(pass);
    e->setRenderPipelineState(offscreenPipeline_.get());
    encodeView(e, view, state);
    e->endEncoding();
    check(c, "Offscreen render failed");
    Pixels p;
    p.width = width;
    p.height = height;
    p.rgba.resize(size_t(width) * height * 4);
    target->getBytes(p.rgba.data(), width * 4, MTL::Region(0, 0, width, height), 0);
    return p;
}

Pixels Renderer::exportTile(const State &state, unsigned width) {
    Vec size = repeatSize(state);
    // By default, at least the texture's own density: resolution / n texels per lattice unit.
    if (!width)
        width = std::min(8192u,
                         std::max(2048u, unsigned(std::lround(size.x * resolution / supercell_))));
    unsigned height = unsigned(std::lround(width * size.y / size.x));
    View view;
    view.center = size * .5;
    view.span = size;
    view.pixels = width / size.x;
    view.handles = false;
    return render(view, width, height, state);
}

double Renderer::basisError(const State &state) const {
    if (!basis_)
        return 0;
    auto b = static_cast<const float *>(basis_->contents());
    const Group &g = groups()[state.group];
    double err = 0;
    for (size_t h = 0; h < state.handles.size(); ++h)
        for (size_t i = 0; i < mesh_.points.size(); i += 137) {
            auto p = mesh_.points[i];
            Mat expected = basis(g, {p.x, p.y}, state.handles[h].source, state.sigma);
            const float *a = b + (h * mesh_.points.size() + i) * 4;
            err = std::max({err, std::abs(expected.a - a[0]), std::abs(expected.b - a[1]),
                            std::abs(expected.c - a[2]), std::abs(expected.d - a[3])});
        }
    return err;
}
} // namespace escher
