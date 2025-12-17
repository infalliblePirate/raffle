export const getAlchemyMainnetUrl = (alchemyKey: string) => {
  return `https://eth-mainnet.g.alchemy.com/v2/${alchemyKey}`;
};

export const getAlchemySepoliaUrl = (alchemyKey: string) => {
  return `https://eth-sepolia.g.alchemy.com/v2/${alchemyKey}`;
};