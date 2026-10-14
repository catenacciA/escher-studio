#import <AppKit/AppKit.h>
#import <ImageIO/ImageIO.h>
#import <MetalKit/MetalKit.h>
#import <QuartzCore/QuartzCore.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include "Renderer.hpp"
#include <algorithm>
#include <chrono>
#include <cmath>
#include <fstream>
#include <memory>
#include <random>
#include <sstream>
#include <stdexcept>

using namespace escher;

static void showError(NSString *message) {
    NSAlert *a = [NSAlert new];
    a.messageText = @"Escher Studio";
    a.informativeText = message;
    [a runModal];
}

static bool writePNG(const Pixels &p, NSURL *url) {
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGDataProviderRef provider =
        CGDataProviderCreateWithData(nullptr, p.rgba.data(), p.rgba.size(), nullptr);
    CGImageRef image = CGImageCreate(p.width, p.height, 8, 32, p.width * 4, cs,
                                     kCGImageAlphaNoneSkipLast | kCGBitmapByteOrder32Big, provider,
                                     nullptr, false, kCGRenderingIntentDefault);
    // PNG unless the name asks for JPEG (used for renders of scanned artwork).
    bool jpeg = [url.pathExtension.lowercaseString isEqualToString:@"jpg"];
    CGImageDestinationRef destination = CGImageDestinationCreateWithURL(
        (__bridge CFURLRef)url, jpeg ? CFSTR("public.jpeg") : CFSTR("public.png"), 1, nullptr);
    bool ok = false;
    if (destination) {
        NSDictionary *options =
            @{(__bridge NSString *)kCGImageDestinationLossyCompressionQuality : @0.9};
        CGImageDestinationAddImage(destination, image,
                                   jpeg ? (__bridge CFDictionaryRef)options : nullptr);
        ok = CGImageDestinationFinalize(destination);
        CFRelease(destination);
    }
    CGImageRelease(image);
    CGDataProviderRelease(provider);
    CGColorSpaceRelease(cs);
    return ok;
}

static std::string shaderSource() {
    NSString *path = [[NSBundle mainBundle] pathForResource:@"Deform" ofType:@"metal"];
    if (!path)
        throw std::runtime_error("Bundled shader source is missing. Launch the CMake-built .app.");
    std::ifstream input(path.UTF8String);
    std::ostringstream out;
    out << input.rdbuf();
    return out.str();
}

static NSString *artworkDirectory() {
    return [[NSBundle mainBundle].resourcePath stringByAppendingPathComponent:@"artwork"];
}

// Registers the bundled third-party artwork; each entry is checked against its group.
static void loadArtworks() {
    artworks().clear();
    NSData *data =
        [NSData dataWithContentsOfFile:[artworkDirectory()
                                           stringByAppendingPathComponent:@"artworks.json"]];
    id list = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (![list isKindOfClass:[NSArray class]])
        return;
    auto text = [](id v) {
        return std::string([v isKindOfClass:[NSString class]] ? [v UTF8String] : "");
    };
    for (NSDictionary *entry in list) {
        if (![entry isKindOfClass:[NSDictionary class]])
            continue;
        Artwork art;
        art.id = text(entry[@"id"]);
        art.collection = text(entry[@"collection"]);
        art.title = text(entry[@"title"]);
        art.english = text(entry[@"english"]);
        art.artist = text(entry[@"artist"]);
        art.source = text(entry[@"source"]);
        art.license = text(entry[@"license"]);
        art.url = text(entry[@"url"]);
        art.museum = text(entry[@"museum"]);
        art.texture = text(entry[@"texture"]);
        art.group = groupIndex(text(entry[@"group"]));
        NSArray *b = entry[@"basis"];
        if (![b isKindOfClass:[NSArray class]] || b.count != 4)
            continue;
        art.basis = {
            [b[0] doubleValue], [b[2] doubleValue], [b[1] doubleValue], [b[3] doubleValue]};
        if (compatible(art))
            artworks().push_back(art);
        else
            fprintf(stderr, "Escher Studio: skipping artwork %s (basis does not fit %s)\n",
                    art.id.c_str(), text(entry[@"group"]).c_str());
    }
}

static Pixels loadImage(const Artwork &art) {
    NSString *name = @(art.texture.c_str());
    NSURL *url =
        [NSURL fileURLWithPath:name.isAbsolutePath
                                   ? name
                                   : [artworkDirectory() stringByAppendingPathComponent:name]];
    CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)url, nullptr);
    CGImageRef image = source ? CGImageSourceCreateImageAtIndex(source, 0, nullptr) : nullptr;
    if (source)
        CFRelease(source);
    if (!image)
        throw std::runtime_error("Could not read artwork texture " + art.texture);
    Pixels p;
    p.width = unsigned(CGImageGetWidth(image));
    p.height = unsigned(CGImageGetHeight(image));
    p.rgba.resize(size_t(p.width) * p.height * 4);
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef c = CGBitmapContextCreate(p.rgba.data(), p.width, p.height, 8, p.width * 4, cs,
                                           kCGImageAlphaNoneSkipLast | kCGBitmapByteOrder32Big);
    CGContextDrawImage(c, CGRectMake(0, 0, p.width, p.height), image);
    CGContextRelease(c);
    CGColorSpaceRelease(cs);
    CGImageRelease(image);
    for (size_t i = 3; i < p.rgba.size(); i += 4)
        p.rgba[i] = 255;
    return p;
}

static bool equalState(const State &a, const State &b) {
    if (a.group != b.group || a.artwork != b.artwork || a.seed != b.seed ||
        a.palette != b.palette || a.sigma != b.sigma || a.handles.size() != b.handles.size())
        return false;
    for (size_t i = 0; i < a.handles.size(); ++i)
        if (length(a.handles[i].source - b.handles[i].source) > 1e-12 ||
            length(a.handles[i].target - b.handles[i].target) > 1e-12)
            return false;
    return true;
}

