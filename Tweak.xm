#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <substrate.h>
#import <mach-o/dyld.h>
#import <dlfcn.h>
#include <stdint.h>
#include <string.h>

static NSString *const kH3kbPurchaseStateDefaultsKey = @"com.ihsiao.apps.Hamster3.purchase.state";

static const uintptr_t kMachOBaseAddress = 0x100000000ULL;
static const uintptr_t kPurchasedStateOffset = 0x98;
static const uintptr_t kInteractionsStoreOffset = 0x58;
static const uintptr_t kPurchaseIDsOffset = 0xB8;

static const uint8_t kPersistedStateLoadSignature[] = {
    0xff, 0x83, 0x01, 0xd1, 0xf8, 0x5f, 0x02, 0xa9,
    0xf6, 0x57, 0x03, 0xa9, 0xf4, 0x4f, 0x04, 0xa9,
};

static const uint8_t kStorePurchasedStateGetterSignature[] = {
    0xff, 0xc3, 0x00, 0xd1, 0xfd, 0x7b, 0x02, 0xa9,
    0xfd, 0x83, 0x00, 0x91, 0x80, 0x62, 0x02, 0x91,
};

static const uint8_t kStorePurchasedStateSetterSignature[] = {
    0xff, 0x43, 0x01, 0xd1, 0xf6, 0x57, 0x02, 0xa9,
    0xf4, 0x4f, 0x03, 0xa9, 0xfd, 0x7b, 0x04, 0xa9,
};

static const uint8_t kStoreOwnedConsumablesGetterSignature[] = {
    0xff, 0x43, 0x02, 0xd1, 0xf6, 0x57, 0x06, 0xa9,
    0xf4, 0x4f, 0x07, 0xa9, 0xfd, 0x7b, 0x08, 0xa9,
};

static const uint8_t kInteractionsPurchasedStateGetterSignature[] = {
    0xff, 0x03, 0x01, 0xd1, 0xf4, 0x4f, 0x02, 0xa9,
    0xfd, 0x7b, 0x03, 0xa9, 0xfd, 0xc3, 0x00, 0x91,
};

typedef struct {
    const char *name;
    uintptr_t offset;
    const uint8_t *signature;
    size_t signatureLength;
    void *replacement;
    void **original;
    BOOL installed;
} H3kbFunctionHook;

typedef struct {
    const char *bundleIdentifier;
    const char *imageSuffix;
    H3kbFunctionHook *hooks;
    size_t hookCount;
} H3kbHookPlan;

#define H3KB_ARRAY_COUNT(array) (sizeof(array) / sizeof((array)[0]))
#define H3KB_HOOK(name, offset, signature, replacement) \
    { name, offset, signature, sizeof(signature), (void *)(replacement), NULL, NO }

static BOOL gDidEnsurePersistedUnlockState = NO;
static void *gH3kbSwiftBridgeObjectRetain = NULL;

static void H3kbEnsurePersistedUnlockedStateIfNeeded(void);
static BOOL H3kbPersistedStateLoadReplacement(void);
static BOOL H3kbStorePurchasedStateGetterReplacement(void *self);
static void H3kbStorePurchasedStateSetterReplacement(void *self, BOOL value);
static void *H3kbStoreOwnedConsumablesGetterReplacement(void *self);
static BOOL H3kbInteractionsPurchasedStateGetterReplacement(void *self);

static H3kbFunctionHook gAppHooks[] = {
    H3KB_HOOK("persistedState.load",
              0x314988,
              kPersistedStateLoadSignature,
              &H3kbPersistedStateLoadReplacement),
    H3KB_HOOK("store.purchasedState.getter",
              0x314ab4,
              kStorePurchasedStateGetterSignature,
              &H3kbStorePurchasedStateGetterReplacement),
    H3KB_HOOK("store.purchasedState.setter",
              0x314ae4,
              kStorePurchasedStateSetterSignature,
              &H3kbStorePurchasedStateSetterReplacement),
    H3KB_HOOK("store.ownedConsumables.getter",
              0x314b8c,
              kStoreOwnedConsumablesGetterSignature,
              &H3kbStoreOwnedConsumablesGetterReplacement),
    H3KB_HOOK("interactions.purchasedState.getter",
              0x31f09c,
              kInteractionsPurchasedStateGetterSignature,
              &H3kbInteractionsPurchasedStateGetterReplacement),
};

