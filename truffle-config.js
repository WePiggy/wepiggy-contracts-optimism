const HDWalletProvider = require('@truffle/hdwallet-provider');

module.exports = {

    networks: {
        optimistic_kovan: {
            network_id: 69,
            gas: 0,
            gasPrice: 15000000,
            provider: function () {
                return new HDWalletProvider("", "https://kovan.optimism.io", 0, 1);
            },
            ovm: true
        },
    },
    compilers: {
        solc: {
            version: "node_modules/@eth-optimism/solc",
            settings: {
                optimizer: {
                    enabled: true,
                    runs: 1
                }
            }
        },
    },
    db: {
        enabled: false
    }
}