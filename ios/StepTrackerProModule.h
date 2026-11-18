#import <Foundation/Foundation.h>

#ifdef __cplusplus
#import <RNStepTrackerProIOSSpec/RNStepTrackerProIOSSpec.h>
#endif

NS_ASSUME_NONNULL_BEGIN

/**
 * The `StepTrackerPro` TurboModule on iOS. react-native-step-tracker-pro's
 * JavaScript finds it through `TurboModuleRegistry.get('StepTrackerPro')`
 * and drives it exactly as it drives the Android module. Every method
 * forwards to `StepTrackerProBridge` (Swift), which owns all state on one
 * serial queue.
 */
#ifdef __cplusplus
@interface StepTrackerProModule : NativeStepTrackerProSpecBase <NativeStepTrackerProSpec>
#else
@interface StepTrackerProModule : NSObject
#endif
@end

NS_ASSUME_NONNULL_END