// Solves and maps a state; if it folds, shrinks every handle's offset until it does not, and
// drops handles whose positions make the solve singular.
static bool settle(Renderer &renderer, State &state, std::vector<Vec> &loads) {
    State base = state;
    while (!base.handles.empty()) {
        State trial = base;
        for (int i = 0; i < 12; ++i) {
            std::vector<Float2> mapped;
            if (solve(trial, loads) && renderer.evaluate(trial, loads, mapped)) {
                renderer.accept(std::move(mapped));
                state = trial;
                return true;
            }
            for (size_t h = 0; h < trial.handles.size(); ++h)
                trial.handles[h].target =
                    base.handles[h].source +
                    (base.handles[h].target - base.handles[h].source) * std::pow(.75, i + 1);
        }
        base.handles.pop_back();
    }
    return false;
}

static double fitWidth(const State &state) {
    if (state.artwork >= 0) {
        // About three lattice cells, but never magnify the source beyond ~1:1 on a typical window.
        double density = artworks()[state.artwork].density;
        return std::max(3.0, density > 0 ? 1000 / density : 0);
    }
    return std::clamp(7.0 / std::sqrt(double(groups()[state.group].ops.size())), 2.2, 7.0);
}

static NSData *encodeProject(const State &state, Vec center, double scale, NSError **error) {
    NSMutableArray *handles = [NSMutableArray new];
    for (auto h : state.handles)
        [handles addObject:@{
            @"source" : @[ @(h.source.x), @(h.source.y) ],
            @"target" : @[ @(h.target.x), @(h.target.y) ]
        }];
    NSDictionary *project = @{
        @"version" : @2,
        @"group" : @(groups()[state.group].name),
        @"artwork" : state.artwork >= 0 ? @(artworks()[state.artwork].id.c_str()) : @"",
        @"seed" : @(state.seed),
        @"palette" : @(palettes()[state.palette].name),
        @"sigma" : @(state.sigma),
        @"handles" : handles,
        @"camera" : @{@"center" : @[ @(center.x), @(center.y) ], @"scale" : @(scale)}
    };
    return
        [NSJSONSerialization dataWithJSONObject:project
                                        options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys
                                          error:error];
}

static bool number(id value, double &output) {
    if (![value isKindOfClass:[NSNumber class]] ||
        CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID())
        return false;
    output = [value doubleValue];
    return std::isfinite(output);
}

static bool vectorValue(id value, Vec &output) {
    return [value isKindOfClass:[NSArray class]] && [value count] == 2 &&
           number(value[0], output.x) && number(value[1], output.y);
}

static bool decodeProject(NSData *data, State &state, Vec &center, double &scale) {
    if (!data || data.length > 131072)
        return false;
    id p = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![p isKindOfClass:[NSDictionary class]])
        return false;
    double version, seed;
    if (!number(p[@"version"], version) || version != 2 ||
        ![p[@"group"] isKindOfClass:[NSString class]] ||
        ![p[@"palette"] isKindOfClass:[NSString class]] || !number(p[@"seed"], seed) || seed < 0 ||
        seed > UINT32_MAX || seed != std::floor(seed))
        return false;
    State candidate;
    candidate.group = groupIndex([p[@"group"] UTF8String]);
    candidate.seed = uint32_t(seed);
    candidate.palette = -1;
    for (size_t i = 0; i < palettes().size(); ++i)
        if ([p[@"palette"] isEqualToString:@(palettes()[i].name)])
            candidate.palette = int(i);
    if (candidate.group < 0 || candidate.palette < 0)
        return false;
    id artwork = p[@"artwork"];
    if (artwork && ![artwork isKindOfClass:[NSString class]])
        return false;
    if ([artwork length]) {
        for (size_t i = 0; i < artworks().size(); ++i)
            if ([artwork isEqualToString:@(artworks()[i].id.c_str())])
                candidate.artwork = int(i);
        if (candidate.artwork < 0 || artworks()[candidate.artwork].group != candidate.group)
            return false;
    }
    if (!number(p[@"sigma"], candidate.sigma) || candidate.sigma < .5 || candidate.sigma > 20)
        return false;
    id handles = p[@"handles"];
    if (![handles isKindOfClass:[NSArray class]] || [handles count] > maxHandles)
        return false;
    for (id entry in handles) {
        escher::Handle h;
        if (![entry isKindOfClass:[NSDictionary class]] ||
            !vectorValue(entry[@"source"], h.source) || !vectorValue(entry[@"target"], h.target))
            return false;
        if (h.source.x < 0 || h.source.x >= 1 || h.source.y < 0 || h.source.y >= 1 ||
            !canAdd(candidate, h.source) || length(h.target - h.source) > 1)
            return false;
        candidate.handles.push_back(h);
    }
    id camera = p[@"camera"];
    if (![camera isKindOfClass:[NSDictionary class]] || !vectorValue(camera[@"center"], center) ||
        !number(camera[@"scale"], scale) || scale < 40 || scale > 1600 || length(center) > 10000)
        return false;
    std::vector<Vec> loads;
    if (!solve(candidate, loads))
        return false;
    state = candidate;
    return true;
}

@interface Canvas : MTKView <MTKViewDelegate> {
  @public
    std::unique_ptr<Renderer> renderer;
    State state;
    std::vector<Vec> loads;
    Vec center;   // world
    double scale; // points per world unit
    int selected;
    bool originalView;
  @private
    bool _dragging, _panning, _pending, _localityGesture;
    int _op;
    Vec _offset, _wanted;
    NSPoint _lastMouse;
    State _gestureStart;
    std::vector<State> _undo, _redo;
}
@property(nonatomic, copy) void (^onMessage)(NSString *);
@property(nonatomic, copy) void (^onState)(void);
- (instancetype)initWithFrame:(NSRect)frame shader:(const std::string &)shader;
@end