static H3kbFunctionHook gPluginHooks[] = {
    H3KB_HOOK("persistedState.load",
              0x25af34,
              kPersistedStateLoadSignature,
              &H3kbPersistedStateLoadReplacement),
    H3KB_HOOK("store.purchasedState.getter",
              0x25b060,
              kStorePurchasedStateGetterSignature,
              &H3kbStorePurchasedStateGetterReplacement),
    H3KB_HOOK("store.purchasedState.setter",
              0x25b090,
              kStorePurchasedStateSetterSignature,
              &H3kbStorePurchasedStateSetterReplacement),
    H3KB_HOOK("store.ownedConsumables.getter",
              0x25b138,
              kStoreOwnedConsumablesGetterSignature,
              &H3kbStoreOwnedConsumablesGetterReplacement),
    H3KB_HOOK("interactions.purchasedState.getter",
              0x265688,
              kInteractionsPurchasedStateGetterSignature,
              &H3kbInteractionsPurchasedStateGetterReplacement),
};

static H3kbHookPlan gHookPlans[] = {
    {
        "com.ihsiao.apps.Hamster3",
        "/h3kb",
        gAppHooks,
        H3KB_ARRAY_COUNT(gAppHooks),
    },
    {
        "com.ihsiao.apps.Hamster3.Keyboard",
        "/h3kb_plugin",
        gPluginHooks,
        H3KB_ARRAY_COUNT(gPluginHooks),
    },
};

static BOOL H3kbShouldForceDefaultsKey(NSString *defaultName) {
    return [defaultName isEqualToString:kH3kbPurchaseStateDefaultsKey];
}

static void H3kbEnsurePersistedUnlockedStateIfNeeded(void) {
    if (gDidEnsurePersistedUnlockState) {
        return;
    }

    BOOL alreadyUnlocked = NO;
    CFPropertyListRef value = CFPreferencesCopyAppValue((CFStringRef)kH3kbPurchaseStateDefaultsKey,
                                                        kCFPreferencesCurrentApplication);
    if (value) {
        CFTypeID valueType = CFGetTypeID(value);
        if (valueType == CFBooleanGetTypeID()) {
            alreadyUnlocked = CFBooleanGetValue((CFBooleanRef)value);
        } else if (valueType == CFNumberGetTypeID()) {
            int numericValue = 0;
            if (CFNumberGetValue((CFNumberRef)value, kCFNumberIntType, &numericValue)) {
                alreadyUnlocked = numericValue != 0;
            }
        }
        CFRelease(value);
    }

    if (!alreadyUnlocked) {
        CFPreferencesSetAppValue((CFStringRef)kH3kbPurchaseStateDefaultsKey,
                                 kCFBooleanTrue,
                                 kCFPreferencesCurrentApplication);
        CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication);
    }

    gDidEnsurePersistedUnlockState = YES;
}

static void H3kbWritePurchasedState(void *store) {
    if (!store) {
        return;
    }

    *(BOOL *)((uint8_t *)store + kPurchasedStateOffset) = YES;
}

static inline void *H3kbCurrentSwiftSelfFromX20(void) {
    void *selfObject = NULL;
    __asm__("mov %0, x20" : "=r"(selfObject));
    return selfObject;
}

static BOOL H3kbFindImageSlide(const char *suffix, intptr_t *slideOut) {
    uint32_t imageCount = _dyld_image_count();
    for (uint32_t i = 0; i < imageCount; i++) {
        const char *imageName = _dyld_get_image_name(i);
        if (!imageName) {
            continue;
        }

        size_t imageNameLength = strlen(imageName);
        size_t suffixLength = strlen(suffix);
        if (imageNameLength < suffixLength) {
            continue;
        }

        if (strcmp(imageName + imageNameLength - suffixLength, suffix) == 0) {
            if (slideOut) {
                *slideOut = _dyld_get_image_vmaddr_slide(i);
            }
            return YES;
        }
    }

    return NO;
}

static void *H3kbResolveImageAddress(const char *imageSuffix, uintptr_t offset) {
    intptr_t slide = 0;
    if (!H3kbFindImageSlide(imageSuffix, &slide)) {
        return NULL;
    }

    return (void *)(kMachOBaseAddress + offset + slide);
}

