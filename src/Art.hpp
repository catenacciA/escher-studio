#pragma once
#include "Core.hpp"

namespace escher {
struct Rgb {
    float r, g, b;
};

struct Palette {
    const char *name;
    Rgb ink, paper;
    std::array<Rgb, 6> tones; // tones[0..k) colour a k-colourable tiling
};

const std::vector<Palette> &palettes();

// Where op k sends a site: the same tile as canonical op `op`, translated by m.
struct Orbit {
    int op, mx, my;
};

std::vector<Orbit> orbits(const Group &group, Vec site);

struct Site {
    Vec position;           // lattice coordinates
    bool symmetric = false; // non-trivial stabilizer: the tile is itself symmetric
    Vec eye;                // world offset of the eye from the site (asymmetric tiles)
    double inradius = 0;    // world distance from the site to its tile's nearest edge
};

// The undeformed tiling: Dirichlet tiles of one or two orbits, properly coloured on a 2 × 2
// supercell, with an eye that reveals each tile's isometry.
struct Art {
    std::vector<Site> sites;
    std::vector<int> color; // [(site * 12 + canonical op) * 4 + parity of the translation]
    int colors = 0;
    double inradius = 0; // smallest site inradius
};

constexpr int maxOps = 12, maxSites = 2;

Art makeArt(const State &state);

// Deterministic sculpt: handles on tile edges pushed across them.
State sculpt(const State &state, uint32_t seed);
} // namespace escher
