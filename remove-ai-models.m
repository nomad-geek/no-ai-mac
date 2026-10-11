// remove-ai-models.m
//
// Shows how much disk space Apple Intelligence models use and, with --remove,
// asks Apple's own asset service to release them. Touches nothing else: no
// profile, no settings, no files under /System (SIP stays on).
//
// Build:   clang -fobjc-arc -framework Foundation remove-ai-models.m -o remove-ai-models
// Check:   ./remove-ai-models
// Remove:  ./remove-ai-models --remove
//
// Keep your profile's DownloadServerBaseURLOverride entries installed, or macOS
// downloads the models again.
//
// The asset service calls follow RemoveMacAI (github.com/omlahore/RemoveMacAI,
// MIT) and pared (github.com/4evy/pared, MIT), which mapped them for macOS 27.
// These are private interfaces: a macOS update can change them, and the tool
// refuses to act on any model set whose asset type no longer matches.

#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <objc/runtime.h>

static NSString *const kFramework =
    @"/System/Library/PrivateFrameworks/UnifiedAssetFramework.framework/UnifiedAssetFramework";
static NSString *const kService = @"com.apple.siri.uaf.subscription.service";

@interface NSObject (UAFPrivate)
+ (id)defaultManager;
+ (NSXPCInterface *)defaultInterface;
+ (id)generateInformationWithError:(NSError **)error;
- (id)getAssetSet:(NSString *)name;
- (NSString *)autoAssetType;
- (oneway void)operationWithConfig:(NSDictionary *)configuration
                        completion:(void (^)(NSError *_Nullable))completion;
@end

static void Out(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
static void Out(NSString *format, ...) {
  va_list args;
  va_start(args, format);
  NSString *s = [[NSString alloc] initWithFormat:format arguments:args];
  va_end(args);
  fputs(s.UTF8String, stdout);
  fputc('\n', stdout);
}

static NSString *Pad(NSString *s) {
  return [s stringByPaddingToLength:MAX(s.length, 40) withString:@" " startingAtIndex:0];
}

static NSString *FormatBytes(int64_t bytes) {
  return [NSByteCountFormatter stringFromByteCount:bytes
                                        countStyle:NSByteCountFormatterCountStyleFile];
}

// The five model sets: the name the asset service knows them by, and the asset
// type it must report before we touch it.
static NSArray<NSDictionary<NSString *, NSString *> *> *ModelSets(void) {
  return @[
    @{@"name" : @"com.apple.modelcatalog",
      @"type" : @"com.apple.MobileAsset.UAF.FM.GenerativeModels",
      @"title" : @"Apple Intelligence foundation models"},
    @{@"name" : @"com.apple.MobileAsset.UAF.FM.Visual",
      @"type" : @"com.apple.MobileAsset.UAF.FM.Visual",
      @"title" : @"Image Playground and Genmoji models"},
    @{@"name" : @"com.apple.MobileAsset.UAF.FM.CodeLM",
      @"type" : @"com.apple.MobileAsset.UAF.FM.CodeLM",
      @"title" : @"Xcode code completion models"},
    @{@"name" : @"com.apple.MobileAsset.UAF.Photos.MagicCleanup",
      @"type" : @"com.apple.MobileAsset.UAF.Photos.MagicCleanup",
      @"title" : @"Photos Clean Up models"},
    @{@"name" : @"com.apple.MobileAsset.UAF.Photos.SpatialPhotosRelive",
      @"type" : @"com.apple.MobileAsset.UAF.Photos.SpatialPhotosRelive",
      @"title" : @"Spatial Photos models"},
  ];
}

// The asset type the service reports for a set, or nil if it doesn't know it.
static NSString *AssetType(NSString *set) {
  Class manager = NSClassFromString(@"UAFConfigurationManager");
  if (![manager respondsToSelector:@selector(defaultManager)]) return nil;
  id m = [manager defaultManager];
  if (![m respondsToSelector:@selector(getAssetSet:)]) return nil;
  id s = [m getAssetSet:set];
  if (![s respondsToSelector:@selector(autoAssetType)]) return nil;
  id type = [s autoAssetType];
  return [type isKindOfClass:NSString.class] ? type : nil;
}

// Bytes on disk per asset type, from the service's inventory. nil if unavailable.
static NSDictionary<NSString *, NSNumber *> *Inventory(void) {
  Class manager = NSClassFromString(@"UAFAssetSetManager");
  if (![manager respondsToSelector:@selector(generateInformationWithError:)]) return nil;
  NSError *error = nil;
  id info = [manager generateInformationWithError:&error];
  if ([info isKindOfClass:NSString.class]) {
    info = [NSJSONSerialization JSONObjectWithData:[info dataUsingEncoding:NSUTF8StringEncoding]
                                           options:0
                                             error:&error];
  }
  if (![info isKindOfClass:NSDictionary.class]) return nil;
  NSMutableDictionary<NSString *, NSNumber *> *bytes = [NSMutableDictionary dictionary];
  id assets = info[@"SystemAssets"];
  if (![assets isKindOfClass:NSArray.class]) return bytes;
  for (id asset in assets) {
    if (![asset isKindOfClass:NSDictionary.class]) continue;
    if (![asset[@"isPresentOnDevice"] isEqual:@YES]) continue;
    NSDictionary *meta = asset[@"metadata"];
    if (![meta isKindOfClass:NSDictionary.class]) continue;
    NSString *type = meta[@"AssetType"];
    if (![type isKindOfClass:NSString.class]) continue;
    id size = meta[@"com.apple.UnifiedAssetFramework.UnarchivedSize"] ?: meta[@"_UnarchivedSize"];
    int64_t n = [[NSString stringWithFormat:@"%@", size ?: @0] longLongValue];
    bytes[type] = @(bytes[type].longLongValue + n);
  }
  return bytes;
}

// Asks the asset service to release one set. Returns nil on success.
static NSError *Reset(NSString *set, NSTimeInterval timeout) {
  Class interfaceClass = NSClassFromString(@"UAFXPCProxyServiceInterface");
  if (![interfaceClass respondsToSelector:@selector(defaultInterface)]) {
    return [NSError errorWithDomain:@"remove-ai-models" code:1
                           userInfo:@{NSLocalizedDescriptionKey : @"asset service interface unavailable"}];
  }
  NSXPCConnection *connection = [[NSXPCConnection alloc] initWithMachServiceName:kService options:0];
  connection.remoteObjectInterface = [interfaceClass defaultInterface];

  // An XPC proxy answers every selector, so check the protocol instead.
  SEL operation = @selector(operationWithConfig:completion:);
  Protocol *protocol = connection.remoteObjectInterface.protocol;
  if (protocol_getMethodDescription(protocol, operation, YES, YES).name == NULL &&
      protocol_getMethodDescription(protocol, operation, NO, YES).name == NULL) {
    return [NSError errorWithDomain:@"remove-ai-models" code:2
                           userInfo:@{NSLocalizedDescriptionKey : @"asset service does not accept operations"}];
  }
  [connection resume];

  dispatch_semaphore_t done = dispatch_semaphore_create(0);
  __block NSError *result = nil;
  id proxy = [connection remoteObjectProxyWithErrorHandler:^(NSError *e) {
    result = e;
    dispatch_semaphore_signal(done);
  }];
  [proxy operationWithConfig:@{@"Operation" : @"ResetAssetSets", @"AssetSets" : @[ set ]}
                  completion:^(NSError *e) {
                    result = e;
                    dispatch_semaphore_signal(done);
                  }];
  long timedOut = dispatch_semaphore_wait(
      done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)));
  [connection invalidate];
  if (timedOut) {
    return [NSError errorWithDomain:@"remove-ai-models" code:3
                           userInfo:@{NSLocalizedDescriptionKey : @"no answer from the asset service"}];
  }
  return result;
}

