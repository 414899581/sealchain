{-# LANGUAGE RecordWildCards #-}
-- | Utility functions working on Utxo.

module Pos.Chain.Txp.Toil.Utxo.Util
       ( filterUtxoByAddr
       , filterUtxoByAddrs
       , getTotalCoinsInUtxo
       , getTotalGDsInUtxo
       , utxoToStakes
       , utxoToAddressCoinPairs
       , utxoToAddressCoinPairMap
       ) where

import           Universum

import qualified Data.HashMap.Strict as HM
import qualified Data.HashSet as HS
import qualified Data.Map.Strict as M

import           Pos.Chain.Genesis (GenesisWStakeholders)
import           Pos.Chain.Txp.Base (addrBelongsTo, addrBelongsToSet,
                     txOutStake)
import           Pos.Chain.Txp.Toil.Types (Utxo)
import           Pos.Chain.Txp.Tx (TxOut (..), isOriginTxOut, isGDTxOut)
import           Pos.Chain.Txp.TxOutAux (TxOutAux (..))
import           Pos.Core (Address, Coin, GoldDollar, CoinPair, StakesMap, 
                     sumCoins, unsafeAddCoin, unsafeIntegerToCoin, mkCoin, mkGoldDollar,
                     sumGoldDollars, unsafeIntegerToGoldDollar,
                     zeroCoinPair, unsafeAddCoinPair)

-- | Select only TxOuts for given address
filterUtxoByAddr :: Address -> Utxo -> Utxo
filterUtxoByAddr addr = M.filter (`addrBelongsTo` addr)

-- | Select only TxOuts for given addresses
filterUtxoByAddrs :: [Address] -> Utxo -> Utxo
filterUtxoByAddrs addrs =
    let addrSet = HS.fromList addrs
    in  M.filter (`addrBelongsToSet` addrSet)

-- | Get total amount of coins in given Utxo
getTotalCoinsInUtxo :: Utxo -> Coin
getTotalCoinsInUtxo =
    unsafeIntegerToCoin . 
    sumCoins .
    map (txOutValue . toaOut) . 
    filter (isOriginTxOut . toaOut) . 
    toList

-- | Get total amount of gds in given Utxo
getTotalGDsInUtxo :: Utxo -> GoldDollar
getTotalGDsInUtxo =
    unsafeIntegerToGoldDollar . 
    sumGoldDollars .
    map (txOutGD . toaOut) . 
    filter (isGDTxOut . toaOut) . 
    toList

-- | Convert 'Utxo' to 'StakesMap'.
utxoToStakes :: GenesisWStakeholders -> Utxo -> StakesMap
utxoToStakes bootStakeholders = foldl' putDistr mempty . M.toList
  where
    plusAt hm (key, val) = HM.insertWith unsafeAddCoin key val hm
    putDistr hm (_, TxOutAux txOut) =
        foldl' plusAt hm (txOutStake bootStakeholders txOut)

utxoToAddressCoinPairs :: Utxo -> [(Address, CoinPair)]
utxoToAddressCoinPairs utxo = combineWith unsafeAddCoinPair txOuts
  where
    combineWith :: (Eq a, Hashable a) => (b -> b -> b) -> [(a, b)] -> [(a, b)]
    combineWith func = HM.toList . HM.fromListWith func

    txOuts :: [(Address, CoinPair)]
    txOuts = map processTxOutAux utxoTxOuts

    utxoTxOuts :: [TxOutAux]
    utxoTxOuts =  M.elems utxo

    processTxOutAux :: TxOutAux -> (Address, CoinPair)
    processTxOutAux (TxOutAux TxOut{..}) = (txOutAddress, (txOutValue, mkGoldDollar 0))
    processTxOutAux (TxOutAux TxOutGD{..}) = (txOutAddress, (mkCoin 0, txOutGD))
    processTxOutAux (TxOutAux TxOutState{..}) = (txOutAddress, zeroCoinPair)

utxoToAddressCoinPairMap :: Utxo -> HashMap Address CoinPair
utxoToAddressCoinPairMap = HM.fromList . utxoToAddressCoinPairs
