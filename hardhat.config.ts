import dotenv from 'dotenv';
import 'solidity-coverage';
import { HardhatUserConfig } from 'hardhat/config';

import '@nomicfoundation/hardhat-toolbox';
import { getAlchemyMainnetUrl } from './helpers/alchemy.helpers';

dotenv.config();

function getEnvVar(name: string): string {
  const value = process.env[name];
  if (!value) {
    throw new Error(`Environment variable ${name} is not defined`);
  }
  return value;
}

const ALCHEMY_API_KEY = getEnvVar('ALCHEMY_API_KEY');
const PRIVATE_KEY = getEnvVar('PRIVATE_KEY');

const config: HardhatUserConfig = {
  solidity: '0.8.28',
  networks: {

    hardhat: {
      forking: {
        url: getAlchemyMainnetUrl(ALCHEMY_API_KEY),
        blockNumber: 18000000,
      },
      accounts: [
        {
          privateKey: PRIVATE_KEY,
          balance: '1000000000000000000000',
        },
      ],
      initialBaseFeePerGas: 0, // for fork testing
    },
  },
};


export default config;
