{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TemplateHaskell #-}

{-# OPTIONS_GHC -fno-warn-orphans #-}

-- | Arbitrary instances for core.

module Test.Pos.Core.Arbitrary
       ( CoinPairOverflowSum (..)
       , CoinPairOverflowSub (..)
       , CoinPairOverflowMul (..)
       , DoubleInZeroToOneRange (..)
       , EoSToIntOverflow (..)
       , IntegerToCoinNoOverflow (..)
       , IntegerToCoinOverflow (..)
       , LessThanZeroOrMoreThanOne (..)
       , SafeCoinPairMul (..)
       , SafeCoinPairSum (..)
       , SafeCoinPairSub (..)
       , UnreasonableEoS (..)

       , genAddress
       , genPositiveSlotCount
       , genSlotId
       , genLocalSlotIndex
       ) where

import           Universum

import qualified Data.ByteString as BS (pack)
import qualified Data.Map as M
import           Data.Time.Units (TimeUnit (..))
import           System.Random (Random)
import           Test.QuickCheck (Arbitrary (..), Gen, choose, oneof, scale,
                     shrinkIntegral, sized, suchThat)
import           Test.QuickCheck.Arbitrary.Generic (genericArbitrary,
                     genericShrink)
import           Test.QuickCheck.Instances ()

import           Pos.Binary.Class (Bi)
import           Pos.Core (AddrAttributes (..), AddrSpendingData (..),
                     AddrStakeDistribution (..), AddrType (..), Address (..),
                     Address' (..), BlockCount (..), ChainDifficulty (..),
                     Coeff (..), Coin (..), CoinPortion (..), EpochIndex (..),
                     EpochOrSlot (..), LocalSlotIndex (..), Script (..),
                     SharedSeed (..), SlotCount (..), SlotId (..),
                     StakeholderId, TimeDiff (..), Timestamp (..),
                     TxFeePolicy (..), TxSizeLinear (..),
                     GoldDollar (..), unsafeGetGoldDollar, mkGoldDollar,
                     coinPortionDenominator, coinToInteger, divCoin,
                     localSlotIndexMaxBound, localSlotIndexMinBound,
                     makeAddress, mkCoin, mkLocalSlotIndex, mkMultiKeyDistr,
                     unsafeCoinPortionFromDouble, unsafeGetCoin, unsafeSubCoin)
import           Pos.Core.Attributes (Attributes (..), UnparsedFields (..))
import           Pos.Core.Constants (sharedSeedLength)
import           Pos.Core.Merkle (MerkleTree, mkMerkleTree)
import           Pos.Core.NetworkMagic (NetworkMagic (..))
import           Pos.Core.ProtocolConstants (pcEpochSlots)
import           Pos.Util.Util (leftToPanic)

import           Test.Pos.Core.Dummy (dummyProtocolConstants)
import           Test.Pos.Crypto.Arbitrary ()


{- NOTE: Deriving an 'Arbitrary' instance
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

(As of derive-2.6.2)

Using, as an example,

    {-# LANGUAGE TemplateHaskell #-}

    import Data.Derive.TH (derive, makeArbitrary)

    data A = A
        { getA1 :: [(String, Int)]
        , getA2 :: Float
        } deriving (Show, Eq, Generic)
    -- `A`'s inner types can be anything for which the constraints make sense

    derive makeArbitrary ''A

means the generated 'Arbitrary' instance uses the default 'shrink' implementation:

    shrink = []

'Pos.Util.Util.dumpSplices' can be used to verify this.'
-}

instance Arbitrary Script where
    arbitrary = genericArbitrary
    shrink = genericShrink

deriving instance Arbitrary BlockCount
deriving instance Arbitrary ChainDifficulty

----------------------------------------------------------------------------
-- Slotting
----------------------------------------------------------------------------

deriving instance Arbitrary SlotCount

genPositiveSlotCount :: Gen SlotCount
genPositiveSlotCount = do
    let upperBound = 5000 -- no specific reason for using 5000
    x <- choose (1, upperBound)
    pure $ SlotCount x

maxReasonableEpoch :: Integral a => a
maxReasonableEpoch = 5 * 1000 * 1000 * 1000 * 1000  -- 5 * 10^12, because why not

deriving instance Random EpochIndex

instance Arbitrary EpochIndex where
    arbitrary = choose (0, maxReasonableEpoch)
    shrink = genericShrink

genLocalSlotIndex :: SlotCount -> Gen LocalSlotIndex
genLocalSlotIndex epochSlots = UnsafeLocalSlotIndex <$>
    choose ( getSlotIndex localSlotIndexMinBound
           , getSlotIndex $ localSlotIndexMaxBound epochSlots
           )

instance Arbitrary LocalSlotIndex where
    arbitrary = genLocalSlotIndex $ pcEpochSlots dummyProtocolConstants
    shrink = genericShrink

genSlotId :: SlotCount -> Gen SlotId
genSlotId epochSlots = SlotId <$> arbitrary <*> genLocalSlotIndex epochSlots

instance Arbitrary SlotId where
    arbitrary = genericArbitrary
    shrink = genericShrink

instance Arbitrary EpochOrSlot where
    arbitrary = oneof [
          EpochOrSlot . Left <$> arbitrary
        , EpochOrSlot . Right <$> arbitrary
        ]
    shrink = genericShrink

-- | A wrapper over 'EpochOrSlot'. When converted to 'EpochOrSlot' via 'fromEnum', using
-- this type ensures there's an exception.
newtype EoSToIntOverflow = EoSToIntOverflow
    { getEoS :: EpochOrSlot
    } deriving (Show, Eq, Generic)

instance Arbitrary EoSToIntOverflow where
    arbitrary = EoSToIntOverflow <$> do
        let epochSlots = pcEpochSlots dummyProtocolConstants
            maxIntAsInteger = toInteger (maxBound :: Int)
            maxW64 = toInteger (maxBound :: Word64)
            (minDiv, minMod) = maxIntAsInteger `divMod` (fromIntegral $ succ epochSlots)
            maxDiv = maxW64 `div` (1 + fromIntegral epochSlots)
        leftEpoch <- EpochIndex . fromIntegral <$> choose (minDiv + 1, maxDiv)
        localSlot <-
            leftToPanic "arbitrary@EoSToIntOverflow" .
            mkLocalSlotIndex epochSlots .
            fromIntegral <$> choose (minMod, toInteger epochSlots)
        let rightEpoch = EpochIndex . fromIntegral $ minDiv
        EpochOrSlot <$>
            oneof [ pure $ Left leftEpoch
                  , pure $ Right SlotId { siEpoch = rightEpoch
                                              , siSlot = localSlot}
                  ]
    shrink = genericShrink

-- | Wrapper over 'EpochOrSlot'. Its 'Arbitrary' instance is made to guarantee its
-- 'EpochIndex' is in the interval (maxReasonableEpoch, maxBound :: Word64 ].
-- This is to ensure the property 'toEnum . fromEnum = id' holds for all 'EpochOrSlot',
-- not just the ones whose 'EpochIndex' uses the "reasonable" 'Arbitrary' instance.
newtype UnreasonableEoS = Unreasonable
    { getUnreasonable :: EpochOrSlot
    } deriving (Show, Eq, Generic)

instance Arbitrary UnreasonableEoS where
    arbitrary = Unreasonable . EpochOrSlot <$> do
        let epochSlots = pcEpochSlots dummyProtocolConstants
        let maxI = (maxBound :: Int) `div` (1 + fromIntegral epochSlots)
        localSlot <- arbitrary
        let lsIntegral = fromIntegral . getSlotIndex $ localSlot
        let epoch n = EpochIndex <$>
                choose (succ maxReasonableEpoch
                       , fromIntegral maxI - (n * fromIntegral (succ epochSlots)))
        leftEpoch <- Left <$> epoch 0
        rightSlot <- Right . (flip SlotId localSlot) <$> epoch lsIntegral
        oneof [ pure leftEpoch
              , pure rightSlot
              ]
    shrink = genericShrink

----------------------------------------------------------------------------
-- Address and related
----------------------------------------------------------------------------

instance Arbitrary AddrType where
    arbitrary =
        oneof
            [ pure ATPubKey
            , pure ATScript
            , pure ATRedeem
            , ATUnknown <$> choose (3, maxBound)
            ]

instance Arbitrary AddrSpendingData where
    arbitrary =
        oneof
            [ PubKeyASD <$> arbitrary
            , ScriptASD <$> arbitrary
            , RedeemASD <$> arbitrary
            -- For unknown spending data payload will be at most 120
            -- bytes long.
            , UnknownASD <$> choose (3, 255) <*> scale (min 120) arbitrary
            ]

instance Arbitrary AddrStakeDistribution where
    arbitrary =
        oneof
            [ pure BootstrapEraDistr
            , SingleKeyDistr <$> arbitrary
            , leftToPanic "arbitrary @AddrStakeDistribution: " .
              mkMultiKeyDistr <$>
              genMultiKeyDistr
            ]
      where
        genMultiKeyDistr :: Gen (Map StakeholderId CoinPortion)
        -- We don't want to generate too much, hence 'scale'.
        genMultiKeyDistr =
            scale (min 16) $ do
                holder0 <- arbitrary
                holder1 <- arbitrary `suchThat` (/= holder0)
                moreHolders <- arbitrary @[StakeholderId]
                -- Must be at least 2 non-repeating stakeholders.
                let holders = ordNub (holder0 : holder1 : moreHolders)
                portions <- genPortions (length holders) []
                return $ M.fromList $ holders `zip` portions
        genPortions :: Int -> [CoinPortion] -> Gen [CoinPortion]
        genPortions 0 res = pure res
        genPortions n res = do
            let limit =
                    foldl' (-) coinPortionDenominator $
                    map getCoinPortion res
            case (n, limit) of
                -- Limit is exhausted, can't create more.
                (_, 0) -> return res
                -- The last portion, we must ensure the sum is correct.
                (1, _) -> return (CoinPortion limit : res)
                -- We intentionally don't generate 'limit', because we
                -- want to generate at least 2 portions.  However, if
                -- 'limit' is 1, we will generate 1, because we must
                -- have already generated one portion.
                _ -> do
                    portion <-
                        CoinPortion <$> choose (1, max 1 (limit - 1))
                    genPortions (n - 1) (portion : res)

instance Arbitrary NetworkMagic where
    arbitrary = oneof [pure NetworkMainOrStage, NetworkTestnet <$> arbitrary]

instance Arbitrary AddrAttributes where
    arbitrary = genericArbitrary
    shrink = genericShrink

deriving instance Arbitrary Address'

instance Arbitrary Address where
    arbitrary = makeAddress <$> arbitrary <*> arbitrary
    shrink = genericShrink

genAddress :: NetworkMagic -> Gen Address
genAddress nm = makeAddress <$> arbitrary <*> genAddrAttr
  where
    genAddrAttr = AddrAttributes <$> arbitrary <*> arbitrary <*> pure nm

----------------------------------------------------------------------------
-- Attributes
----------------------------------------------------------------------------

instance Arbitrary UnparsedFields where
    arbitrary = sized $ go M.empty
        where
            go !acc 0 = pure $ UnparsedFields acc
            go !acc n = do
                -- Assume that data type doesn't have more than 100 constructors.
                k <- choose (100, maxBound)
                v <- arbitrary
                go (M.insert k v acc) (n - 1)
    shrink = genericShrink

instance Arbitrary h => Arbitrary (Attributes h) where
    arbitrary = genericArbitrary
    shrink = genericShrink

----------------------------------------------------------------------------
-- Coin
----------------------------------------------------------------------------

instance Arbitrary Coin where
    arbitrary = mkCoin <$> choose (1, unsafeGetCoin maxBound)
    shrink = genericShrink

-- | This datatype has two coins that will always overflow when added.
-- It is used in tests to make sure addition raises the appropriate exception when this
-- happens.
newtype CoinPairOverflowSum = TwoCoinsSum
    { get2CSum :: (Coin, Coin)
    } deriving (Show, Eq)

instance Arbitrary CoinPairOverflowSum where
    arbitrary = do
        c1 <- arbitrary
        let lowerBound = succ $ coinToInteger $ (maxBound @Coin) `unsafeSubCoin` c1
            upperBound = coinToInteger (maxBound @Coin)
        c2 <- mkCoin . fromIntegral <$> choose (lowerBound, upperBound)
        return $ TwoCoinsSum (c1, c2)

-- | This datatype has two coins that will never overflow when added.
-- It is therefore safe to add them. Useful in tests to ensure adding two coins whose sum
-- is a valid 'Coin' always works.
newtype SafeCoinPairSum = CoinPairSum
    { getPairSum :: (Coin, Coin)
    } deriving (Show, Eq)

instance Arbitrary SafeCoinPairSum where
    arbitrary = do
        c1 <- arbitrary
        let upperBound = unsafeGetCoin c1
            highestBound = unsafeGetCoin maxBound
        c2 <- mkCoin <$> choose (0, highestBound - upperBound)
        return $ CoinPairSum (c1, c2)

-- | This datatype has two coins that will always underflow when subtracted.
-- It is used in tests to make sure subtraction raises the appropriate exception when this
-- happens.
newtype CoinPairOverflowSub = TwoCoinsSub
    { get2CSub :: (Coin, Coin)
    } deriving (Show, Eq)

instance Arbitrary CoinPairOverflowSub where
    arbitrary = do
        firstCoin <- arbitrary
        let firstWord = unsafeGetCoin firstCoin
            c1 = if firstCoin == maxBound
                then mkCoin $ firstWord - 1
                else firstCoin
        c2 <- arbitrary `suchThat` (> c1)
        return $ TwoCoinsSub (c1, c2)

-- | This datatype has two coins that will never underflow when subtracted.
-- It is therefore safe to subtract them. Useful in tests to show that two coins whose
-- subtraction does not underflow always works.
newtype SafeCoinPairSub = CoinPairSub
    { getPairSub :: (Coin, Coin)
    } deriving (Show, Eq)

instance Arbitrary SafeCoinPairSub where
    arbitrary = do
        c1 <- arbitrary
        let upperBound = unsafeGetCoin c1
        c2 <- mkCoin <$> choose (0, upperBound)
        return $ CoinPairSub (c1, c2)

-- | This datatype has a 'Coin' and an 'Integer' that will always overflow when
-- multiplied.
-- It is used in tests to make sure multiplication raises the appropriate exception when
-- this happens.
newtype CoinPairOverflowMul = TwoCoinsM
    { get2CMul :: (Coin, Integer)
    } deriving (Show, Eq)

instance Arbitrary CoinPairOverflowMul where
    arbitrary = do
        c1 <- arbitrary
        let integralC1 = getCoin c1
            lowerBound =
                1 + (coinToInteger $ (maxBound @Coin) `divCoin` integralC1)
            upperBound = coinToInteger (maxBound @Coin)
        c2 <- fromIntegral @Integer <$> choose (lowerBound, upperBound)
        return $ TwoCoinsM (c1, c2)

-- | This datatype has a 'Coin' and an 'Integer'  that will always overflow when
-- multiplied.
-- It is used to make sure coin multiplication by an integer raises the appropriate
-- exception when this happens.
newtype SafeCoinPairMul = CoinPairMul
    { getPairMul :: (Coin, Integer)
    } deriving (Show, Eq)

instance Arbitrary SafeCoinPairMul where
    arbitrary = do
        c1 <- arbitrary
        let upperBound = coinToInteger c1
            highestBound = coinToInteger maxBound
        c2 <- choose (0, div highestBound upperBound)
        return $ CoinPairMul (c1, c2)

-- | 'IntegerToCoinOverflow' is a wrapped over 'Integer'. Its 'Arbitrary' instance makes
-- it so that these integers will always overflow when converted into a 'Coin'.
-- Used in tests to make sure an exception is raised when there is an attempt to turn an
-- excessively large 'Integer' into a 'Coin'.
newtype IntegerToCoinOverflow = LargeInteger
    { getLargeInteger :: Integer
    } deriving (Show, Eq)

instance Arbitrary IntegerToCoinOverflow where
    arbitrary = LargeInteger <$> do
        n <- succ . fromIntegral <$> (arbitrary :: Gen Word)
        let lowerBound = succ . coinToInteger $ maxBound @Coin
        num <- choose (lowerBound, n * lowerBound)
        return $ toInteger num

-- | This datatype has an Integer that will never overflow when turned into a 'Coin'.
-- Useful for testing that conversion between valid 'Integer's and 'Coin's works properly.
newtype IntegerToCoinNoOverflow = Integer
    { getInteger :: Integer
    } deriving (Show, Eq)

instance Arbitrary IntegerToCoinNoOverflow where
    arbitrary =
      Integer . fromIntegral <$> choose (0, unsafeGetCoin $ maxBound @Coin)

instance Arbitrary CoinPortion where
    arbitrary = unsafeCoinPortionFromDouble . (1/) <$> choose (1, 20)

-- | A wrapper over 'Double'. Its 'Arbitrary' instance ensures the 'Double' within can
-- never be converted into a 'CoinPortion' without an exception being raised. Used in
-- tests to safeguard that converting an invalid 'Double' to a 'CoinPortion' always
-- raised an exception.
newtype LessThanZeroOrMoreThanOne = BadCoinPortion
    { getDouble :: Double
    } deriving (Show, Eq)

instance Arbitrary LessThanZeroOrMoreThanOne where
    arbitrary = BadCoinPortion <$> do
        d <- arbitrary
        return $ if (d >= 0 && d <= 1)
            then 10 / d
            else d

-- | Another wrapper over 'Double'. Its 'Arbitrary' instance guarantees the 'Double'
-- inside can always be safely turned into a 'CoinPortion'. Used in tests to ensure
-- converting a valid 'Double' to/from 'CoinPortion' works properly.
newtype DoubleInZeroToOneRange = DoubleInRange
    { getDoubleInRange :: Double
    } deriving (Show, Eq)

instance Arbitrary DoubleInZeroToOneRange where
    arbitrary = DoubleInRange <$> choose (0, 1)

----------------------------------------------------------------------------
-- GoldDollar
----------------------------------------------------------------------------

instance Arbitrary GoldDollar where
    arbitrary = mkGoldDollar <$> choose (1, unsafeGetGoldDollar maxBound)
    shrink = genericShrink

instance Arbitrary SharedSeed where
    arbitrary = do
        bs <- replicateM sharedSeedLength (choose (0, 255))
        return $ SharedSeed $ BS.pack bs

----------------------------------------------------------------------------
-- Arbitrary types from 'Pos.Core.Fee'
----------------------------------------------------------------------------

deriving instance Arbitrary Coeff

instance Arbitrary TxSizeLinear where
    arbitrary = genericArbitrary
    shrink = genericShrink

instance Arbitrary TxFeePolicy where
    arbitrary = oneof
        [ TxFeePolicyTxSizeLinear <$> arbitrary
        , do
              policyCode <-
                  -- The lower bound is needed so that
                  -- we don't get codes for known policies.
                  choose (1, maxBound)
              policyPayload <- arbitrary
              return $ TxFeePolicyUnknown policyCode policyPayload
        ]
    shrink = \case
        TxFeePolicyTxSizeLinear a ->
            TxFeePolicyTxSizeLinear <$> shrink a
        TxFeePolicyUnknown v a ->
            TxFeePolicyUnknown v <$> shrink a

----------------------------------------------------------------------------
-- Arbitrary miscellaneous types
----------------------------------------------------------------------------

instance Arbitrary Timestamp where
    arbitrary = Timestamp . fromMicroseconds <$> choose (0, 2000000000 * 1000 * 1000)
    shrink = shrinkIntegral

deriving instance Arbitrary TimeDiff

----------------------------------------------------------------------------
-- Merkle
----------------------------------------------------------------------------

instance (Bi a, Arbitrary a) => Arbitrary (MerkleTree a) where
    arbitrary = mkMerkleTree <$> arbitrary
