#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <substrate.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach-o/nlist.h>
#import <dlfcn.h>
#include <stdint.h>
#include <string.h>

static NSString *const kH3kbPurchaseStateDefaultsKey = @"com.ihsiao.apps.Hamster3.purchase.state";

static const uintptr_t kMachOBaseAddress = 0x100000000ULL;
static const uintptr_t kPurchasedStateOffsetFallback = 0x98;
static const uintptr_t kInteractionsStoreOffsetFallback = 0x58;
// purchaseIDs is the in-instance Array<String> that matches ownedConsumables' return type.
static const uintptr_t kPurchaseIDsOffsetFallback = 0xB8;

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
    const char *symbolName;
    uintptr_t fallbackOffset;
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
#define H3KB_HOOK(name, symbolName, offset, signature, replacement) \
    { name, symbolName, offset, signature, sizeof(signature), (void *)(replacement), NULL, NO }

typedef struct {
    const struct mach_header_64 *header;
    intptr_t slide;
} H3kbLoadedImage;

static BOOL gDidEnsurePersistedUnlockState = NO;
static void *gH3kbSwiftBridgeObjectRetain = NULL;
static uintptr_t gPurchasedStateOffset = kPurchasedStateOffsetFallback;
static uintptr_t gInteractionsStoreOffset = kInteractionsStoreOffsetFallback;
static uintptr_t gPurchaseIDsOffset = kPurchaseIDsOffsetFallback;

static void H3kbEnsurePersistedUnlockedStateIfNeeded(void);
static BOOL H3kbPersistedStateLoadReplacement(void);
static BOOL H3kbStorePurchasedStateGetterReplacement(void *self);
static void H3kbStorePurchasedStateSetterReplacement(void *self, BOOL value);
static void *H3kbStoreOwnedConsumablesGetterReplacement(void *self);
static BOOL H3kbInteractionsPurchasedStateGetterReplacement(void *self);
static void H3kbResolveRuntimeLayout(void);

static const char *const kInAppPurchaseStoreClassName = "_TtC10HamsterKit18InAppPurchaseStore";
static const char *const kReduxInAppPurchaseUserInteractionsClassName =
    "_TtC10HamsterKit34ReduxInAppPurchaseUserInteractions";

static const char *const kPersistedStateLoadSymbolName =
    "_$s10HamsterKit18InAppPurchaseStoreC14purchasedStateSbvpfi_0";
static const char *const kStorePurchasedStateGetterSymbolName =
    "_$s10HamsterKit18InAppPurchaseStoreC14purchasedStateSbvg";
static const char *const kStoreOwnedConsumablesGetterSymbolName =
    "_$s10HamsterKit18InAppPurchaseStoreC16ownedConsumablesSaySSGvg";
static const char *const kInteractionsPurchasedStateGetterSymbolName =
    "_$s10HamsterKit34ReduxInAppPurchaseUserInteractionsC14purchasedStateSbvg";

static H3kbFunctionHook gAppHooks[] = {
    H3KB_HOOK("persistedState.load",
              kPersistedStateLoadSymbolName,
              0x31497c,
              kPersistedStateLoadSignature,
              &H3kbPersistedStateLoadReplacement),
    H3KB_HOOK("store.purchasedState.getter",
              kStorePurchasedStateGetterSymbolName,
              0x314aa8,
              kStorePurchasedStateGetterSignature,
              &H3kbStorePurchasedStateGetterReplacement),
    H3KB_HOOK("store.purchasedState.setter",
              NULL,
              0x314ad8,
              kStorePurchasedStateSetterSignature,
              &H3kbStorePurchasedStateSetterReplacement),
    H3KB_HOOK("store.ownedConsumables.getter",
              kStoreOwnedConsumablesGetterSymbolName,
              0x314b80,
              kStoreOwnedConsumablesGetterSignature,
              &H3kbStoreOwnedConsumablesGetterReplacement),
    H3KB_HOOK("interactions.purchasedState.getter",
              kInteractionsPurchasedStateGetterSymbolName,
              0x31f090,
              kInteractionsPurchasedStateGetterSignature,
              &H3kbInteractionsPurchasedStateGetterReplacement),
};

