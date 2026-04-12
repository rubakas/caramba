import type { CapacitorConfig } from '@capacitor/cli';

const config: CapacitorConfig = {
  appId: 'com.caramba.tv',
  appName: 'Caramba',
  webDir: '../web/dist',
  server: {
    androidScheme: 'https'
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
