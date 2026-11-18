#import "StepTrackerProModule.h"

#import <React/RCTBridgeModule.h>
#import <UIKit/UIKit.h>
#import <atomic>

#if __has_include("react_native_step_tracker_pro_ios/react_native_step_tracker_pro_ios-Swift.h")
#import "react_native_step_tracker_pro_ios/react_native_step_tracker_pro_ios-Swift.h"
#else
#import "react_native_step_tracker_pro_ios-Swift.h"
#endif

/**
 * Apple Health wakes the app in the background only for observer queries
 * registered as launch finishes, so they are registered from here - at the
 * end of launch - rather than from JavaScript, which may never run on a
 * background launch. The app's AppDelegate needs no edit.
 * (RCT_EXPORT_MODULE owns +load, hence a constructor.)
 */
__attribute__((constructor)) static void StepTrackerProObserveLaunch(void)
{
  [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification
                                                    object:nil
                                                     queue:nil
                                                usingBlock:^(__unused NSNotification *note) {
                                                  [StepTrackerProBridge applicationDidFinishLaunching];
                                                }];
}

@implementation StepTrackerProModule {
  BOOL _listening;
  // The generated emitOn... methods call an event callback the runtime sets
  // after init; calling it before then throws. Events wait for it.
  std::atomic<bool> _canEmit;
}

RCT_EXPORT_MODULE(StepTrackerPro)

+ (BOOL)requiresMainQueueSetup
{
  return NO;
}

- (instancetype)init
{
  if (self = [super init]) {
    __weak StepTrackerProModule *weakSelf = self;
    [[StepTrackerProBridge shared] attachEmitter:^(NSString *name, NSDictionary *payload) {
      [weakSelf emit:name payload:payload];
    }];
  }
  return self;
}

- (void)setEventEmitterCallback:(EventEmitterCallbackWrapper *)eventEmitterCallbackWrapper
{
  [super setEventEmitterCallback:eventEmitterCallbackWrapper];
  _canEmit = true;
}

- (void)invalidate
{
  _canEmit = false;
  [[StepTrackerProBridge shared] detachEmitter];
}

- (std::shared_ptr<facebook::react::TurboModule>)getTurboModule:
    (const facebook::react::ObjCTurboModule::InitParams &)params
{
  return std::make_shared<facebook::react::NativeStepTrackerProSpecJSI>(params);
}

- (void)emit:(NSString *)name payload:(NSDictionary *)payload
{
  if (!_canEmit) return;
  // Typed emitters only exist once the runtime has handed the module its
  // event callback; before that there is nobody to hear an event anyway.
  if ([name isEqualToString:@"stepsChanged"]) [self emitOnStepsChanged:payload];
  else if ([name isEqualToString:@"goalReached"]) [self emitOnGoalReached:payload];
  else if ([name isEqualToString:@"goalProgressChanged"]) [self emitOnGoalProgressChanged:payload];
  else if ([name isEqualToString:@"trackingStateChanged"]) [self emitOnTrackingStateChanged:payload];
  else if ([name isEqualToString:@"dayChanged"]) [self emitOnDayChanged:payload];
  else if ([name isEqualToString:@"historyBackfilled"]) [self emitOnHistoryBackfilled:payload];
  else if ([name isEqualToString:@"motionWindow"]) [self emitOnMotionWindow:payload];
  else if ([name isEqualToString:@"suspiciousActivity"]) [self emitOnSuspiciousActivity:payload];
  else if ([name isEqualToString:@"syncCompleted"]) [self emitOnSyncCompleted:payload];
  else if ([name isEqualToString:@"syncAuthFailed"]) [self emitOnSyncAuthFailed:payload];
  else if ([name isEqualToString:@"stepSourceChanged"]) [self emitOnStepSourceChanged:payload];
  else if ([name isEqualToString:@"healthConnectStatusChanged"]) [self emitOnHealthConnectStatusChanged:payload];
  else if ([name isEqualToString:@"error"]) [self emitOnError:payload];
}