static H3kbFunctionHook gPluginHooks[] = {
    H3KB_HOOK("persistedState.load",
              kPersistedStateLoadSymbolName,
              0x25af28,
              kPersistedStateLoadSignature,
              &H3kbPersistedStateLoadReplacement),
    H3KB_HOOK("store.purchasedState.getter",
              kStorePurchasedStateGetterSymbolName,
              0x25b054,
              kStorePurchasedStateGetterSignature,
              &H3kbStorePurchasedStateGetterReplacement),
    H3KB_HOOK("store.purchasedState.setter",
              NULL,
              0x25b084,
              kStorePurchasedStateSetterSignature,
              &H3kbStorePurchasedStateSetterReplacement),
    H3KB_HOOK("store.ownedConsumables.getter",
              kStoreOwnedConsumablesGetterSymbolName,
              0x25b12c,
              kStoreOwnedConsumablesGetterSignature,
              &H3kbStoreOwnedConsumablesGetterReplacement),
    H3KB_HOOK("interactions.purchasedState.getter",
              kInteractionsPurchasedStateGetterSymbolName,
              0x26567c,
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

    *(BOOL *)((uint8_t *)store + gPurchasedStateOffset) = YES;
}

static inline void *H3kbCurrentSwiftSelfFromX20(void) {
    void *selfObject = NULL;
    __asm__("mov %0, x20" : "=r"(selfObject));
    return selfObject;
}

static BOOL H3kbFindLoadedImage(const char *suffix, H3kbLoadedImage *imageOut) {
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
            const struct mach_header *header = _dyld_get_image_header(i);
            if (!header || header->magic != MH_MAGIC_64) {
                return NO;
            }

            if (imageOut) {
                imageOut->header = (const struct mach_header_64 *)header;
                imageOut->slide = _dyld_get_image_vmaddr_slide(i);
            }
            return YES;
        }
    }

    return NO;
}

static const struct segment_command_64 *H3kbFindSegment64(const struct mach_header_64 *header,
                                                          const char *segmentName) {
    if (!header || !segmentName) {
        return NULL;
    }

    const struct load_command *loadCommand =
        (const struct load_command *)((const uint8_t *)header + sizeof(struct mach_header_64));
    for (uint32_t i = 0; i < header->ncmds; i++) {
        if (loadCommand->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *segment = (const struct segment_command_64 *)loadCommand;
            if (strcmp(segment->segname, segmentName) == 0) {
                return segment;
            }
        }
        loadCommand = (const struct load_command *)((const uint8_t *)loadCommand + loadCommand->cmdsize);
    }

    return NULL;
}

static void *H3kbResolveSymbolInImage(const H3kbLoadedImage *image, const char *symbolName) {
    if (!image || !image->header || !symbolName) {
        return NULL;
    }

    const struct symtab_command *symtabCommand = NULL;
    const struct segment_command_64 *linkeditSegment = NULL;
    const struct load_command *loadCommand =
        (const struct load_command *)((const uint8_t *)image->header + sizeof(struct mach_header_64));
    for (uint32_t i = 0; i < image->header->ncmds; i++) {
        if (loadCommand->cmd == LC_SYMTAB) {
            symtabCommand = (const struct symtab_command *)loadCommand;
        } else if (loadCommand->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *segment = (const struct segment_command_64 *)loadCommand;
            if (strcmp(segment->segname, SEG_LINKEDIT) == 0) {
                linkeditSegment = segment;
            }
        }
        loadCommand = (const struct load_command *)((const uint8_t *)loadCommand + loadCommand->cmdsize);
    }

    if (!symtabCommand || !linkeditSegment) {
        return NULL;
    }

    uintptr_t linkeditBase = (uintptr_t)(image->slide + linkeditSegment->vmaddr - linkeditSegment->fileoff);
    const struct nlist_64 *symbols = (const struct nlist_64 *)(linkeditBase + symtabCommand->symoff);
    const char *stringTable = (const char *)(linkeditBase + symtabCommand->stroff);
    for (uint32_t i = 0; i < symtabCommand->nsyms; i++) {
        uint32_t stringIndex = symbols[i].n_un.n_strx;
        if (!stringIndex) {
            continue;
        }

        const char *currentName = stringTable + stringIndex;
        if (strcmp(currentName, symbolName) == 0) {
            return (void *)(symbols[i].n_value + image->slide);
        }
    }

    return NULL;
}

