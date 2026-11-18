const path = require('path');

// The example links this repository's package from source.
module.exports = {
  dependencies: {
    'react-native-step-tracker-pro-ios': {
      root: path.join(__dirname, '..'),
    },
  },
};
