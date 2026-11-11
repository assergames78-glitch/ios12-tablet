/*
 * ios12-tablet: a minimal IOKit platform driver.
 *
 * On a real iPhone, a closed-source platform kext (AppleARMPlatform and
 * friends) claims the IOPlatformExpertDevice root nub. Without one, IOKit
 * falls back to IOPanicPlatform, which panics with
 * "Unable to find driver for this platform". This class claims the root nub
 * for our boards ("Pi3,1" in QEMU, "MT6737T,1" on the tablet) using the
 * generic device-tree platform expert, so IOKit can keep booting.
 */
#include <IOKit/IOPlatformExpert.h>
#include <IOKit/IOLib.h>
#include <pexpert/pexpert.h>
#include <mach/mach_time.h>

/*
 * Boot diagnostics: a thread that prints a heartbeat every 2 seconds. If the
 * heartbeats stop (or never start), the kernel's timer isn't firing; if they
 * keep coming while boot is stuck, the kernel is waiting for something else.
 * Enabled with the boot-arg "ios12hb=1".
 */
static void
ios12_heartbeat(void *arg __unused)
{
	for (unsigned n = 1;; n++) {
		IOSleep(2000);
		uint64_t now = mach_absolute_time();
		IOLog("ios12-tablet: heartbeat %u (mach_absolute_time %llu, timebase %u Hz)\n",
		    n, now, (unsigned)gPEClockFrequencyInfo.timebase_frequency_hz);
	}
}

/* osfmk/prng/ios12_prng.c: stands in for the corecrypto kext's PRNG. */
extern "C" void ios12_prng_register(void);

class Ios12TabletPlatform : public IODTPlatformExpert
{
	OSDeclareDefaultStructors(Ios12TabletPlatform);

public:
	virtual bool start(IOService * provider) APPLE_KEXT_OVERRIDE;
	virtual const char * deleteList(void) APPLE_KEXT_OVERRIDE;
	virtual const char * excludeList(void) APPLE_KEXT_OVERRIDE;
};

#define super IODTPlatformExpert
OSDefineMetaClassAndStructors(Ios12TabletPlatform, IODTPlatformExpert);

/* Device-tree nodes IOKit should not publish as nubs (none for now). */
const char *
Ios12TabletPlatform::deleteList(void)
{
	return "";
}

const char *
Ios12TabletPlatform::excludeList(void)
{
	return "";
}

bool
Ios12TabletPlatform::start(IOService * provider)
{
	IOLog("ios12-tablet: platform driver starting for \"%s\"\n",
	    provider ? provider->getName() : "?");

	/* IOPlatformExpert::start -> IOPMrootDomain::start -> uuid_generate
	 * needs read_random(), which needs a registered PRNG backend. */
	ios12_prng_register();
	IOLog("ios12-tablet: kernel random number generator registered\n");

	if (!super::start(provider)) {
		IOLog("ios12-tablet: IODTPlatformExpert::start failed\n");
		return false;
	}

	registerService();
	IOLog("ios12-tablet: platform driver registered\n");

	uint32_t hb = 0;
	if (PE_parse_boot_argn("ios12hb", &hb, sizeof(hb)) && hb) {
		if (IOCreateThread(ios12_heartbeat, NULL) != NULL) {
			IOLog("ios12-tablet: heartbeat thread started\n");
		}
	}
	return true;
}
