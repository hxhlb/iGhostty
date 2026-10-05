// Declarations for the SPAKE2+ (CCC variant) functions libcorecrypto exports,
// written for this project from the exported symbols and their documented
// calling convention. Every one of them is present in iOS 15.0's
// libcorecrypto and in every later release; nothing newer is declared here.
//
// Two facts the declarations do not show, both checked against the system
// library: the session key `ccspake_mac_verify_and_get_session_key` hands
// back is half the MAC's digest (16 bytes for HMAC-SHA256), and a scalar w is
// `ccspake_sizeof_w` bytes (40 for P-256) that the library maps to
// (w mod (n - 1)) + 1. `PairingExchange` relies on both.

#ifndef IGHOSTVT_CORECRYPTO_SHIM_H
#define IGHOSTVT_CORECRYPTO_SHIM_H

#include <stddef.h>
#include <stdint.h>

struct ccspake_ctx;
struct ccspake_cp;
struct ccspake_mac;
struct ccrng_state;

typedef const struct ccspake_cp *ighostvt_ccspake_cp_t;
typedef const struct ccspake_mac *ighostvt_ccspake_mac_t;

struct ccrng_state *ccrng(int *error);

ighostvt_ccspake_cp_t ccspake_cp_256(void);
ighostvt_ccspake_mac_t ccspake_mac_hkdf_hmac_sha256(void);

size_t ccspake_sizeof_ctx(ighostvt_ccspake_cp_t cp);
size_t ccspake_sizeof_w(ighostvt_ccspake_cp_t cp);
size_t ccspake_sizeof_point(ighostvt_ccspake_cp_t cp);

int ccspake_prover_init(struct ccspake_ctx *ctx,
                        ighostvt_ccspake_cp_t cp,
                        ighostvt_ccspake_mac_t mac,
                        struct ccrng_state *rng,
                        size_t aad_nbytes,
                        const uint8_t *aad,
                        size_t w_nbytes,
                        const uint8_t *w0,
                        const uint8_t *w1);

int ccspake_verifier_init(struct ccspake_ctx *ctx,
                          ighostvt_ccspake_cp_t cp,
                          ighostvt_ccspake_mac_t mac,
                          struct ccrng_state *rng,
                          size_t aad_nbytes,
                          const uint8_t *aad,
                          size_t w0_nbytes,
                          const uint8_t *w0,
                          size_t L_nbytes,
                          const uint8_t *L);

int ccspake_kex_generate(struct ccspake_ctx *ctx, size_t x_nbytes, uint8_t *x);
int ccspake_kex_process(struct ccspake_ctx *ctx, size_t y_nbytes, const uint8_t *y);
int ccspake_mac_compute(struct ccspake_ctx *ctx, size_t t_nbytes, uint8_t *t);
int ccspake_mac_verify_and_get_session_key(struct ccspake_ctx *ctx,
                                           size_t t_nbytes,
                                           const uint8_t *t,
                                           size_t sk_nbytes,
                                           uint8_t *sk);

#endif
