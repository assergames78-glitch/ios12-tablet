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

	if (!super::start(provider)) {
		IOLog("ios12-tablet: IODTPlatformExpert::start failed\n");
		return false;
	}

	registerService();
	IOLog("ios12-tablet: platform driver registered\n");
	return true;
}