@implementation Canvas

- (BOOL)isFlipped {
    return YES;
}

- (BOOL)acceptsFirstResponder {
    return YES;
}

- (void)resetCursorRects {
    [self addCursorRect:self.bounds cursor:[NSCursor crosshairCursor]];
}

- (instancetype)initWithFrame:(NSRect)frame shader:(const std::string &)shader {
    self = [super initWithFrame:frame device:nil];
    if (self) {
        renderer = std::make_unique<Renderer>(shader, loadImage);
        self.device = (__bridge id<MTLDevice>)(void *)renderer->device();
        self.colorPixelFormat = MTLPixelFormatBGRA8Unorm_sRGB;
        self.paused = YES;
        self.enableSetNeedsDisplay = YES;
        self.delegate = self;
        selected = -1;
        // Open on the first bundled artwork, untouched: the first drag shows what the tool does.
        if (!artworks().empty()) {
            state.artwork = 0;
            state.group = artworks()[0].group;
        }
        renderer->setArtwork(state);
        renderer->update(state, loads);
        [self fit:nil];
    }
    return self;
}

- (Mat)lattice {
    return cellBasis(state);
}

- (Vec)world:(NSPoint)p {
    return center + Vec{(p.x - self.bounds.size.width / 2) / scale,
                        (p.y - self.bounds.size.height / 2) / scale};
}

- (Vec)cell:(NSPoint)p {
    return inverse([self lattice]) * [self world:p];
}

- (void)drawInMTKView:(MTKView *)view {
    if (_pending)
        [self step];
    View v;
    v.center = center;
    v.span = {self.bounds.size.width / scale, self.bounds.size.height / scale};
    v.dot = self.window.backingScaleFactor ?: 2;
    v.pixels = scale * v.dot;
    v.original = originalView;
    v.selected = selected;
    renderer->draw((CA::MetalDrawable *)(__bridge void *)view.currentDrawable,
                   (MTL::RenderPassDescriptor *)(__bridge void *)view.currentRenderPassDescriptor,
                   v, state);
}

- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {
}

- (void)refresh {
    [self setNeedsDisplay:YES];
}

- (void)message:(NSString *)text {
    if (self.onMessage)
        self.onMessage(text);
}

- (BOOL)apply:(const State &)candidate {
    std::vector<Vec> proposed;
    if (!solve(candidate, proposed))
        return NO;
    State previous = state;
    renderer->setArtwork(candidate);
    if (!renderer->update(candidate, proposed)) {
        renderer->setArtwork(previous);
        renderer->update(previous, loads);
        return NO;
    }
    bool styleChanged = candidate.group != state.group || candidate.artwork != state.artwork ||
                        candidate.sigma != state.sigma;
    state = candidate;
    loads = std::move(proposed);
    if (selected >= int(state.handles.size()))
        selected = int(state.handles.size()) - 1;
    if (styleChanged && self.onState)
        self.onState();
    [self refresh];
    return YES;
}

- (void)record:(const State &)before {
    if (!equalState(state, before)) {
        _undo.push_back(before);
        if (_undo.size() > 200)
            _undo.erase(_undo.begin());
        _redo.clear();
    }
}

// One drag update per displayed frame; bisects on the CPU when an edit would fold.
- (void)step {
    _pending = false;
    if (!_dragging || selected < 0 || selected >= int(state.handles.size()))
        return;
    State candidate = state;
    Vec previous = state.handles[selected].target;
    std::vector<Vec> proposed;
    std::vector<Float2> mapped;
    auto attempt = [&](Vec target) {
        candidate.handles[selected].target = target;
        return solve(candidate, proposed) && renderer->evaluate(candidate, proposed, mapped);
    };
    if (attempt(_wanted)) {
        renderer->accept(std::move(mapped));
        state = candidate;
        loads = proposed;
        return;
    }
    double low = 0, high = 1;
    for (int i = 0; i < 6; ++i) {
        double t = (low + high) / 2;
        if (attempt(previous + (_wanted - previous) * t)) {
            low = t;
            renderer->accept(std::move(mapped));
            state = candidate;
            loads = proposed;
        } else
            high = t;
    }
    [self message:@"Edit limit — this would fold the tiles"];
}

- (void)mouseDown:(NSEvent *)event {
    [self.window makeFirstResponder:self];
    _lastMouse = [self convertPoint:event.locationInWindow fromView:nil];
    if (event.modifierFlags & NSEventModifierFlagOption) {
        _panning = true;
        return;
    }
    if (originalView)
        return;
    _gestureStart = state;
    const Group &g = groups()[state.group];
    Mat m = [self lattice];
    Vec q = [self cell:_lastMouse];
    double best = 12;
    int hit = -1;
    for (size_t i = 0; i < state.handles.size(); ++i)
        for (size_t k = 0; k < g.ops.size(); ++k) {
            Vec p = g.ops[k](state.handles[i].target), d = wrapCentered(q - p);
            double distance = length(m * d) * scale;
            if (distance < best) {
                best = distance;
                hit = int(i);
                _op = int(k);
                Vec n = q - d - p;
                _offset = {std::round(n.x), std::round(n.y)};
            }
        }
    if (hit < 0) {
        Vec source;
        if (!renderer->mesh().pick(q, renderer->mapped(), source) || !canAdd(state, source)) {
            [self message:state.handles.size() >= maxHandles
                              ? @"Eight handles at most"
                              : @"Too close to a handle, mirror or rotation centre"];
            return;
        }
        State candidate = state;
        std::vector<Vec> sources;
        for (auto h : state.handles)
            sources.push_back(h.source);
        Vec target = source + displacement(g, source, sources, loads, state.sigma);
        candidate.handles.push_back({source, target});
        if (![self apply:candidate]) {
            [self message:@"Too close to another handle"];
            return;
        }
        hit = int(state.handles.size() - 1);
        _op = 0;
        _offset = {std::round(q.x - target.x), std::round(q.y - target.y)};
    }
    selected = hit;
    _dragging = true;
    [self refresh];
}

