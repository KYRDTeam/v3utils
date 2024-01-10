#!/bin/bash

setup-dev:
	anvil --fork-url https://mainnet.infura.io/v3/$(INFURA_API_KEY); 

# deploy using the default account by anvil which is imported before hand
# cast wallet import --interactive anvilLocalDev
deploy-local:
	forge script script/V3Utils.s.sol:MyScript --fork-url http://localhost:8545 --sender 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 --account anvilLocalDev --broadcast -vvvv

deploy-testnet:
	forge script script/V3Utils.s.sol:MyScript --rpc-url $(GOERLI_RPC_URL) --sender 0x320849EC0aDffCd6fb0212B59a2EC936cdEF5fCa --account krystalOps --broadcast --verify -vvvv
