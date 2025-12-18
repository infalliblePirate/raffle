import dotenv from 'dotenv';
import 'solidity-coverage';
import { HardhatUserConfig } from 'hardhat/config';

import '@nomicfoundation/hardhat-toolbox';
import { getAlchemyMainnetUrl, getAlchemySepoliaUrl } from './helpers/alchemy.helpers';
import { latest } from '@nomicfoundation/hardhat-network-helpers/dist/src/helpers/time';
import { version } from 'node:os';

dotenv.config();

function getEnvVar(name: string): string {
  const value = process.env[name];
  if (!value) {
    throw new Error(`Environment variable ${name} is not defined`);
  }
  return value;
}

const ALCHEMY_API_KEY = getEnvVar('ALCHEMY_API_KEY');
const PRIVATE1_KEY = getEnvVar('PRIVATE1_KEY');
const PRIVATE2_KEY = getEnvVar('PRIVATE2_KEY');
const ETHERSCAN_API_KEY = getEnvVar('ETHERSCAN_API_KEY');

const config: HardhatUserConfig = {
  solidity: {
    version: '0.8.28',
    settings: {
      evmVersion: "cancun",
      optimizer: {
        enabled: true
      }
    },
  },
  sourcify: {
    enabled: true
  },
  networks: {

    hardhat: {
      forking: {
        url: getAlchemyMainnetUrl(ALCHEMY_API_KEY),
        blockNumber: 18000000,
      },
      accounts: { count: 10 },
      // accounts: [
      //   {
      //     privateKey: PRIVATE_KEY,
      //     balance: '1000000000000000000000',
      //   },
      // ],
      initialBaseFeePerGas: 0, // for fork testing
    },
    sepolia: {
      chainId: 11155111,
      url: getAlchemySepoliaUrl(ALCHEMY_API_KEY),
      accounts: [PRIVATE1_KEY, PRIVATE2_KEY],
    },
  },
  etherscan: {
    apiKey: ETHERSCAN_API_KEY,
  },
};


export default config;