int main(int argc, const char *argv[]) {
  @autoreleasepool {
    BOOL remove = argc == 2 && strcmp(argv[1], "--remove") == 0;
    if (argc > 2 || (argc == 2 && !remove)) {
      Out(@"usage: remove-ai-models [--remove]");
      return 2;
    }
    if (!dlopen(kFramework.fileSystemRepresentation, RTLD_NOW)) {
      Out(@"Could not load Apple's asset framework. This needs macOS 27 on Apple silicon.");
      return 1;
    }

    NSDictionary<NSString *, NSNumber *> *before = Inventory();
    if (!before) Out(@"Note: the asset service did not report sizes; sizes show as unknown.\n");

    NSMutableArray<NSString *> *targets = [NSMutableArray array];
    int64_t total = 0;
    for (NSDictionary<NSString *, NSString *> *set in ModelSets()) {
      NSString *type = AssetType(set[@"name"]);
      if (![type isEqualToString:set[@"type"]]) {
        Out(@"  –  %@ skipped: %@", Pad(set[@"title"]),
            type ? [NSString stringWithFormat:@"asset type is now %@", type]
                 : @"not known to this macOS");
        continue;
      }
      if (!before) {
        Out(@"  ?  %@ size unknown", Pad(set[@"title"]));
        [targets addObject:set[@"name"]];
        continue;
      }
      int64_t bytes = before[type].longLongValue;
      total += bytes;
      Out(@"  %@  %@ %@", bytes > 0 ? @"•" : @" ", Pad(set[@"title"]),
          bytes > 0 ? FormatBytes(bytes) : @"not on disk");
      if (bytes > 0) [targets addObject:set[@"name"]];
    }
    if (before) Out(@"\n  Total: %@", FormatBytes(total));

    if (!remove) {
      if (targets.count) Out(@"\nRun with --remove to release these models.");
      return 0;
    }
    if (targets.count == 0) {
      Out(@"\nNothing to remove.");
      return 0;
    }

    Out(@"");
    int failures = 0;
    for (NSString *name in targets) {
      NSError *error = Reset(name, 120);
      if (error) {
        failures++;
        Out(@"  ✗  %@: %@", name, error.localizedDescription);
      } else {
        Out(@"  ✓  %@ released", name);
      }
    }

    NSDictionary<NSString *, NSNumber *> *after = Inventory();
    if (before && after) {
      int64_t left = 0;
      for (NSDictionary<NSString *, NSString *> *set in ModelSets())
        left += after[set[@"type"]].longLongValue;
      Out(@"\n  Before: %@   After: %@", FormatBytes(total), FormatBytes(left));
    }
    Out(@"\nmacOS deletes released files on its own schedule, so free space can take a"
        @" little while to catch up. Storage in System Settings lags further behind.");
    return failures ? 1 : 0;
  }
}