- (void)mouseDragged:(NSEvent *)event {
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    if (_panning) {
        center = center - Vec{(p.x - _lastMouse.x) / scale, (p.y - _lastMouse.y) / scale};
        _lastMouse = p;
        [self refresh];
        return;
    }
    if (!_dragging)
        return;
    const Op &op = groups()[state.group].ops[_op];
    _wanted = inverse(op)([self cell:p] - _offset);
    _pending = true;
    [self refresh];
}

- (void)mouseUp:(NSEvent *)event {
    if (_dragging) {
        if (_pending)
            [self step];
        [self record:_gestureStart];
    }
    _dragging = false;
    _panning = false;
}

- (void)rightMouseDown:(NSEvent *)e {
    _panning = true;
    _lastMouse = [self convertPoint:e.locationInWindow fromView:nil];
}

- (void)rightMouseDragged:(NSEvent *)e {
    [self mouseDragged:e];
}

- (void)rightMouseUp:(NSEvent *)e {
    _panning = false;
}

- (void)zoomBy:(double)factor at:(NSPoint)p {
    Vec before = [self world:p];
    scale = std::clamp(scale * factor, 40., 1600.);
    center = center + before - [self world:p];
    [self refresh];
}

- (void)scrollWheel:(NSEvent *)e {
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
    if (e.hasPreciseScrollingDeltas && !(e.modifierFlags & NSEventModifierFlagCommand)) {
        // Two-finger scroll pans; pinch zooms.
        center = center - Vec{e.scrollingDeltaX / scale, e.scrollingDeltaY / scale};
        [self refresh];
        return;
    }
    [self zoomBy:std::exp(e.scrollingDeltaY * (e.hasPreciseScrollingDeltas ? .008 : .09)) at:p];
}

- (void)magnifyWithEvent:(NSEvent *)e {
    [self zoomBy:1 + e.magnification at:[self convertPoint:e.locationInWindow fromView:nil]];
}

- (void)keyDown:(NSEvent *)e {
    if (e.keyCode == 49) {
        if (!e.isARepeat) {
            originalView = true;
            [self refresh];
        }
        return;
    }
    if (e.keyCode == 51 || e.keyCode == 117) {
        if (selected >= 0 && selected < int(state.handles.size())) {
            State before = state, candidate = state;
            candidate.handles.erase(candidate.handles.begin() + selected);
            if ([self apply:candidate]) {
                selected = int(state.handles.size()) - 1;
                [self record:before];
            } else
                [self message:@"Removing this handle would fold the tiles"];
        }
        return;
    }
    if (e.keyCode == 53) {
        if (_dragging) {
            [self apply:_gestureStart];
            _dragging = false;
        }
        originalView = false;
        [self refresh];
        return;
    }
    [super keyDown:e];
}

- (void)keyUp:(NSEvent *)e {
    if (e.keyCode == 49) {
        originalView = false;
        [self refresh];
    } else
        [super keyUp:e];
}

- (void)change:(const State &)candidate failure:(NSString *)failure {
    State before = state;
    if ([self apply:candidate])
        [self record:before];
    else if (failure)
        [self message:failure];
}

- (void)beginLocality {
    _gestureStart = state;
    _localityGesture = true;
}

- (void)endLocality {
    [self record:_gestureStart];
    _localityGesture = false;
}

- (void)locality:(NSSlider *)slider {
    State before = state, candidate = state;
    candidate.sigma = slider.doubleValue;
    if (![self apply:candidate]) {
        slider.doubleValue = state.sigma;
        [self message:@"Locality limit — this would fold the tiles"];
    }
    if (!_localityGesture)
        [self record:before];
}

// Menu tags: a wallpaper group's index, or artworkTag + an artwork's index.
static const NSInteger artworkTag = 1000;

- (void)chooseGroup:(NSPopUpButton *)sender {
    State candidate = state;
    NSInteger tag = sender.selectedItem.tag;
    candidate.artwork = tag >= artworkTag ? int(tag - artworkTag) : -1;
    candidate.group = tag >= artworkTag ? artworks()[candidate.artwork].group : int(tag);
    candidate.handles.clear();
    selected = -1;
    [self change:candidate failure:nil];
    [self fit:nil];
}

- (void)shuffle:(id)sender {
    if (state.artwork >= 0)
        return;
    State candidate = state;
    candidate.seed = std::random_device{}();
    [self change:candidate failure:@"This shape does not fit the current edits"];
}

- (void)cyclePalette:(id)sender {
    if (state.artwork >= 0)
        return;
    State candidate = state;
    candidate.palette = (state.palette + 1) % int(palettes().size());
    [self change:candidate failure:nil];
    [self message:@(palettes()[state.palette].name)];
}

- (void)choosePalette:(NSMenuItem *)sender {
    if (state.artwork >= 0)
        return;
    State candidate = state;
    candidate.palette = int(sender.tag);
    [self change:candidate failure:nil];
}

- (void)sculpt:(id)sender {
    State before = state, candidate = escher::sculpt(state, std::random_device{}());
    std::vector<Vec> proposed;
    if (!settle(*renderer, candidate, proposed)) {
        renderer->update(state, loads);
        [self message:@"Try again"];
        return;
    }
    state = candidate;
    loads = proposed;
    selected = -1;
    [self record:before];
    if (self.onState)
        self.onState();
    [self refresh];
}

