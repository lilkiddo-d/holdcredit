/** @type {import('next').NextConfig} */
const nextConfig = {
  reactStrictMode: true,
  webpack: (config) => {
    // WalletConnect / MetaMask SDK optional deps that are not needed in the browser bundle.
    config.externals.push("pino-pretty", "lokijs", "encoding");
    config.resolve.fallback = { ...config.resolve.fallback, "@react-native-async-storage/async-storage": false };
    // @coinbase/cdp-sdk (pulled in via wagmi's Base Account connector) imports optional x402 payment packages
    // that Holdcredit never uses; resolve them to empty modules.
    config.resolve.alias = { ...config.resolve.alias, "@x402/evm": false, "@x402/svm": false, "@x402/core": false };
    return config;
  },
};
export default nextConfig;