static BOOL H3kbAddressMatchesSignature(void *address, const uint8_t *signature, size_t signatureLength) {
    if (!address || !signature || signatureLength == 0) {
        return NO;
    }

    return memcmp(address, signature, signatureLength) == 0;
}

static void H3kbInstallHooksForPlan(H3kbHookPlan *plan) {
    if (!plan) {
        return;
    }

    for (size_t i = 0; i < plan->hookCount; i++) {
        H3kbFunctionHook *hook = &plan->hooks[i];
        void *address = H3kbResolveImageAddress(plan->imageSuffix, hook->offset);
        if (!H3kbAddressMatchesSignature(address, hook->signature, hook->signatureLength)) {
            hook->installed = NO;
            continue;
        }

        MSHookFunction(address, hook->replacement, hook->original);
        hook->installed = YES;
    }
}

static BOOL H3kbPersistedStateLoadReplacement(void) {
    H3kbEnsurePersistedUnlockedStateIfNeeded();
    return YES;
}

static BOOL H3kbStorePurchasedStateGetterReplacement(void *self) {
    (void)self;
    H3kbWritePurchasedState(H3kbCurrentSwiftSelfFromX20());
    return YES;
}

static void H3kbStorePurchasedStateSetterReplacement(void *self, BOOL value) {
    (void)self;
    (void)value;
    H3kbWritePurchasedState(H3kbCurrentSwiftSelfFromX20());
}

static void *H3kbStoreOwnedConsumablesGetterReplacement(void *self) {
    (void)self;

    void *store = H3kbCurrentSwiftSelfFromX20();
    H3kbWritePurchasedState(store);
    if (!store) {
        return NULL;
    }

    void *purchaseIDs = *(void **)((uint8_t *)store + kPurchaseIDsOffset);
    if (!purchaseIDs) {
        return NULL;
    }

    if (gH3kbSwiftBridgeObjectRetain) {
        typedef void *(*H3kbSwiftBridgeObjectRetainFn)(void *);
        H3kbSwiftBridgeObjectRetainFn bridgeRetain =
            (H3kbSwiftBridgeObjectRetainFn)gH3kbSwiftBridgeObjectRetain;
        return bridgeRetain(purchaseIDs);
    }

    return purchaseIDs;
}

static BOOL H3kbInteractionsPurchasedStateGetterReplacement(void *self) {
    (void)self;

    void *interactions = H3kbCurrentSwiftSelfFromX20();
    if (interactions) {
        void *store = *(void **)((uint8_t *)interactions + kInteractionsStoreOffset);
        H3kbWritePurchasedState(store);
    }

    return YES;
}

%hook NSUserDefaults

- (BOOL)boolForKey:(NSString *)defaultName {
    if (H3kbShouldForceDefaultsKey(defaultName)) {
        return YES;
    }

    return %orig(defaultName);
}

- (id)objectForKey:(NSString *)defaultName {
    if (H3kbShouldForceDefaultsKey(defaultName)) {
        return @(YES);
    }

    return %orig(defaultName);
}

- (void)setBool:(BOOL)value forKey:(NSString *)defaultName {
    if (H3kbShouldForceDefaultsKey(defaultName)) {
        %orig(YES, defaultName);
        return;
    }

    %orig(value, defaultName);
}

- (void)setObject:(id)value forKey:(NSString *)defaultName {
    if (H3kbShouldForceDefaultsKey(defaultName)) {
        %orig(@(YES), defaultName);
        return;
    }

    %orig(value, defaultName);
}

%end

%ctor {
    @autoreleasepool {
        H3kbEnsurePersistedUnlockedStateIfNeeded();
        gH3kbSwiftBridgeObjectRetain = dlsym(RTLD_DEFAULT, "_swift_bridgeObjectRetain");

        NSString *bundleIdentifier = [NSBundle mainBundle].bundleIdentifier ?: @"";
        for (size_t i = 0; i < H3KB_ARRAY_COUNT(gHookPlans); i++) {
            H3kbHookPlan *plan = &gHookPlans[i];
            NSString *planBundleIdentifier = [NSString stringWithUTF8String:plan->bundleIdentifier];
            if (planBundleIdentifier && [bundleIdentifier isEqualToString:planBundleIdentifier]) {
                H3kbInstallHooksForPlan(plan);
                break;
            }
        }
    }
}