- (void)resetArt:(id)sender {
    State candidate = state;
    candidate.handles.clear();
    selected = -1;
    [self change:candidate failure:nil];
}

- (void)fit:(id)sender {
    Mat m = [self lattice];
    center = m * Vec{.5, .5};
    double width = std::max(self.bounds.size.width, 400.0);
    scale = std::clamp(width / fitWidth(state), 40., 1600.);
    [self refresh];
}

- (void)undoEdit:(id)sender {
    if (_undo.empty())
        return;
    State previous = state, candidate = _undo.back();
    if ([self apply:candidate]) {
        _undo.pop_back();
        _redo.push_back(previous);
        selected = -1;
        if (candidate.group != previous.group || candidate.artwork != previous.artwork)
            [self fit:nil];
    }
}

- (void)redoEdit:(id)sender {
    if (_redo.empty())
        return;
    State previous = state, candidate = _redo.back();
    if ([self apply:candidate]) {
        _redo.pop_back();
        _undo.push_back(previous);
        selected = -1;
        if (candidate.group != previous.group || candidate.artwork != previous.artwork)
            [self fit:nil];
    }
}

- (BOOL)validateMenuItem:(NSMenuItem *)item {
    if (item.action == @selector(undoEdit:))
        return !_undo.empty();
    if (item.action == @selector(redoEdit:))
        return !_redo.empty();
    if (item.action == @selector(choosePalette:)) {
        item.state = item.tag == state.palette ? NSControlStateValueOn : NSControlStateValueOff;
        return state.artwork < 0;
    }
    if (item.action == @selector(shuffle:))
        return state.artwork < 0;
    return YES;
}

- (void)exportArt:(id)sender {
    NSSavePanel *panel = [NSSavePanel savePanel];
    panel.nameFieldStringValue =
        [NSString stringWithFormat:@"Escher %s.png", groups()[state.group].name];
    panel.allowedContentTypes = @[ UTTypePNG ];
    if ([panel runModal] != NSModalResponseOK)
        return;
    Pixels tile = renderer->exportTile(state);
    if (writePNG(tile, panel.URL))
        [self message:[NSString stringWithFormat:@"Exported a seamless %u × %u tile", tile.width,
                                                 tile.height]];
    else
        showError(@"Could not write the PNG. Choose another location.");
}

- (void)saveProject:(id)sender {
    NSSavePanel *panel = [NSSavePanel savePanel];
    panel.nameFieldStringValue =
        [NSString stringWithFormat:@"%s.escher", groups()[state.group].name];
    panel.allowedContentTypes = @[ [UTType typeWithFilenameExtension:@"escher"] ];
    if ([panel runModal] != NSModalResponseOK)
        return;
    NSError *error = nil;
    NSData *data = encodeProject(state, center, scale, &error);
    if (!data || ![data writeToURL:panel.URL options:NSDataWritingAtomic error:&error])
        showError(error.localizedDescription ?: @"Could not save this project.");
    else {
        self.window.representedURL = panel.URL;
        [self message:@"Saved"];
    }
}

- (void)openProject:(id)sender {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.allowsMultipleSelection = NO;
    panel.allowedContentTypes = @[ [UTType typeWithFilenameExtension:@"escher"], UTTypeJSON ];
    if ([panel runModal] != NSModalResponseOK)
        return;
    State candidate;
    Vec newCenter;
    double newScale;
    if (!decodeProject([NSData dataWithContentsOfURL:panel.URL], candidate, newCenter, newScale)) {
        showError(@"This is not a valid Escher Studio project.");
        return;
    }
    State before = state;
    if (![self apply:candidate]) {
        showError(@"This project would fold the tiles. The current artwork has been kept.");
        return;
    }
    [self record:before];
    center = newCenter;
    scale = newScale;
    selected = -1;
    [self refresh];
    self.window.representedURL = panel.URL;
}

@end

@interface LocalitySlider : NSSlider
@end

@implementation LocalitySlider

- (void)mouseDown:(NSEvent *)event {
    Canvas *canvas = (Canvas *)self.target;
    [canvas beginLocality];
    [super mouseDown:event];
    [canvas endLocality];
}

@end

static NSButton *iconButton(NSString *symbol, NSString *tip, id target, SEL action) {
    NSImage *image = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:tip];
    NSButton *b = [NSButton buttonWithImage:image target:target action:action];
    b.bordered = NO;
    b.toolTip = tip;
    b.contentTintColor = NSColor.secondaryLabelColor;
    b.imageScaling = NSImageScaleProportionallyUpOrDown;
    [b.widthAnchor constraintEqualToConstant:28].active = YES;
    [b.heightAnchor constraintEqualToConstant:28].active = YES;
    return b;
}

@interface App : NSObject <NSApplicationDelegate>
@property(nonatomic, strong) NSWindow *window;
@property(nonatomic, strong) Canvas *canvas;
@property(nonatomic, strong) NSPopUpButton *groupMenu;
@property(nonatomic, strong) NSButton *shuffleButton, *paletteButton;
@property(nonatomic, strong) NSSlider *slider;
@property(nonatomic, strong) NSTextField *toast;
@property(nonatomic, strong) NSView *toastBox;
@property(nonatomic) NSUInteger toastId;
@end

@implementation App

- (void)showToast:(NSString *)text {
    self.toast.stringValue = text;
    NSUInteger ticket = ++self.toastId;
    self.toastBox.hidden = NO;
    self.toastBox.alphaValue = 1;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, int64_t(2.2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                       if (ticket != self.toastId)
                           return;
                       [NSAnimationContext
                           runAnimationGroup:^(NSAnimationContext *context) {
                               context.duration = .35;
                               self.toastBox.animator.alphaValue = 0;
                           }
                           completionHandler:nil];
                   });
}

