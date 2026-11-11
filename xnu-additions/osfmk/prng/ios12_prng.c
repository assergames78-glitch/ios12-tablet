/*
 * ios12-tablet: kernel PRNG backend.
 *
 * read_random() (osfmk/prng/prng_random.c) calls through prng_fns, which the
 * closed-source corecrypto kext normally provides via register_and_init_prng().
 * Without that kext the PRNG lock is NULL and the first read_random() panics
 * (seen in IOPMrootDomain::start -> uuid_generate). This backend implements the
 * same four callbacks with the NIST SP 800-90A HMAC-DRBG (SHA-256) that ships
 * in xnu's own osfmk/corecrypto, seeded by xnu's entropy collector.
 */
#include <stdint.h>
#include <string.h>
#include <kern/debug.h>
#include <mach/mach_time.h>
#include <corecrypto/cc_error.h>
#include <corecrypto/ccdrbg.h>
#include <corecrypto/ccsha2.h>
#include <corecrypto/cckprng.h>
#include <prng/random.h>

#define DRBG_STATE_BYTES  1024
#define DRBG_MIN_SEED     32          /* SHA-256 security strength */
#define DRBG_CHUNK        4096

static struct ccdrbg_info ios12_drbg_info;
static const struct ccdrbg_nisthmac_custom ios12_drbg_custom = {
	.di = &ccsha256_ltc_di,
	.strictFIPS = 0,
};
static uint64_t ios12_drbg_state[DRBG_STATE_BYTES / sizeof(uint64_t)];
static int ios12_prng_registered;

#define STATE ((struct ccdrbg_state *)ios12_drbg_state)

/* The DRBG insists on >= 32 bytes per seed/reseed; pad short inputs. */
static int
ios12_reseed_any(size_t n, const void *data)
{
	uint8_t pad[DRBG_MIN_SEED];
	if (n < DRBG_MIN_SEED) {
		memset(pad, 0, sizeof(pad));
		memcpy(pad, data, n);
		data = pad;
		n = sizeof(pad);
	}
	int rc = ccdrbg_reseed(&ios12_drbg_info, STATE, n, data, 0, NULL);
	return rc == CCDRBG_STATUS_OK ? CCKPRNG_OK : CCKPRNG_ABORT;
}

static int
ios12_prng_init(cckprng_ctx_t ctx, size_t nbytes, const void *seed)
{
	(void)ctx;
	ccdrbg_factory_nisthmac(&ios12_drbg_info, &ios12_drbg_custom);
	if (ios12_drbg_info.size > sizeof(ios12_drbg_state)) {
		panic("ios12_prng: DRBG state needs %zu bytes", (size_t)ios12_drbg_info.size);
	}
	uint8_t pad[DRBG_MIN_SEED];
	if (nbytes < DRBG_MIN_SEED) {
		memset(pad, 0, sizeof(pad));
		memcpy(pad, seed, nbytes);
		seed = pad;
		nbytes = sizeof(pad);
	}
	uint64_t nonce = mach_absolute_time();
	int rc = ccdrbg_init(&ios12_drbg_info, STATE, nbytes, seed,
	    sizeof(nonce), &nonce, 0, NULL);
	return rc == CCDRBG_STATUS_OK ? CCKPRNG_OK : CCKPRNG_ABORT;
}

static int
ios12_prng_reseed(cckprng_ctx_t ctx, size_t nbytes, const void *seed)
{
	(void)ctx;
	return ios12_reseed_any(nbytes, seed);
}

static int
ios12_prng_addentropy(cckprng_ctx_t ctx, size_t nbytes, const void *entropy)
{
	(void)ctx;
	return ios12_reseed_any(nbytes, entropy);
}

static int
ios12_prng_generate(cckprng_ctx_t ctx, size_t nbytes, void *out)
{
	(void)ctx;
	uint8_t *p = out;
	while (nbytes > 0) {
		size_t n = nbytes > DRBG_CHUNK ? DRBG_CHUNK : nbytes;
		int rc = ccdrbg_generate(&ios12_drbg_info, STATE, n, p, 0, NULL);
		if (rc == CCDRBG_STATUS_NEED_RESEED) {
			return CCKPRNG_NEED_ENTROPY;
		}
		if (rc != CCDRBG_STATUS_OK) {
			return CCKPRNG_ABORT;
		}
		p += n;
		nbytes -= n;
	}
	return CCKPRNG_OK;
}

static const struct prng_fns ios12_prng_fns = {
	.init       = ios12_prng_init,
	.reseed     = ios12_prng_reseed,
	.addentropy = ios12_prng_addentropy,
	.generate   = ios12_prng_generate,
};

/* Called by Ios12TabletPlatform::start before anything needs read_random(). */
void ios12_prng_register(void);
void
ios12_prng_register(void)
{
	if (ios12_prng_registered) {
		return;
	}
	ios12_prng_registered = 1;
	register_and_init_prng(&ios12_prng_fns);
}