/** Every promise method lands here: Swift answers on its own queue. */
- (void)call:(NSString *)method
        args:(NSArray *)args
     resolve:(RCTPromiseResolveBlock)resolve
      reject:(RCTPromiseRejectBlock)reject
{
  [[StepTrackerProBridge shared] call:method
                                 args:args
                              resolve:^(id _Nullable value) {
                                resolve(value);
                              }
                               reject:^(NSString *code, NSString *message, NSDictionary *_Nullable details) {
                                 // React Native copies an NSError's userInfo onto the JS
                                 // error, where react-native-step-tracker-pro reads it as
                                 // `details`; with none, `userInfo` is null as on Android.
                                 NSError *error = details == nil
                                     ? nil
                                     : [NSError errorWithDomain:@"StepTrackerPro" code:0 userInfo:details];
                                 reject(code, message, error);
                               }];
}

// ---- event emitter plumbing ----------------------------------------------
// Typed emitters (emitOn...) carry every event on the new architecture; these
// exist because the spec declares them.

- (void)addListener:(NSString *)eventName
{
  _listening = YES;
}

- (void)removeListeners:(double)count
{
}

// ---- spec methods ----------------------------------------------------------

- (void)initialize:(NSDictionary *)config resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [self call:@"initialize" args:@[(config ?: (id)[NSNull null])] resolve:resolve reject:reject];
}

- (void)updateConfig:(NSDictionary *)config resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [self call:@"updateConfig" args:@[(config ?: (id)[NSNull null])] resolve:resolve reject:reject];
}

- (void)getConfig:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [self call:@"getConfig" args:@[] resolve:resolve reject:reject];
}

- (void)startTracking:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [self call:@"startTracking" args:@[] resolve:resolve reject:reject];
}

- (void)pauseTracking:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [self call:@"pauseTracking" args:@[] resolve:resolve reject:reject];
}

- (void)resumeTracking:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [self call:@"resumeTracking" args:@[] resolve:resolve reject:reject];
}

- (void)stopTracking:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [self call:@"stopTracking" args:@[] resolve:resolve reject:reject];
}

- (void)getTrackingState:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [self call:@"getTrackingState" args:@[] resolve:resolve reject:reject];
}

- (void)isTracking:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [self call:@"isTracking" args:@[] resolve:resolve reject:reject];
}

- (void)getTrackingHealth:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [self call:@"getTrackingHealth" args:@[] resolve:resolve reject:reject];
}

- (void)getTodaySteps:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [self call:@"getTodaySteps" args:@[] resolve:resolve reject:reject];
}

- (void)setOtherDevicesSteps:(NSString *)date steps:(double)steps resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [self call:@"setOtherDevicesSteps" args:@[(date ?: (id)[NSNull null]), @(steps)] resolve:resolve reject:reject];
}

- (void)setCountFrom:(double)at resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [self call:@"setCountFrom" args:@[@(at)] resolve:resolve reject:reject];
}

- (void)getStepsForDate:(NSString *)date resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [self call:@"getStepsForDate" args:@[(date ?: (id)[NSNull null])] resolve:resolve reject:reject];
}

- (void)getYesterdaySteps:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [self call:@"getYesterdaySteps" args:@[] resolve:resolve reject:reject];
}

- (void)getStatsForRange:(NSString *)startDate endDate:(NSString *)endDate resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [self call:@"getStatsForRange" args:@[(startDate ?: (id)[NSNull null]), (endDate ?: (id)[NSNull null])] resolve:resolve reject:reject];
}

- (void)getWeeklyStats:(NSDictionary *)options resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [self call:@"getWeeklyStats" args:@[(options ?: (id)[NSNull null])] resolve:resolve reject:reject];
}

- (void)getMonthlyStats:(NSDictionary *)options resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [self call:@"getMonthlyStats" args:@[(options ?: (id)[NSNull null])] resolve:resolve reject:reject];
}