- (void)syncControls {
    const State &state = self.canvas->state;
    [self.groupMenu
        selectItemWithTag:state.artwork >= 0 ? artworkTag + state.artwork : state.group];
    self.slider.doubleValue = state.sigma;
    // Shape and palette belong to generated tilings; artwork keeps its own.
    self.shuffleButton.enabled = self.paletteButton.enabled = state.artwork < 0;
}

- (NSView *)makeBar {
    NSVisualEffectView *bar = [NSVisualEffectView new];
    bar.material = NSVisualEffectMaterialPopover;
    bar.blendingMode = NSVisualEffectBlendingModeWithinWindow;
    bar.state = NSVisualEffectStateActive;
    bar.wantsLayer = YES;
    bar.layer.cornerRadius = 14;
    bar.layer.masksToBounds = YES;

    self.groupMenu = [NSPopUpButton new];
    NSMenu *menu = self.groupMenu.menu;
    auto header = [&](NSString *title) {
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:nil keyEquivalent:@""];
        item.enabled = NO;
        [menu addItem:item];
    };
    if (!artworks().empty()) {
        std::string collection = "-";
        for (size_t i = 0; i < artworks().size(); ++i) {
            const Artwork &art = artworks()[i];
            if (art.collection != collection) {
                if (i)
                    [menu addItem:[NSMenuItem separatorItem]];
                collection = art.collection;
                header(@(collection.c_str()));
            }
            const char *group = groups()[art.group].name;
            NSString *title =
                art.english.empty()
                    ? @(group)
                    : [NSString stringWithFormat:@"%s  ·  %s", art.english.c_str(), group];
            NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title
                                                          action:nil
                                                   keyEquivalent:@""];
            item.tag = artworkTag + NSInteger(i);
            item.toolTip = @(art.source.c_str());
            [menu addItem:item];
        }
        [menu addItem:[NSMenuItem separatorItem]];
        header(@"Generated tilings");
    }
    for (size_t i = 0; i < groups().size(); ++i) {
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:@(groups()[i].name)
                                                      action:nil
                                               keyEquivalent:@""];
        item.tag = NSInteger(i);
        item.toolTip = @(groups()[i].orbifold);
        [menu addItem:item];
    }
    self.groupMenu.autoenablesItems = NO;
    self.groupMenu.bordered = NO;
    self.groupMenu.font = [NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
    self.groupMenu.target = self.canvas;
    self.groupMenu.action = @selector(chooseGroup:);
    self.groupMenu.toolTip = @"Wallpaper group";

    self.slider = [LocalitySlider sliderWithValue:self.canvas->state.sigma
                                         minValue:.5
                                         maxValue:20
                                           target:self.canvas
                                           action:@selector(locality:)];
    self.slider.continuous = YES;
    self.slider.controlSize = NSControlSizeSmall;
    self.slider.toolTip = @"Locality — right is more local";
    [self.slider.widthAnchor constraintEqualToConstant:120].active = YES;

    NSView *divider = [NSBox new];
    ((NSBox *)divider).boxType = NSBoxSeparator;
    [divider.heightAnchor constraintEqualToConstant:18].active = YES;
    NSView *divider2 = [NSBox new];
    ((NSBox *)divider2).boxType = NSBoxSeparator;
    [divider2.heightAnchor constraintEqualToConstant:18].active = YES;

    NSStackView *row = [NSStackView stackViewWithViews:@[
        self.groupMenu,
        self.shuffleButton =
            iconButton(@"shuffle", @"New tile shape", self.canvas, @selector(shuffle:)),
        iconButton(@"wand.and.stars", @"Random sculpt (⌘R)", self.canvas, @selector(sculpt:)),
        self.paletteButton = iconButton(@"circle.lefthalf.filled", @"Palette", self.canvas,
                                        @selector(cyclePalette:)),
        divider,
        self.slider,
        divider2,
        iconButton(@"arrow.counterclockwise", @"Remove all handles", self.canvas,
                   @selector(resetArt:)),
        iconButton(@"square.and.arrow.up", @"Export seamless tile (⌘E)", self.canvas,
                   @selector(exportArt:)),
    ]];
    row.spacing = 6;
    row.edgeInsets = NSEdgeInsetsMake(0, 10, 0, 10);
    row.translatesAutoresizingMaskIntoConstraints = NO;
    [bar addSubview:row];
    [NSLayoutConstraint activateConstraints:@[
        [row.leadingAnchor constraintEqualToAnchor:bar.leadingAnchor],
        [row.trailingAnchor constraintEqualToAnchor:bar.trailingAnchor],
        [row.centerYAnchor constraintEqualToAnchor:bar.centerYAnchor],
        [bar.heightAnchor constraintEqualToConstant:44],
    ]];
    return bar;
}

