// X25519 (Curve25519 scalar multiplication) for WireGuard key generation.
// Header-only; the field arithmetic is TweetNaCl's crypto_scalarmult
// (public domain, https://tweetnacl.cr.yp.to).
#pragma once

#include <stdint.h>
#include <string.h>

typedef int64_t pa_gf[16];

static const pa_gf pa_121665 = {0xDB41, 1};

static void pa_car25519(pa_gf o) {
    for (int i = 0; i < 16; i++) {
        o[i] += (1LL << 16);
        int64_t c = o[i] >> 16;
        o[(i + 1) * (i < 15)] += c - 1 + 37 * (c - 1) * (i == 15);
        o[i] -= c << 16;
    }
}

static void pa_sel25519(pa_gf p, pa_gf q, int b) {
    int64_t c = ~(int64_t)(b - 1);
    for (int i = 0; i < 16; i++) {
        int64_t t = c & (p[i] ^ q[i]);
        p[i] ^= t;
        q[i] ^= t;
    }
}

static void pa_pack25519(uint8_t *o, const pa_gf n) {
    pa_gf m, t;
    for (int i = 0; i < 16; i++) t[i] = n[i];
    pa_car25519(t);
    pa_car25519(t);
    pa_car25519(t);
    for (int j = 0; j < 2; j++) {
        m[0] = t[0] - 0xffed;
        for (int i = 1; i < 15; i++) {
            m[i] = t[i] - 0xffff - ((m[i - 1] >> 16) & 1);
            m[i - 1] &= 0xffff;
        }
        m[15] = t[15] - 0x7fff - ((m[14] >> 16) & 1);
        int b = (int)((m[15] >> 16) & 1);
        m[14] &= 0xffff;
        pa_sel25519(t, m, 1 - b);
    }
    for (int i = 0; i < 16; i++) {
        o[2 * i] = t[i] & 0xff;
        o[2 * i + 1] = (uint8_t)(t[i] >> 8);
    }
}

static void pa_unpack25519(pa_gf o, const uint8_t *n) {
    for (int i = 0; i < 16; i++) o[i] = n[2 * i] + ((int64_t)n[2 * i + 1] << 8);
    o[15] &= 0x7fff;
}

static void pa_A(pa_gf o, const pa_gf a, const pa_gf b) {
    for (int i = 0; i < 16; i++) o[i] = a[i] + b[i];
}

static void pa_Z(pa_gf o, const pa_gf a, const pa_gf b) {
    for (int i = 0; i < 16; i++) o[i] = a[i] - b[i];
}

static void pa_M(pa_gf o, const pa_gf a, const pa_gf b) {
    int64_t t[31];
    for (int i = 0; i < 31; i++) t[i] = 0;
    for (int i = 0; i < 16; i++)
        for (int j = 0; j < 16; j++) t[i + j] += a[i] * b[j];
    for (int i = 0; i < 15; i++) t[i] += 38 * t[i + 16];
    for (int i = 0; i < 16; i++) o[i] = t[i];
    pa_car25519(o);
    pa_car25519(o);
}

static void pa_S(pa_gf o, const pa_gf a) { pa_M(o, a, a); }

static void pa_inv25519(pa_gf o, const pa_gf in) {
    pa_gf c;
    for (int a = 0; a < 16; a++) c[a] = in[a];
    for (int a = 253; a >= 0; a--) {
        pa_S(c, c);
        if (a != 2 && a != 4) pa_M(c, c, in);
    }
    for (int a = 0; a < 16; a++) o[a] = c[a];
}

// q = n * p (all 32 bytes)
static void pa_x25519(uint8_t q[32], const uint8_t n[32], const uint8_t p[32]) {
    uint8_t z[32];
    int64_t x[80];
    pa_gf a, b, c, d, e, f;
    for (int i = 0; i < 31; i++) z[i] = n[i];
    z[31] = (n[31] & 127) | 64;
    z[0] &= 248;
    pa_unpack25519(x, p);
    for (int i = 0; i < 16; i++) {
        b[i] = x[i];
        d[i] = a[i] = c[i] = 0;
    }
    a[0] = d[0] = 1;
    for (int i = 254; i >= 0; --i) {
        int r = (z[i >> 3] >> (i & 7)) & 1;
        pa_sel25519(a, b, r);
        pa_sel25519(c, d, r);
        pa_A(e, a, c);
        pa_Z(a, a, c);
        pa_A(c, b, d);
        pa_Z(b, b, d);
        pa_S(d, e);
        pa_S(f, a);
        pa_M(a, c, a);
        pa_M(c, b, e);
        pa_A(e, a, c);
        pa_Z(a, a, c);
        pa_S(b, a);
        pa_Z(c, d, f);
        pa_M(a, c, pa_121665);
        pa_A(a, a, d);
        pa_M(c, c, a);
        pa_M(a, d, f);
        pa_M(d, b, x);
        pa_S(b, e);
        pa_sel25519(a, b, r);
        pa_sel25519(c, d, r);
    }
    for (int i = 0; i < 16; i++) {
        x[i + 16] = a[i];
        x[i + 32] = c[i];
        x[i + 48] = b[i];
        x[i + 64] = d[i];
    }
    pa_inv25519(x + 32, x + 32);
    pa_M(x + 16, x + 16, x + 32);
    pa_pack25519(q, x + 16);
}

// public = private * 9; clamps `priv` in place (WireGuard key format)
static void pa_x25519_keypair(uint8_t pub[32], uint8_t priv[32]) {
    static const uint8_t base[32] = {9};
    priv[0] &= 248;
    priv[31] = (priv[31] & 127) | 64;
    pa_x25519(pub, priv, base);
}
