#pragma once
#include <array>
#include <cstdint>
#include <string>
#include <vector>

namespace escher {
struct Vec {
    double x = 0, y = 0;

    Vec operator+(Vec b) const { return {x + b.x, y + b.y}; }

    Vec operator-(Vec b) const { return {x - b.x, y - b.y}; }

    Vec operator*(double s) const { return {x * s, y * s}; }
};

// Row-major 2 × 2 matrix [a b; c d].
struct Mat {
    double a = 1, b = 0, c = 0, d = 1;

    Vec operator*(Vec v) const { return {a * v.x + b * v.y, c * v.x + d * v.y}; }

    Mat operator*(Mat m) const {
        return {a * m.a + b * m.c, a * m.b + b * m.d, c * m.a + d * m.c, c * m.b + d * m.d};
    }

    Mat operator+(Mat m) const { return {a + m.a, b + m.b, c + m.c, d + m.d}; }

    Mat operator*(double s) const { return {a * s, b * s, c * s, d * s}; }
};

Mat inverse(Mat m);

// An isometry in lattice coordinates: s -> A s + t.
struct Op {
    Mat A;
    Vec t;

    Vec operator()(Vec s) const { return A * s + t; }
};

Op inverse(Op g);

enum class Lattice { Oblique, Square, Hexagonal };

struct Group {
    const char *name, *orbifold;
    Lattice lattice;
    std::vector<Op> ops; // One representative per coset of the translations; ops[0] = identity.
};

const std::vector<Group> &groups();
int groupIndex(const std::string &name);
// World = basis * lattice coordinates, a = (1,0) throughout. Oblique: b = (1/2, 0.85);
// square: b = (0,1); hexagonal: b = (-1/2, √3/2).
Mat latticeBasis(Lattice lattice);

// Third-party artwork: a texture of the 2 × 2 supercell in lattice coordinates, with the exact
// world basis of its pattern. Registered at startup from resources/artwork/artworks.json.
struct Artwork {
    std::string id, collection, title, english, artist, source, license, url, museum, texture;
    int group = -1;
    Mat basis;
    int supercell = 2;  // lattice cells across the texture (its exact repeat fits inside)
    double density = 0; // source pixels per lattice unit, for a sharp default zoom
};

std::vector<Artwork> &artworks();
// True when every operation of the group is an isometry in the artwork's basis.
bool compatible(const Artwork &artwork);

double length(Vec v);
double cross(Vec a, Vec b);
Vec wrap(Vec p);
Vec wrapCentered(Vec p);
// Shortest world-space distance between a and any lattice translate of b.
double latticeDistance(Mat basis, Vec a, Vec b);

// Closed-form periodic kernel in lattice coordinates, invariant under the lattice's point group.
double kernel(Vec delta, double sigma, Lattice lattice);
// Equivariant basis of one handle at h: B(s) = Σ_g w(s - g h) A_g, so u(s) = Σ B_i(s) a_i.
Mat basis(const Group &group, Vec s, Vec h, double sigma);
Vec displacement(const Group &group, Vec s, const std::vector<Vec> &sources,
                 const std::vector<Vec> &loads, double sigma);

struct Handle {
    Vec source, target;
};

constexpr size_t maxHandles = 8;

struct State {
    int group = 9;    // p4
    int artwork = -1; // index into artworks(), or -1 for a generated tiling
    uint32_t seed = 7;
    int palette = 0;
    double sigma = 8;
    std::vector<Handle> handles;
};

// World = cellBasis(state) * lattice coordinates.
Mat cellBasis(const State &state);
// Lattice cells across the material texture: 2 for generated tilings.
int supercell(const State &state);
bool solve(const State &state, std::vector<Vec> &loads);
bool canAdd(const State &state, Vec source);

struct Float2 {
    float x, y;
};

struct Mesh {
    std::vector<Float2> points;
    std::vector<uint32_t> indices;
    explicit Mesh(unsigned divisions = 128);
    bool valid(const std::vector<Float2> &mapped) const;
    bool pick(Vec destination, const std::vector<Float2> &mapped, Vec &source) const;
};
} // namespace escher