- (void)applicationDidFinishLaunching:(NSNotification *)note {
    try {
        self.window = [[NSWindow alloc]
            initWithContentRect:NSMakeRect(0, 0, 1180, 800)
                      styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable |
                                NSWindowStyleMaskFullSizeContentView
                        backing:NSBackingStoreBuffered
                          defer:NO];
        self.window.title = @"Escher Studio";
        self.window.titleVisibility = NSWindowTitleHidden;
        self.window.titlebarAppearsTransparent = YES;
        self.window.minSize = NSMakeSize(640, 420);
        NSView *root = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 1180, 800)];
        self.window.contentView = root;
        self.canvas = [[Canvas alloc] initWithFrame:root.bounds shader:shaderSource()];
        self.canvas.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        [root addSubview:self.canvas];
        [self.canvas fit:nil];

        NSView *bar = [self makeBar];
        bar.translatesAutoresizingMaskIntoConstraints = NO;
        [root addSubview:bar];
        self.toast = [NSTextField labelWithString:@""];
        self.toast.font = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
        self.toast.textColor = NSColor.labelColor;
        self.toast.translatesAutoresizingMaskIntoConstraints = NO;
        NSVisualEffectView *toastBox = [NSVisualEffectView new];
        toastBox.material = NSVisualEffectMaterialPopover;
        toastBox.blendingMode = NSVisualEffectBlendingModeWithinWindow;
        toastBox.state = NSVisualEffectStateActive;
        toastBox.wantsLayer = YES;
        toastBox.layer.cornerRadius = 10;
        toastBox.layer.masksToBounds = YES;
        toastBox.translatesAutoresizingMaskIntoConstraints = NO;
        toastBox.hidden = YES;
        [toastBox addSubview:self.toast];
        [root addSubview:toastBox];
        self.toastBox = toastBox;
        [NSLayoutConstraint activateConstraints:@[
            [bar.centerXAnchor constraintEqualToAnchor:root.centerXAnchor],
            [bar.bottomAnchor constraintEqualToAnchor:root.bottomAnchor constant:-18],
            [toastBox.centerXAnchor constraintEqualToAnchor:root.centerXAnchor],
            [toastBox.bottomAnchor constraintEqualToAnchor:bar.topAnchor constant:-10],
            [self.toast.leadingAnchor constraintEqualToAnchor:toastBox.leadingAnchor constant:12],
            [self.toast.trailingAnchor constraintEqualToAnchor:toastBox.trailingAnchor
                                                      constant:-12],
            [self.toast.topAnchor constraintEqualToAnchor:toastBox.topAnchor constant:6],
            [self.toast.bottomAnchor constraintEqualToAnchor:toastBox.bottomAnchor constant:-6],
        ]];

        [self syncControls];
        __weak App *weakSelf = self;
        self.canvas.onMessage = ^(NSString *text) {
            [weakSelf showToast:text];
        };
        self.canvas.onState = ^{
            [weakSelf syncControls];
        };
        [self buildMenu];
        [self.window center];
        [self.window makeKeyAndOrderFront:nil];
        [self.window makeFirstResponder:self.canvas];
        [NSApp activateIgnoringOtherApps:YES];
    } catch (const std::exception &error) {
        showError([NSString stringWithUTF8String:error.what()]);
        [NSApp terminate:nil];
    }
}

- (void)buildMenu {
    NSMenu *menu = [NSMenu new];
    auto submenu = [&](NSString *title) {
        NSMenuItem *item = [NSMenuItem new];
        item.title = title;
        item.submenu = [[NSMenu alloc] initWithTitle:title];
        [menu addItem:item];
        return item.submenu;
    };
    auto add = [&](NSMenu *m, NSString *title, SEL action, NSString *key, id target) {
        NSMenuItem *item = [m addItemWithTitle:title action:action keyEquivalent:key];
        item.target = target;
        return item;
    };
    NSMenu *app = submenu(@"Escher Studio");
    add(app, @"About Escher Studio", @selector(about:), @"", self);
    [app addItem:[NSMenuItem separatorItem]];
    add(app, @"Quit Escher Studio", @selector(terminate:), @"q", NSApp);
    NSMenu *file = submenu(@"File");
    add(file, @"Open…", @selector(openProject:), @"o", self.canvas);
    add(file, @"Save…", @selector(saveProject:), @"s", self.canvas);
    add(file, @"Export Tile…", @selector(exportArt:), @"e", self.canvas);
    NSMenu *edit = submenu(@"Edit");
    add(edit, @"Undo", @selector(undoEdit:), @"z", self.canvas);
    add(edit, @"Redo", @selector(redoEdit:), @"z", self.canvas).keyEquivalentModifierMask =
        NSEventModifierFlagCommand | NSEventModifierFlagShift;
    [edit addItem:[NSMenuItem separatorItem]];
    add(edit, @"Random Sculpt", @selector(sculpt:), @"r", self.canvas);
    add(edit, @"New Tile Shape", @selector(shuffle:), @"n", self.canvas);
    add(edit, @"Remove All Handles", @selector(resetArt:), @"", self.canvas);
    NSMenu *view = submenu(@"View");
    add(view, @"Fit", @selector(fit:), @"0", self.canvas);
    [view addItem:[NSMenuItem separatorItem]];
    for (size_t i = 0; i < palettes().size(); ++i)
        add(view, @(palettes()[i].name), @selector(choosePalette:),
            [NSString stringWithFormat:@"%zu", i + 1], self.canvas)
            .tag = NSInteger(i);
    NSApp.mainMenu = menu;
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    return YES;
}

- (void)about:(id)sender {
    NSMutableString *credits = [NSMutableString new];
    std::string last;
    for (const Artwork &art : artworks())
        if (art.collection != last) {
            last = art.collection;
            [credits appendFormat:@"\n• %s — %s", art.collection.c_str(), art.license.c_str()];
        }
    showError([NSString
        stringWithFormat:
            @"Escher Studio 0.3\n\nAll 17 wallpaper groups, deformed with the closed-form method "
            @"of Crane He Chen and Vladimir G. Kim (SIGGRAPH 2025).\n\nClick to add a handle, "
            @"drag to sculpt. Space compares with the original.\n\nExamples, not covered by the "
            @"MIT license (details in Resources/artwork/README.md):%@"
            @"\n\nApplication: MIT. Metal-cpp: Apple, Apache 2.0.",
            credits]);
}

@end

static NSURL *fileIn(NSString *directory, NSString *name) {
    return [NSURL fileURLWithPath:[directory stringByAppendingPathComponent:name]];
}

