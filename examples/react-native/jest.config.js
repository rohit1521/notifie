module.exports = {
  preset: '@react-native/jest-preset',
  transformIgnorePatterns: [
    '<rootDir>/../../node_modules/.pnpm/(?!(react-native|@react-native\\+|@react-native-community\\+)@)',
    'node_modules/(?!.pnpm|react-native|@react-native|@react-native-community)',
  ],
};