- (void)getYearlyStats:(NSDictionary *)options resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [self call:@"getYearlyStats" args:@[(options ?: (id)[NSNull null])] resolve:resolve reject:reject];
}

- (void)getHistory:(NSString *)startDate endDate:(NSString *)endDate resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [self call:@"getHistory" args:@[(startDate ?: (id)[NSNull null]), (endDate ?: (id)[NSNull null])] resolve:resolve reject:reject];
}

- (void)getVerificationSnapshot:(NSString *)date options:(NSDictionary *)options resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [self call:@"getVerificationSnapshot" args:@[(date ?: (id)[NSNull null]), (options ?: (id)[NSNull null])] resolve:resolve reject:reject];
}

- (void)getMotionWindows:(NSString *)startDate endDate:(NSString *)endDate resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [self call:@"getMotionWindows" args:@[(startDate ?: (id)[NSNull null]), (endDate ?: (id)[NSNull null])] resolve:resolve reject:reject];
}

- (void)getIntegrityReport:(NSString *)date resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [self call:@"getIntegrityReport" args:@[(date ?: (id)[NSNull null])] resolve:resolve reject:reject];
}

- (void)getIntegrityEvents:(NSString *)startDate endDate:(NSString *)endDate resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [self call:@"getIntegrityEvents" args:@[(startDate ?: (id)[NSNull null]), (endDate ?: (id)[NSNull null])] resolve:resolve reject:reject];
}

- (void)getStepMinutes:(NSString *)startDate endDate:(NSString *)endDate resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [self call:@"getStepMinutes" args:@[(startDate ?: (id)[NSNull null]), (endDate ?: (id)[NSNull null])] resolve:resolve reject:reject];
}

- (void)attestDevice:(NSString *)challenge resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [self call:@"attestDevice" args:@[(challenge ?: (id)[NSNull null])] resolve:resolve reject:reject];
}

- (void)hasAttestationKey:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [self call:@"hasAttestationKey" args:@[] resolve:resolve reject:reject];
}

- (void)getAttestationKeyInfo:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [self call:@"getAttestationKeyInfo" args:@[] resolve:resolve reject:reject];
}

- (void)requestIntegrityToken:(NSDictionary *)options resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [self call:@"requestIntegrityToken" args:@[(options ?: (id)[NSNull null])] resolve:resolve reject:reject];
}

- (void)prepareIntegrity:(double)cloudProjectNumber resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [self call:@"prepareIntegrity" args:@[@(cloudProjectNumber)] resolve:resolve reject:reject];
}

- (void)resetToday:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [self call:@"resetToday" args:@[] resolve:resolve reject:reject];
}

- (void)clearHistory:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [self call:@"clearHistory" args:@[] resolve:resolve reject:reject];
}

- (void)pruneHistory:(double)retentionDays resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [self call:@"pruneHistory" args:@[@(retentionDays)] resolve:resolve reject:reject];
}

- (void)checkPermissions:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [self call:@"checkPermissions" args:@[] resolve:resolve reject:reject];
}

- (void)requestPermissions:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [self call:@"requestPermissions" args:@[] resolve:resolve reject:reject];
}

- (void)getDeviceCapabilities:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [self call:@"getDeviceCapabilities" args:@[] resolve:resolve reject:reject];
}

- (void)openAppSettings:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [self call:@"openAppSettings" args:@[] resolve:resolve reject:reject];
}

- (void)isBatteryOptimizationEnabled:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [self call:@"isBatteryOptimizationEnabled" args:@[] resolve:resolve reject:reject];
}

- (void)requestDisableBatteryOptimization:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [self call:@"requestDisableBatteryOptimization" args:@[] resolve:resolve reject:reject];
}

- (void)openBatteryOptimizationSettings:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [self call:@"openBatteryOptimizationSettings" args:@[] resolve:resolve reject:reject];
}

- (void)openManufacturerAutoStartSettings:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [self call:@"openManufacturerAutoStartSettings" args:@[] resolve:resolve reject:reject];
}