static int smokeTest(NSString *directory) {
    Renderer renderer(shaderSource(), loadImage);
    double worstBasis = 0, totalMs = 0, worstMs = 0;
    int frames = 0;
    // Every generated group, then every bundled artwork.
    std::vector<State> cases;
    for (size_t gi = 0; gi < groups().size(); ++gi) {
        State s;
        s.group = int(gi);
        s.seed = 11;
        cases.push_back(s);
    }
    for (size_t ai = 0; ai < artworks().size(); ++ai) {
        State s;
        s.artwork = int(ai);
        s.group = artworks()[ai].group;
        if (!compatible(artworks()[ai]))
            throw std::runtime_error("Artwork basis does not fit its group: " + artworks()[ai].id);
        cases.push_back(s);
    }
    if (artworks().empty())
        throw std::runtime_error("No bundled artwork found");
    for (const State &s : cases) {
        std::string name = s.artwork >= 0 ? artworks()[s.artwork].id : groups()[s.group].name;
        const char *label = name.c_str();
        renderer.setArtwork(s);
        State sculpted = sculpt(s, 3);
        std::vector<Vec> loads;
        if (sculpted.handles.size() < 2 || !settle(renderer, sculpted, loads))
            throw std::runtime_error(std::string("Sculpt failed for ") + label);
        worstBasis = std::max(worstBasis, renderer.basisError(sculpted));
        auto tile = renderer.exportTile(sculpted, 512);
        for (size_t i = 3; i < tile.rgba.size(); i += 4)
            if (tile.rgba[i] != 255)
                throw std::runtime_error("Transparent pixel in export");
        writePNG(tile, fileIn(directory, [NSString stringWithFormat:@"%s.png", label]));
        // Seamless: a render of two periods must repeat exactly across both halves.
        {
            Vec size = repeatSize(sculpted);
            View twice;
            twice.center = size;
            twice.span = size * 2;
            twice.pixels = 256 / size.x;
            twice.handles = false;
            // Exactly two periods per axis: pixels may be very slightly non-square.
            unsigned w = 512, h = 2 * unsigned(std::lround(256 * size.y / size.x));
            auto image = renderer.render(twice, w, h, sculpted);
            double worst = 0;
            auto at = [&](unsigned x, unsigned y, int c) {
                return double(image.rgba[(size_t(y) * w + x) * 4 + c]);
            };
            for (unsigned y = 0; y < h / 2; ++y)
                for (unsigned x = 0; x < w / 2; ++x)
                    for (int c = 0; c < 3; ++c)
                        worst = std::max({worst, std::abs(at(x, y, c) - at(x + w / 2, y, c)),
                                          std::abs(at(x, y, c) - at(x, y + h / 2, c))});
            if (worst > 2)
                throw std::runtime_error(std::string("Pattern is not periodic for ") + label);
        }
        // Drag the first handle in a small circle, timing CPU mapping plus the GPU tile.
        for (int i = 0; i < 24; ++i) {
            State frame = sculpted;
            frame.handles[0].target =
                frame.handles[0].target + Vec{.01 * std::sin(i * .3), .01 * std::cos(i * .3)};
            auto begin = std::chrono::steady_clock::now();
            std::vector<Float2> mapped;
            if (!solve(frame, loads) || !renderer.evaluate(frame, loads, mapped))
                continue;
            renderer.accept(std::move(mapped));
            renderer.flush();
            double ms =
                std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - begin)
                    .count();
            totalMs += ms;
            worstMs = std::max(worstMs, ms);
            ++frames;
        }
        // Project round trip.
        State reopened;
        Vec camera;
        double zoom = 0;
        NSData *project = encodeProject(sculpted, {.5, .5}, 420, nil);
        if (!decodeProject(project, reopened, camera, zoom) || !equalState(sculpted, reopened))
            throw std::runtime_error(std::string("Project round trip failed for ") + label);
        // An extreme edit must be rejected without disturbing the accepted mesh.
        State extreme = sculpted;
        extreme.handles[0].target = extreme.handles[0].source + Vec{.6, .6};
        auto before = renderer.mapped();
        if (solve(extreme, loads) && renderer.update(extreme, loads))
            throw std::runtime_error(std::string("Fold accepted for ") + label);
        if (renderer.mapped().size() != before.size())
            throw std::runtime_error("Rejected edit replaced the mesh");
    }
    if (worstBasis > 5e-5)
        throw std::runtime_error("GPU basis disagrees with the CPU");
    State bad;
    Vec camera;
    double zoom;
    if (decodeProject([@"{\"version\":true}" dataUsingEncoding:NSUTF8StringEncoding], bad, camera,
                      zoom))
        throw std::runtime_error("Invalid project was accepted");
    printf("PASS: 17 generated groups and %zu artworks — material, sculpt, GPU basis, seamless "
           "opaque export, project round trip, fold rejection\nGPU basis max error %.3g\nDrag "
           "update (solve + map + fold check + GPU tile, synchronous): mean %.2f ms, max %.2f ms "
           "over %d frames\n",
           artworks().size(), worstBasis, totalMs / std::max(frames, 1), worstMs, frames);
    return 0;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        try {
            loadArtworks();
            if (argc >= 3 && std::string(argv[1]) == "--smoke-test") {
                NSString *directory = @(argv[2]);
                [[NSFileManager defaultManager] createDirectoryAtPath:directory
                                          withIntermediateDirectories:YES
                                                           attributes:nil
                                                                error:nil];
                return smokeTest(directory);
            }
            NSApplication *application = [NSApplication sharedApplication];
            [application setActivationPolicy:NSApplicationActivationPolicyRegular];
            App *delegate = [App new];
            application.delegate = delegate;
            [application run];
            return 0;
        } catch (const std::exception &e) {
            fprintf(stderr, "Escher Studio: %s\n", e.what());
            return 1;
        }
    }
}