static void *H3kbResolveImageAddress(const H3kbLoadedImage *image, uintptr_t offset) {
    if (!image || !image->header) {
        return NULL;
    }

    return (void *)(kMachOBaseAddress + offset + image->slide);
}

static BOOL H3kbAddressMatchesSignature(void *address, const uint8_t *signature, size_t signatureLength) {
    if (!address || !signature || signatureLength == 0) {
        return NO;
    }

    return memcmp(address, signature, signatureLength) == 0;
}

static void *H3kbFindUniqueSignatureInText(const H3kbLoadedImage *image,
                                           const uint8_t *signature,
                                           size_t signatureLength) {
    if (!image || !image->header || !signature || signatureLength == 0) {
        return NULL;
    }

    const struct segment_command_64 *textSegment = H3kbFindSegment64(image->header, SEG_TEXT);
    if (!textSegment) {
        return NULL;
    }

    const struct section_64 *section = (const struct section_64 *)(textSegment + 1);
    void *match = NULL;
    size_t matchCount = 0;
    for (uint32_t i = 0; i < textSegment->nsects; i++, section++) {
        if (strcmp(section->sectname, "__text") != 0) {
            continue;
        }

        const uint8_t *start = (const uint8_t *)(section->addr + image->slide);
        size_t size = (size_t)section->size;
        if (size < signatureLength) {
            continue;
        }

        for (size_t offset = 0; offset + signatureLength <= size; offset++) {
            if (memcmp(start + offset, signature, signatureLength) == 0) {
                match = (void *)(start + offset);
                matchCount++;
                if (matchCount > 1) {
                    return NULL;
                }
            }
        }
    }

    return matchCount == 1 ? match : NULL;
}

static uintptr_t H3kbResolveIvarOffset(const char *className,
                                       const char *ivarName,
                                       uintptr_t fallbackOffset) {
    if (!className || !ivarName) {
        return fallbackOffset;
    }

    Class classObject = objc_getClass(className);
    if (!classObject) {
        return fallbackOffset;
    }

    Ivar ivar = class_getInstanceVariable(classObject, ivarName);
    if (!ivar) {
        return fallbackOffset;
    }

    ptrdiff_t offset = ivar_getOffset(ivar);
    return offset >= 0 ? (uintptr_t)offset : fallbackOffset;
}

static void H3kbResolveRuntimeLayout(void) {
    gPurchasedStateOffset =
        H3kbResolveIvarOffset(kInAppPurchaseStoreClassName, "purchasedState", kPurchasedStateOffsetFallback);
    gPurchaseIDsOffset =
        H3kbResolveIvarOffset(kInAppPurchaseStoreClassName, "purchaseIDs", kPurchaseIDsOffsetFallback);
    gInteractionsStoreOffset = H3kbResolveIvarOffset(kReduxInAppPurchaseUserInteractionsClassName,
                                                     "inAppPurchaseStore",
                                                     kInteractionsStoreOffsetFallback);
}

static void *H3kbResolveHookAddress(const H3kbLoadedImage *image, const H3kbFunctionHook *hook) {
    if (!image || !hook) {
        return NULL;
    }

    if (hook->symbolName) {
        void *symbolAddress = H3kbResolveSymbolInImage(image, hook->symbolName);
        if (symbolAddress) {
            return symbolAddress;
        }
    }

    if (hook->fallbackOffset) {
        void *fallbackAddress = H3kbResolveImageAddress(image, hook->fallbackOffset);
        if (H3kbAddressMatchesSignature(fallbackAddress, hook->signature, hook->signatureLength)) {
            return fallbackAddress;
        }
    }

    return H3kbFindUniqueSignatureInText(image, hook->signature, hook->signatureLength);
}

static void H3kbInstallHooksForPlan(H3kbHookPlan *plan) {
    if (!plan) {
        return;
    }

    H3kbLoadedImage image = {0};
    if (!H3kbFindLoadedImage(plan->imageSuffix, &image)) {
        return;
    }

    for (size_t i = 0; i < plan->hookCount; i++) {
        H3kbFunctionHook *hook = &plan->hooks[i];
        void *address = H3kbResolveHookAddress(&image, hook);
        if (!address) {
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

    void *purchaseIDs = *(void **)((uint8_t *)store + gPurchaseIDsOffset);
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
        void *store = *(void **)((uint8_t *)interactions + gInteractionsStoreOffset);
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
        H3kbResolveRuntimeLayout();

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