- (void)getBackgroundRestrictionStatus:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [self call:@"getBackgroundRestrictionStatus" args:@[] resolve:resolve reject:reject];
}

- (void)getHealthConnectStatus:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [self call:@"getHealthConnectStatus" args:@[] resolve:resolve reject:reject];
}

- (void)requestHealthConnectPermissions:(NSDictionary *)options resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [self call:@"requestHealthConnectPermissions" args:@[(options ?: (id)[NSNull null])] resolve:resolve reject:reject];
}

- (void)openHealthConnectSettings:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [self call:@"openHealthConnectSettings" args:@[] resolve:resolve reject:reject];
}

- (void)installHealthConnect:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [self call:@"installHealthConnect" args:@[] resolve:resolve reject:reject];
}

- (void)revokeHealthConnectPermissions:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [self call:@"revokeHealthConnectPermissions" args:@[] resolve:resolve reject:reject];
}

- (void)readHealthConnectSteps:(NSString *)startIso endIso:(NSString *)endIso resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [self call:@"readHealthConnectSteps" args:@[(startIso ?: (id)[NSNull null]), (endIso ?: (id)[NSNull null])] resolve:resolve reject:reject];
}

- (void)writeHealthConnectSteps:(NSString *)date resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [self call:@"writeHealthConnectSteps" args:@[(date ?: (id)[NSNull null])] resolve:resolve reject:reject];
}

- (void)syncWithHealthConnect:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [self call:@"syncWithHealthConnect" args:@[] resolve:resolve reject:reject];
}

- (void)getHealthConnectRecords:(NSString *)startIso endIso:(NSString *)endIso options:(NSDictionary *)options resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [self call:@"getHealthConnectRecords" args:@[(startIso ?: (id)[NSNull null]), (endIso ?: (id)[NSNull null]), (options ?: (id)[NSNull null])] resolve:resolve reject:reject];
}

- (void)getHealthConnectChangesToken:(NSDictionary *)options resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [self call:@"getHealthConnectChangesToken" args:@[(options ?: (id)[NSNull null])] resolve:resolve reject:reject];
}

- (void)getHealthConnectChanges:(NSString *)token resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [self call:@"getHealthConnectChanges" args:@[(token ?: (id)[NSNull null])] resolve:resolve reject:reject];
}

- (void)readHealthConnectVitals:(NSString *)startIso endIso:(NSString *)endIso options:(NSDictionary *)options resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [self call:@"readHealthConnectVitals" args:@[(startIso ?: (id)[NSNull null]), (endIso ?: (id)[NSNull null]), (options ?: (id)[NSNull null])] resolve:resolve reject:reject];
}

- (void)deleteHealthConnectData:(NSString *)startDate endDate:(NSString *)endDate resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [self call:@"deleteHealthConnectData" args:@[(startDate ?: (id)[NSNull null]), (endDate ?: (id)[NSNull null])] resolve:resolve reject:reject];
}

- (void)getStepSources:(NSString *)startDate endDate:(NSString *)endDate resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [self call:@"getStepSources" args:@[(startDate ?: (id)[NSNull null]), (endDate ?: (id)[NSNull null])] resolve:resolve reject:reject];
}

- (void)getCurrentStepSource:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [self call:@"getCurrentStepSource" args:@[] resolve:resolve reject:reject];
}

- (void)setPreferredStepSource:(NSString * _Nullable)packageName resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [self call:@"setPreferredStepSource" args:@[(packageName ?: (id)[NSNull null])] resolve:resolve reject:reject];
}

- (void)getInstalledCompanionApps:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [self call:@"getInstalledCompanionApps" args:@[] resolve:resolve reject:reject];
}

- (void)getPendingSyncCount:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [self call:@"getPendingSyncCount" args:@[] resolve:resolve reject:reject];
}

- (void)getSyncStatus:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [self call:@"getSyncStatus" args:@[] resolve:resolve reject:reject];
}

- (void)syncNow:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [self call:@"syncNow" args:@[] resolve:resolve reject:reject];
}

@end
