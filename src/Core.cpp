#include "Core.hpp"
#include <algorithm>
#include <cmath>
#include <limits>

namespace escher {
Mat inverse(Mat m) {
    double det = m.a * m.d - m.b * m.c;
    return {m.d / det, -m.b / det, -m.c / det, m.a / det};
}

Op inverse(Op g) {
    Mat a = inverse(g.A);
    return {a, (a * g.t) * -1};
}

const std::vector<Group> &groups() {
    // International Tables coordinates. p1 and p2 use an oblique lattice, so their Dirichlet
    // tiles are hexagons rather than squares; the kernel only needs invariance under -I.
    // cm and cmm use a square lattice with diagonal mirrors (a rhombic, centred cell).
    const Mat I{1, 0, 0, 1}, N{-1, 0, 0, -1}, X{-1, 0, 0, 1}, Y{1, 0, 0, -1}, S{0, 1, 1, 0},
        Sn{0, -1, -1, 0}, R{0, -1, 1, 0}, Rn{0, 1, -1, 0};
    const Mat H1{0, -1, 1, -1}, H2{-1, 1, -1, 0}, H3{1, -1, 1, 0}, H4{0, 1, -1, 1},
        M1{0, -1, -1, 0}, M2{-1, 1, 0, 1}, M3{1, 0, 1, -1}, M4{0, 1, 1, 0}, M5{1, -1, 0, -1},
        M6{-1, 0, -1, 1};
    const Vec o{0, 0}, hx{.5, 0}, hy{0, .5}, hh{.5, .5};
    const auto ob = Lattice::Oblique, sq = Lattice::Square, hex = Lattice::Hexagonal;
    static const std::vector<Group> all = {
        {"p1", "o", ob, {{I, o}}},
        {"p2", "2222", ob, {{I, o}, {N, o}}},
        {"pm", "**", sq, {{I, o}, {X, o}}},
        {"pg", "xx", sq, {{I, o}, {X, hy}}},
        {"cm", "*x", sq, {{I, o}, {S, o}}},
        {"pmm", "*2222", sq, {{I, o}, {N, o}, {X, o}, {Y, o}}},
        {"pmg", "22*", sq, {{I, o}, {N, o}, {X, hx}, {Y, hx}}},
        {"pgg", "22x", sq, {{I, o}, {N, o}, {X, hh}, {Y, hh}}},
        {"cmm", "2*22", sq, {{I, o}, {N, o}, {S, o}, {Sn, o}}},
        {"p4", "442", sq, {{I, o}, {N, o}, {R, o}, {Rn, o}}},
        {"p4m", "*442", sq, {{I, o}, {N, o}, {R, o}, {Rn, o}, {X, o}, {Y, o}, {S, o}, {Sn, o}}},
        {"p4g", "4*2", sq, {{I, o}, {N, o}, {R, o}, {Rn, o}, {X, hh}, {Y, hh}, {S, hh}, {Sn, hh}}},
        {"p3", "333", hex, {{I, o}, {H1, o}, {H2, o}}},
        {"p3m1", "*333", hex, {{I, o}, {H1, o}, {H2, o}, {M1, o}, {M2, o}, {M3, o}}},
        {"p31m", "3*3", hex, {{I, o}, {H1, o}, {H2, o}, {M4, o}, {M5, o}, {M6, o}}},
        {"p6", "632", hex, {{I, o}, {H1, o}, {H2, o}, {N, o}, {H4, o}, {H3, o}}},
        {"p6m",
         "*632",
         hex,
         {{I, o},
          {H1, o},
          {H2, o},
          {N, o},
          {H4, o},
          {H3, o},
          {M1, o},
          {M2, o},
          {M3, o},
          {M4, o},
          {M5, o},
          {M6, o}}},
    };
    return all;
}

int groupIndex(const std::string &name) {
    for (size_t i = 0; i < groups().size(); ++i)
        if (name == groups()[i].name)
            return int(i);
    return -1;
}

Mat latticeBasis(Lattice lattice) {
    if (lattice == Lattice::Oblique)
        return {1, .5, 0, .85};
    if (lattice == Lattice::Square)
        return {};
    return {1, -.5, 0, std::sqrt(3.0) / 2};
}

double length(Vec v) {
    return std::hypot(v.x, v.y);
}

double cross(Vec a, Vec b) {
    return a.x * b.y - a.y * b.x;
}

Vec wrap(Vec p) {
    return {p.x - std::floor(p.x), p.y - std::floor(p.y)};
}

Vec wrapCentered(Vec p) {
    return wrap(p + Vec{.5, .5}) - Vec{.5, .5};
}

std::vector<Artwork> &artworks() {
    static std::vector<Artwork> all;
    return all;
}

bool compatible(const Artwork &art) {
    if (art.group < 0 || art.group >= int(groups().size()))
        return false;
    Mat m = art.basis, mi = inverse(m);
    if (!std::isfinite(mi.a) || !std::isfinite(mi.d))
        return false;
    for (const Op &op : groups()[art.group].ops) {
        Mat w = m * op.A * mi;
        if (std::abs(w.a * w.a + w.c * w.c - 1) > 1e-4 ||
            std::abs(w.b * w.b + w.d * w.d - 1) > 1e-4 || std::abs(w.a * w.b + w.c * w.d) > 1e-4)
            return false;
    }
    return true;
}

Mat cellBasis(const State &s) {
    if (s.artwork >= 0 && s.artwork < int(artworks().size()))
        return artworks()[s.artwork].basis;
    return latticeBasis(groups()[s.group].lattice);
}

int supercell(const State &s) {
    if (s.artwork >= 0 && s.artwork < int(artworks().size()))
        return artworks()[s.artwork].supercell;
    return 2;
}

double latticeDistance(Mat m, Vec a, Vec b) {
    Vec d = wrapCentered(a - b);
    double best = std::numeric_limits<double>::infinity();
    for (int y = -1; y <= 1; ++y)
        for (int x = -1; x <= 1; ++x)
            best = std::min(best, length(m * (d + Vec{double(x), double(y)})));
    return best;
}

static double squareKernel(Vec d, double sigma) {
    // Paper equations 3–5, factored into two convergent geometric series.
    d = wrap(d);
    const double a = sigma * std::log(2.0), denominator = -std::expm1(-a);
    auto axis = [&](double t) { return (std::exp(-a * t) + std::exp(-a * (1 - t))) / denominator; };
    return axis(d.x) * axis(d.y);
}

double kernel(Vec d, double sigma, Lattice lattice) {
    if (lattice != Lattice::Hexagonal)
        return squareKernel(d, sigma);
    // Symmetrize the square closed form over the hexagonal point group D3 (D6 with ±).
    // Each term is an integer unimodular change of lattice basis, so it stays periodic.
    static const Mat terms[] = {{1, 0, 0, 1}, {0, -1, 1, -1}, {-1, 1, -1, 0},
                                {0, 1, 1, 0}, {1, -1, 0, -1}, {-1, 0, -1, 1}};
    double sum = 0;
    for (const Mat &m : terms)
        sum += squareKernel(m * d, sigma);
    return sum / 6;
}

Mat basis(const Group &g, Vec s, Vec h, double sigma) {
    Mat result{0, 0, 0, 0};
    for (const Op &op : g.ops)
        result = result + op.A * kernel(s - op(h), sigma, g.lattice);
    return result;
}

Vec displacement(const Group &g, Vec s, const std::vector<Vec> &h, const std::vector<Vec> &a,
                 double sigma) {
    Vec result;
    for (size_t i = 0; i < h.size(); ++i)
        result = result + basis(g, s, h[i], sigma) * a[i];
    return result;
}

bool solve(const State &s, std::vector<Vec> &loads) {
    // Calibrate the paper's load vectors; do not alter its analytical weights.
    const size_t n = s.handles.size() * 2;
    if (s.group < 0 || s.group >= int(groups().size()) || s.handles.size() > maxHandles ||
        !std::isfinite(s.sigma) || s.sigma < .5 || s.sigma > 20 || s.artwork < -1 ||
        s.artwork >= int(artworks().size()) ||
        (s.artwork >= 0 && artworks()[s.artwork].group != s.group))
        return false;
    if (!n) {
        loads.clear();
        return true;
    }
    const Group &group = groups()[s.group];
    std::vector<double> m(n * (n + 1), 0);
    double maxEntry = 0;
    for (size_t i = 0; i < n / 2; ++i) {
        const auto &h = s.handles[i];
        if (!std::isfinite(h.source.x) || !std::isfinite(h.source.y) ||
            !std::isfinite(h.target.x) || !std::isfinite(h.target.y))
            return false;
        for (size_t j = 0; j < n / 2; ++j) {
            Mat b = basis(group, h.source, s.handles[j].source, s.sigma);
            m[(2 * i) * (n + 1) + 2 * j] = b.a;
            m[(2 * i) * (n + 1) + 2 * j + 1] = b.b;
            m[(2 * i + 1) * (n + 1) + 2 * j] = b.c;
            m[(2 * i + 1) * (n + 1) + 2 * j + 1] = b.d;
            maxEntry =
                std::max({maxEntry, std::abs(b.a), std::abs(b.b), std::abs(b.c), std::abs(b.d)});
        }
        auto d = h.target - h.source;
        m[2 * i * (n + 1) + n] = d.x;
        m[(2 * i + 1) * (n + 1) + n] = d.y;
    }
    for (size_t k = 0; k < n; ++k) {
        size_t pivot = k;
        for (size_t i = k + 1; i < n; ++i)
            if (std::abs(m[i * (n + 1) + k]) > std::abs(m[pivot * (n + 1) + k]))
                pivot = i;
        if (std::abs(m[pivot * (n + 1) + k]) < std::max(1e-12, maxEntry * 1e-8))
            return false;
        if (pivot != k)
            for (size_t j = k; j <= n; ++j)
                std::swap(m[k * (n + 1) + j], m[pivot * (n + 1) + j]);
        for (size_t i = k + 1; i < n; ++i) {
            double f = m[i * (n + 1) + k] / m[k * (n + 1) + k];
            for (size_t j = k; j <= n; ++j)
                m[i * (n + 1) + j] -= f * m[k * (n + 1) + j];
        }
    }
    std::vector<double> x(n);
    for (size_t i = n; i-- > 0;) {
        double v = m[i * (n + 1) + n];
        for (size_t j = i + 1; j < n; ++j)
            v -= m[i * (n + 1) + j] * x[j];
        x[i] = v / m[i * (n + 1) + i];
        if (!std::isfinite(x[i]) || std::abs(x[i]) > 100)
            return false;
    }
    loads.resize(n / 2);
    for (size_t i = 0; i < n / 2; ++i)
        loads[i] = {x[2 * i], x[2 * i + 1]};
    std::vector<Vec> sources;
    for (auto h : s.handles)
        sources.push_back(h.source);
    for (auto h : s.handles)
        if (length(h.source + displacement(group, h.source, sources, loads, s.sigma) - h.target) >
            1e-7)
            return false;
    return true;
}

bool canAdd(const State &s, Vec p) {
    if (s.handles.size() >= maxHandles || s.group < 0 || s.group >= int(groups().size()))
        return false;
    const Group &g = groups()[s.group];
    const Mat m = cellBasis(s);
    // Points on mirrors or rotation centres cannot leave them.
    for (size_t k = 1; k < g.ops.size(); ++k)
        if (latticeDistance(m, p, g.ops[k](p)) < .03)
            return false;
    for (auto h : s.handles)
        for (const Op &op : g.ops)
            if (latticeDistance(m, p, op(h.source)) < .025)
                return false;
    return true;
}

Mesh::Mesh(unsigned n) {
    for (unsigned y = 0; y <= n; ++y)
        for (unsigned x = 0; x <= n; ++x)
            points.push_back({float(x) / n, float(y) / n});
    const uint32_t centers = uint32_t(points.size());
    for (unsigned y = 0; y < n; ++y)
        for (unsigned x = 0; x < n; ++x) {
            points.push_back({(x + .5f) / n, (y + .5f) / n});
            uint32_t a = y * (n + 1) + x, b = a + 1, c = a + n + 2, d = a + n + 1,
                     e = centers + y * n + x;
            for (auto t : {std::array<uint32_t, 3>{a, b, e}, {b, c, e}, {c, d, e}, {d, a, e}})
                indices.insert(indices.end(), t.begin(), t.end());
        }
}

static Vec asVec(Float2 p) {
    return {p.x, p.y};
}

bool Mesh::valid(const std::vector<Float2> &p) const {
    if (p.size() != points.size())
        return false;
    for (size_t i = 0; i < p.size(); ++i) {
        if (!std::isfinite(p[i].x) || !std::isfinite(p[i].y) ||
            length(asVec(p[i]) - asVec(points[i])) > .45)
            return false;
    }
    for (size_t i = 0; i < indices.size(); i += 3) {
        auto a = indices[i], b = indices[i + 1], c = indices[i + 2];
        double original =
            cross(asVec(points[b]) - asVec(points[a]), asVec(points[c]) - asVec(points[a]));
        double deformed = cross(asVec(p[b]) - asVec(p[a]), asVec(p[c]) - asVec(p[a]));
        if (deformed < original * .08)
            return false;
    }
    return true;
}

bool Mesh::pick(Vec q, const std::vector<Float2> &p, Vec &source) const {
    q = wrap(q);
    for (int oy = -1; oy <= 1; ++oy)
        for (int ox = -1; ox <= 1; ++ox) {
            Vec v = q + Vec{double(ox), double(oy)};
            for (size_t i = 0; i < indices.size(); i += 3) {
                auto ia = indices[i], ib = indices[i + 1], ic = indices[i + 2];
                Vec a = asVec(p[ia]), b = asVec(p[ib]), c = asVec(p[ic]);
                if (v.x < std::min({a.x, b.x, c.x}) - 1e-8 ||
                    v.x > std::max({a.x, b.x, c.x}) + 1e-8 ||
                    v.y < std::min({a.y, b.y, c.y}) - 1e-8 ||
                    v.y > std::max({a.y, b.y, c.y}) + 1e-8)
                    continue;
                double det = cross(b - a, c - a);
                double u = cross(v - a, c - a) / det, w = cross(b - a, v - a) / det;
                if (u >= -1e-6 && w >= -1e-6 && u + w <= 1 + 1e-6) {
                    source = wrap(asVec(points[ia]) * (1 - u - w) + asVec(points[ib]) * u +
                                  asVec(points[ic]) * w);
                    return true;
                }
            }
        }
    return false;
}
} // namespace escher
