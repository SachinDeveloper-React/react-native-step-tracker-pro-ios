'use strict';

/**
 * react-native-step-tracker-pro-ios has no JavaScript API of its own. It
 * registers the native `StepTrackerPro` TurboModule on iOS, and the API you
 * call is react-native-step-tracker-pro's:
 *
 *   import StepTracker from 'react-native-step-tracker-pro';
 *
 * Installing this package (and running `pod install`) is all it takes.
 */
module.exports = {
  /** The version of this package, as signed into iOS snapshots' `libraryVersion`. */
  version: require('./package.json').version,
};
