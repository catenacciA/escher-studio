#include "Art.hpp"
#include "Core.hpp"
#include <algorithm>
#include <cmath>
#include <iostream>
#include <random>
#include <stdexcept>
#include <string>
using namespace escher;

static void check(bool pass, const std::string &message) {
    if (!pass)
        throw std::runtime_error(message);
}

static bool integral(double v) {
    return std::abs(v - std::round(v)) < 1e-12;
}

static double matDistance(Mat a, Mat b) {
    return std::max(
        {std::abs(a.a - b.a), std::abs(a.b - b.b), std::abs(a.c - b.c), std::abs(a.d - b.d)});
}

int main() {
    try {
        std::mt19937 random(2025);
        std::uniform_real_distribution<double> uniform(-3, 3), unit(0, 1);
        const int orders[] = {1, 2, 2, 2, 2, 4, 4, 4, 4, 4, 8, 8, 3, 6, 6, 6, 12};
        check(groups().size() == 17, "Seventeen wallpaper groups");

        // Group tables: identity first, closed under composition modulo translations, isometric.
        for (size_t gi = 0; gi < groups().size(); ++gi) {
            const Group &g = groups()[gi];
            std::string name = g.name;
            check(int(g.ops.size()) == orders[gi], name + ": order");
            check(matDistance(g.ops[0].A, Mat{}) == 0 && length(g.ops[0].t) == 0,
                  name + ": identity first");
            Mat m = latticeBasis(g.lattice), mi = inverse(m);
            for (const Op &a : g.ops) {
                Mat w = m * a.A * mi, wtw{w.a * w.a + w.c * w.c, w.a * w.b + w.c * w.d,
                                          w.b * w.a + w.d * w.c, w.b * w.b + w.d * w.d};
                check(matDistance(wtw, Mat{}) < 1e-12, name + ": not an isometry");
                for (const Op &b : g.ops) {
                    Op ab{a.A * b.A, a.A * b.t + a.t};
                    int found = 0;
                    for (const Op &c : g.ops)
                        if (matDistance(c.A, ab.A) < 1e-12 && integral(ab.t.x - c.t.x) &&
                            integral(ab.t.y - c.t.y))
                            ++found;
                    check(found == 1, name + ": not closed under composition");
                }
            }
        }

        // Kernels: closed form against a converged lattice sum, and point-group invariance.
        double kernelError = 0;
        const Mat hexTerms[] = {{1, 0, 0, 1}, {0, -1, 1, -1}, {-1, 1, -1, 0},
                                {0, 1, 1, 0}, {1, -1, 0, -1}, {-1, 0, -1, 1}};
        for (double sigma : {.5, 1., 5., 10., 20.})
            for (int trial = 0; trial < 40; ++trial) {
                Vec p = {uniform(random), uniform(random)};
                auto latticeSum = [&](Vec q) {
                    int radius = int(std::ceil(60 / sigma)) + 2;
                    double sum = 0;
                    for (int n = -radius; n <= radius; ++n)
                        for (int k = -radius; k <= radius; ++k)
                            sum += std::exp2(-sigma * (std::abs(q.x - std::round(q.x) - k) +
                                                       std::abs(q.y - std::round(q.y) - n)));
                    return sum;
                };
                double square = latticeSum(p), hex = 0;
                for (const Mat &t : hexTerms)
                    hex += latticeSum(t * p) / 6;
                kernelError = std::max(
                    {kernelError, std::abs(kernel(p, sigma, Lattice::Square) - square) / square,
                     std::abs(kernel(p, sigma, Lattice::Hexagonal) - hex) / hex});
                for (const Group &g : groups())
                    for (const Op &op : g.ops)
                        check(std::abs(kernel(op.A * p, sigma, g.lattice) -
                                       kernel(p, sigma, g.lattice)) <
                                  1e-10 * kernel(p, sigma, g.lattice),
                              std::string(g.name) + ": kernel not invariant");
            }
        check(kernelError < 1e-11, "Kernel closed form differs from the lattice sum");

        // Fields: periodic and equivariant, F(g s) = g F(s), for every group.
        double periodError = 0, symmetryError = 0, handleError = 0;
        for (size_t gi = 0; gi < groups().size(); ++gi) {
            const Group &g = groups()[gi];
            State state;
            state.group = int(gi);
            state.sigma = 6;
            while (state.handles.size() < 3) {
                Vec p{unit(random), unit(random)};
                if (canAdd(state, p))
                    state.handles.push_back({p, p + Vec{.02 * unit(random), -.015 * unit(random)}});
            }
            std::vector<Vec> loads, sources;
            check(solve(state, loads), std::string(g.name) + ": solve failed");
            for (auto h : state.handles)
                sources.push_back(h.source);
            for (auto h : state.handles)
                handleError = std::max(
                    handleError,
                    length(h.source + displacement(g, h.source, sources, loads, state.sigma) -
                           h.target));
            for (int trial = 0; trial < 60; ++trial) {
                Vec s{uniform(random), uniform(random)};
                Vec u = displacement(g, s, sources, loads, state.sigma);
                periodError = std::max(
                    periodError,
                    length(u - displacement(g, s + Vec{3, -2}, sources, loads, state.sigma)));
                for (const Op &op : g.ops)
                    symmetryError = std::max(
                        symmetryError,
                        length(op.A * u - displacement(g, op(s), sources, loads, state.sigma)));
            }
            check(!canAdd(state, state.handles[0].source), std::string(g.name) + ": duplicate");
            if (g.ops.size() > 1)
                check(!canAdd(state, g.ops.back()(state.handles[1].source)),
                      std::string(g.name) + ": equivalent handle accepted");
            Art art = makeArt(state);
            check(art.colors >= 1 && art.colors <= 6 && art.inradius > .02,
                  std::string(g.name) + ": artwork");
            std::cout << g.name << " (" << g.orbifold << "): " << art.colors << " colours\n";
        }
        check(periodError < 1e-12 && symmetryError < 1e-12 && handleError < 1e-10,
              "Periodicity, equivariance or handle constraints failed");

        // Fixed sets: a mirror point and a rotation centre cannot carry a handle.
        State mirror;
        mirror.group = groupIndex("pm");
        check(!canAdd(mirror, {0, .3}) && !canAdd(mirror, {.5, .7}) && canAdd(mirror, {.25, .3}),
              "Mirror lines");
        State p4;
        check(!canAdd(p4, {.5, .5}) && !canAdd(p4, {0, .5}), "Rotation centres");
        p4.handles = {{{.23, .37}, {.27, .35}}, {{.12, .41}, {.12, .41}}};
        std::vector<Vec> loads;
        check(solve(p4, loads), "Constraint solve failed");
        p4.handles.push_back(p4.handles[0]);
        check(!solve(p4, loads), "Singular solve accepted");
        p4.sigma = 0;
        check(!solve(p4, loads), "Invalid locality accepted");

        // Artwork registration: a basis must make every operation an isometry.
        Artwork rhombic;
        rhombic.group = groupIndex("cm");
        rhombic.basis = {.6966, -.6966, .7174, .7174}; // a = (.6966, .7174), b = (-.6966, .7174)
        Artwork skewed = rhombic;
        skewed.basis = {.6966, -.5, .7174, .7174};
        Artwork hexagonal;
        hexagonal.group = groupIndex("p3m1");
        hexagonal.basis = {1, -.5, 0, std::sqrt(3.0) / 2};
        Artwork squareHex = hexagonal;
        squareHex.basis = {};
        check(compatible(rhombic) && compatible(hexagonal) && !compatible(skewed) &&
                  !compatible(squareHex),
              "Artwork basis compatibility");
        artworks() = {rhombic};
        State art;
        art.group = rhombic.group;
        art.artwork = 0;
        check(length(cellBasis(art) * Vec{1, 0} - Vec{.6966, .7174}) < 1e-12, "Artwork basis");
        art.handles = {{{.3, .1}, {.32, .12}}};
        check(solve(art, loads), "Artwork solve");
        art.group = groupIndex("p4");
        check(!solve(art, loads), "Artwork with the wrong group accepted");
        artworks().clear();

        Mesh mesh(32);
        check(mesh.valid(mesh.points), "Identity mesh rejected");
        auto inverted = mesh.points;
        std::swap(inverted[0], inverted[1]);
        check(!mesh.valid(inverted), "Inverted triangle accepted");
        Vec picked;
        check(mesh.pick({.23, .37}, mesh.points, picked) && length(picked - Vec{.23, .37}) < 1e-6,
              "Identity pick failed");
        const Group &g4 = groups()[9];
        std::vector<Vec> sources = {{.23, .37}, {.12, .41}}, mild = {{.025, 0}, {0, .015}};
        auto mapped = mesh.points;
        for (auto &p : mapped) {
            auto u = displacement(g4, {p.x, p.y}, sources, mild, 10);
            p.x += float(u.x);
            p.y += float(u.y);
        }
        check(mesh.valid(mapped), "Mild deformation rejected");
        check(mesh.pick({.3, .3}, mapped, picked), "Deformed mesh pick failed");
        auto returned = picked + displacement(g4, picked, sources, mild, 10);
        check(length(returned - Vec{.3, .3}) < .001, "Deformed pick residual");
        std::cout << "PASS: 17 group tables, closed-form kernels, periodicity, equivariance, "
                     "handle constraints, fixed sets, artwork, mesh guard and picking\n";
        std::cout << "Maximum errors: kernel " << kernelError << " (relative), periodicity "
                  << periodError << ", equivariance " << symmetryError << ", handles "
                  << handleError << "\n";
        return 0;
    } catch (const std::exception &e) {
        std::cerr << "FAIL: " << e.what() << "\n";
        return 1;
    }
}
