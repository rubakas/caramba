import type { CapacitorConfig } from '@capacitor/cli';

const config: CapacitorConfig = {
  appId: 'com.caramba.tv',
  appName: 'Caramba',
  webDir: '../web/dist',
  server: {
    // Use http to allow connections to local http servers
    androidScheme: 'http',
    // Allow mixed content (http requests from the app)
    allowNavigation: ['*']
  },
  android: {
    // Allow cleartext (http) traffic
    allowMixedContent: true
  },
  plugins: {
    SplashScreen: {
      launchShowDuration: 0,
    },
    Preferences: {
      group: 'com.caramba.tv',
    }
  }
};

export default config;
