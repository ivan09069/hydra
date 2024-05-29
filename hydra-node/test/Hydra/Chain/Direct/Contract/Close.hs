{-# LANGUAGE DuplicateRecordFields #-}
{-# OPTIONS_GHC -Wno-orphans #-}

module Hydra.Chain.Direct.Contract.Close where

import Hydra.Cardano.Api
import Hydra.Prelude hiding (label)

import Cardano.Api.UTxO as UTxO
import Data.Maybe (fromJust)
import Hydra.Chain.Direct.Contract.Gen (genHash, genMintedOrBurnedValue)
import Hydra.Chain.Direct.Contract.Mutation (
  Mutation (..),
  SomeMutation (..),
  addParticipationTokens,
  changeMintedTokens,
  modifyInlineDatum,
  replaceContestationDeadline,
  replaceContestationPeriod,
  replaceContesters,
  replaceHeadId,
  replaceParties,
  replacePolicyIdWith,
  replaceSnapshotNumber,
  replaceUtxoHash,
  replaceUtxoToDecommitHash,
 )
import Hydra.Chain.Direct.Fixture qualified as Fixture
import Hydra.Chain.Direct.ScriptRegistry (genScriptRegistry, registryUTxO)
import Hydra.Chain.Direct.State (splitUTxO)
import Hydra.Chain.Direct.TimeHandle (PointInTime)
import Hydra.Chain.Direct.Tx (ClosingSnapshot (..), OpenThreadOutput (..), UTxOHash (UTxOHash), closeTx, mkHeadId, mkHeadOutput)
import Hydra.ContestationPeriod (fromChain)
import Hydra.Contract.Error (toErrorCode)
import Hydra.Contract.HeadError (HeadError (..))
import Hydra.Contract.HeadState qualified as Head
import Hydra.Contract.HeadTokens (headPolicyId)
import Hydra.Contract.Util (UtilError (MintingOrBurningIsForbidden))
import Hydra.Crypto (HydraKey, MultiSignature, aggregate, sign, toPlutusSignatures)
import Hydra.Data.ContestationPeriod qualified as OnChain
import Hydra.Data.Party qualified as OnChain
import Hydra.Ledger (hashUTxO)
import Hydra.Ledger.Cardano (genAddressInEra, genOneUTxOFor, genValue, genVerificationKey)
import Hydra.Ledger.Cardano.Evaluate (genValidityBoundsFromContestationPeriod)
import Hydra.Party (Party, deriveParty, partyToChain)
import Hydra.Plutus.Extras (posixFromUTCTime)
import Hydra.Plutus.Orphans ()
import Hydra.Snapshot (Snapshot (..), SnapshotNumber)
import PlutusLedgerApi.V1.Time (DiffMilliSeconds (..), fromMilliSeconds)
import PlutusLedgerApi.V2 (BuiltinByteString, POSIXTime, PubKeyHash (PubKeyHash), toBuiltin)
import Test.Hydra.Fixture (aliceSk, bobSk, carolSk, genForParty)
import Test.QuickCheck (arbitrarySizedNatural, choose, elements, listOf1, oneof, suchThat)
import Test.QuickCheck.Instances ()

-- | Healthy close transaction for the generic case were we close a head
--   after one or more snapshot have been agreed upon between the members.
healthyCloseTx :: (Tx, UTxO)
healthyCloseTx =
  (tx, lookupUTxO)
 where
  tx =
    closeTx
      scriptRegistry
      somePartyCardanoVerificationKey
      closingSnapshot
      healthyCloseLowerBoundSlot
      healthyCloseUpperBoundPointInTime
      openThreadOutput
      (mkHeadId Fixture.testPolicyId)

  datum = toUTxOContext (mkTxOutDatumInline healthyOpenHeadDatum)

  lookupUTxO =
    UTxO.singleton (healthyOpenHeadTxIn, healthyOpenHeadTxOut datum)
      <> registryUTxO scriptRegistry

  scriptRegistry = genScriptRegistry `generateWith` 42

  openThreadOutput =
    OpenThreadOutput
      { openThreadUTxO = (healthyOpenHeadTxIn, healthyOpenHeadTxOut datum)
      , openParties = healthyOnChainParties
      , openContestationPeriod = healthyContestationPeriod
      }

  closingSnapshot :: ClosingSnapshot
  closingSnapshot =
    let (utxo, utxoToDecommit) = generateWith (splitUTxO healthyCloseUTxO) 42
     in CloseWithConfirmedSnapshot
          { snapshotNumber = healthyCloseSnapshotNumber
          , closeUtxoHash = UTxOHash $ hashUTxO @Tx utxo
          , closeUtxoToDecommitHash = UTxOHash $ hashUTxO @Tx utxoToDecommit
          , signatures = healthySignature healthyCloseSnapshotNumber
          }

-- | Healthy close transaction for the specific case were we close a head
--   with the initial UtxO, that is, no snapshot have been agreed upon and
--   signed by the head members yet.
healthyCloseInitialTx :: (Tx, UTxO)
healthyCloseInitialTx =
  (tx, lookupUTxO)
 where
  tx =
    closeTx
      scriptRegistry
      somePartyCardanoVerificationKey
      closingSnapshot
      healthyCloseLowerBoundSlot
      healthyCloseUpperBoundPointInTime
      openThreadOutput
      (mkHeadId Fixture.testPolicyId)

  initialDatum = toUTxOContext (mkTxOutDatumInline $ healthyOpenHeadDatum{Head.snapshotNumber = 0})

  lookupUTxO =
    UTxO.singleton (healthyOpenHeadTxIn, healthyOpenHeadTxOut initialDatum)
      <> registryUTxO scriptRegistry

  scriptRegistry = genScriptRegistry `generateWith` 42

  openThreadOutput =
    OpenThreadOutput
      { openThreadUTxO = (healthyOpenHeadTxIn, healthyOpenHeadTxOut initialDatum)
      , openParties = healthyOnChainParties
      , openContestationPeriod = healthyContestationPeriod
      }
  closingSnapshot :: ClosingSnapshot
  closingSnapshot =
    CloseWithInitialSnapshot
      { openUtxoHash = UTxOHash $ hashUTxO @Tx healthyUTxO
      }

-- NOTE: We need to use the contestation period when generating start/end tx
-- validity slots/time since if tx validity bound difference is bigger than
-- contestation period our close validator will fail
healthyCloseLowerBoundSlot :: SlotNo
healthyCloseUpperBoundPointInTime :: PointInTime
(healthyCloseLowerBoundSlot, healthyCloseUpperBoundPointInTime) =
  genValidityBoundsFromContestationPeriod (fromChain healthyContestationPeriod) `generateWith` 42

healthyOpenHeadTxIn :: TxIn
healthyOpenHeadTxIn = generateWith arbitrary 42

healthyOpenHeadTxOut :: TxOutDatum CtxUTxO -> TxOut CtxUTxO
healthyOpenHeadTxOut headTxOutDatum =
  mkHeadOutput Fixture.testNetworkId Fixture.testPolicyId headTxOutDatum
    & addParticipationTokens healthyParticipants

healthyCloseSnapshotUTxO :: (UTxO, UTxO)
healthyCloseSnapshotUTxO = generateWith (splitUTxO healthyCloseUTxO) 42

healthySnapshot :: Snapshot Tx
healthySnapshot =
  let (utxo, utxoToDecommit') = healthyCloseSnapshotUTxO
   in Snapshot
        { headId = mkHeadId Fixture.testPolicyId
        , number = healthyCloseSnapshotNumber
        , utxo
        , confirmed = []
        , utxoToDecommit = Just utxoToDecommit'
        }

healthyCloseUTxO :: UTxO
healthyCloseUTxO =
  (genOneUTxOFor somePartyCardanoVerificationKey `suchThat` (/= healthyUTxO))
    `generateWith` 42

healthyCloseUTxOHash :: BuiltinByteString
healthyCloseUTxOHash =
  toBuiltin $ hashUTxO @Tx (fst healthyCloseSnapshotUTxO)

healthyCloseUTxOToDecommitHash :: BuiltinByteString
healthyCloseUTxOToDecommitHash =
  toBuiltin $ hashUTxO @Tx (snd healthyCloseSnapshotUTxO)

healthyCloseSnapshotNumber :: SnapshotNumber
healthyCloseSnapshotNumber = 1

healthyOpenHeadDatum :: Head.State
healthyOpenHeadDatum =
  Head.Open
    { parties = healthyOnChainParties
    , utxoHash = toBuiltin $ hashUTxO @Tx healthyUTxO
    , snapshotNumber = toInteger healthyCloseSnapshotNumber
    , contestationPeriod = healthyContestationPeriod
    , headId = toPlutusCurrencySymbol Fixture.testPolicyId
    }

healthyContestationPeriod :: OnChain.ContestationPeriod
healthyContestationPeriod = OnChain.contestationPeriodFromDiffTime $ fromInteger healthyContestationPeriodSeconds

healthyContestationPeriodSeconds :: Integer
healthyContestationPeriodSeconds = 10

healthyUTxO :: UTxO
healthyUTxO = genOneUTxOFor somePartyCardanoVerificationKey `generateWith` 42

healthyParticipants :: [VerificationKey PaymentKey]
healthyParticipants =
  genForParty genVerificationKey <$> healthyParties

somePartyCardanoVerificationKey :: VerificationKey PaymentKey
somePartyCardanoVerificationKey =
  elements healthyParticipants `generateWith` 42

healthySigningKeys :: [SigningKey HydraKey]
healthySigningKeys = [aliceSk, bobSk, carolSk]

healthyParties :: [Party]
healthyParties = deriveParty <$> healthySigningKeys

healthyOnChainParties :: [OnChain.Party]
healthyOnChainParties = partyToChain <$> healthyParties

healthySignature :: SnapshotNumber -> MultiSignature (Snapshot Tx)
healthySignature number = aggregate [sign sk snapshot | sk <- healthySigningKeys]
 where
  snapshot = healthySnapshot{number}

healthyContestationDeadline :: UTCTime
healthyContestationDeadline =
  addUTCTime
    (fromInteger healthyContestationPeriodSeconds)
    (snd healthyCloseUpperBoundPointInTime)

data CloseMutation
  = -- | Ensures collectCom does not allow any output address but νHead.
    NotContinueContract
  | -- | Ensures the snapshot signature is multisigned by all valid Head
    -- participants.
    --
    -- Invalidates the tx by changing the redeemer signature
    -- but not the snapshot number in output head datum.
    MutateSignatureButNotSnapshotNumber
  | -- | Ensures the snapshot number is consistent with the signature.
    --
    -- Invalidates the tx by changing the snapshot number
    -- in resulting head output but not the redeemer signature.
    MutateSnapshotNumberButNotSignature
  | -- | Check that snapshot numbers <= 0 need to close the head with the
    -- initial UTxO hash.
    MutateSnapshotNumberToLessThanEqualZero
  | -- | Ensures the close snapshot is multisigned by all Head participants by
    -- changing the parties in the input head datum. If they do not align the
    -- multisignature will not be valid anymore.
    SnapshotNotSignedByAllParties
  | -- | Ensures close is authenticated by a one of the Head members by changing
    --  the signer used on the tx to not be one of PTs.
    MutateRequiredSigner
  | -- | Ensures close is authenticated by a one of the Head members by changing
    --  the signer used on the tx to be empty.
    MutateNoRequiredSigner
  | -- | Ensures close is authenticated by a one of the Head members by changing
    --  the signer used on the tx to have multiple signers (including the signer
    -- to not fail for SignerIsNotAParticipant).
    MutateMultipleRequiredSigner
  | -- | Invalidates the tx by changing the utxo hash in resulting head output.
    --
    -- Ensures the output state is consistent with the redeemer.
    MutateCloseUTxOHash
  | -- | Ensures parties do not change between head input datum and head output
    --  datum.
    MutatePartiesInOutput
  | -- | Ensures headId do not change between head input datum and head output
    -- datum.
    MutateHeadIdInOutput
  | -- | Invalidates the tx by changing the lower bound to be non finite.
    MutateInfiniteLowerBound
  | -- | Invalidates the tx by changing the upper bound to be non finite.
    MutateInfiniteUpperBound
  | -- | Invalidates the tx by changing the contestation deadline to not satisfy
    -- `contestationDeadline = upperBound + contestationPeriod`.
    MutateContestationDeadline
  | -- | Invalidates the tx by changing the lower and upper bound to be not
    -- bounded as per spec `upperBound - lowerBound <= contestationPeriod`.
    --
    -- This also changes the resulting `head output` contestation deadline to be
    -- valid, so it satisfy `contestationDeadline = upperBound +
    -- contestationPeriod`.
    MutateValidityInterval
  | -- | Ensure the Head cannot be closed with correct authentication from a
    -- different Head. We simulate this by changing the head policy id of the ST
    -- and PTs to be of a different head - a real attack would be to add inputs
    -- with those tokens on top of spending the head output, a bit like a double
    -- satisfaction attack. Note that the token name stays the same and
    -- consistent with the signer. This will cause authentication failure
    -- because the signer's PT, although with a consistent name, is not from the
    -- right head (has a different policy id than in the datum).
    CloseFromDifferentHead
  | -- | Minting or burning of tokens should not be possible in close.
    MutateTokenMintingOrBurning
  | -- | Invalidates the tx by changing the contesters to be non empty.
    MutateContesters
  | -- | Invalidates the tx by changing output values arbitrarily to be different
    -- (not preserved) from the head.
    --
    -- Ensures values are preserved between head input and output.
    MutateValueInOutput
  | -- | Invalidate the tx by changing the contestation period.
    MutateContestationPeriod
  deriving stock (Generic, Show, Enum, Bounded)

genCloseMutation :: (Tx, UTxO) -> Gen SomeMutation
genCloseMutation (tx, _utxo) =
  oneof
    [ SomeMutation (pure $ toErrorCode NotPayingToHead) NotContinueContract <$> do
        mutatedAddress <- genAddressInEra Fixture.testNetworkId
        pure $ ChangeOutput 0 (modifyTxOutAddress (const mutatedAddress) headTxOut)
    , SomeMutation (pure $ toErrorCode SignatureVerificationFailed) MutateSignatureButNotSnapshotNumber . ChangeHeadRedeemer <$> do
        Head.Close . toPlutusSignatures <$> (arbitrary :: Gen (MultiSignature (Snapshot Tx)))
    , SomeMutation (pure $ toErrorCode ClosedWithNonInitialHash) MutateSnapshotNumberToLessThanEqualZero <$> do
        mutatedSnapshotNumber <- arbitrary `suchThat` (<= 0)
        pure $ ChangeOutput 0 $ modifyInlineDatum (replaceSnapshotNumber mutatedSnapshotNumber) headTxOut
    , SomeMutation (pure $ toErrorCode SignatureVerificationFailed) MutateSnapshotNumberButNotSignature <$> do
        mutatedSnapshotNumber <- arbitrarySizedNatural `suchThat` (> healthyCloseSnapshotNumber)
        pure $ ChangeOutput 0 $ modifyInlineDatum (replaceSnapshotNumber $ toInteger mutatedSnapshotNumber) headTxOut
    , SomeMutation (pure $ toErrorCode SignatureVerificationFailed) SnapshotNotSignedByAllParties . ChangeInputHeadDatum <$> do
        mutatedParties <- arbitrary `suchThat` (/= healthyOnChainParties)
        pure $
          Head.Open
            { parties = mutatedParties
            , utxoHash = ""
            , snapshotNumber = toInteger healthyCloseSnapshotNumber
            , contestationPeriod = healthyContestationPeriod
            , headId = toPlutusCurrencySymbol Fixture.testPolicyId
            }
    , SomeMutation (pure $ toErrorCode ChangedParameters) MutatePartiesInOutput <$> do
        mutatedParties <- arbitrary `suchThat` (/= healthyOnChainParties)
        pure $ ChangeOutput 0 $ modifyInlineDatum (replaceParties mutatedParties) headTxOut
    , SomeMutation (pure $ toErrorCode ChangedParameters) MutateHeadIdInOutput <$> do
        otherHeadId <- toPlutusCurrencySymbol . headPolicyId <$> arbitrary `suchThat` (/= Fixture.testSeedInput)
        pure $ ChangeOutput 0 $ modifyInlineDatum (replaceHeadId otherHeadId) headTxOut
    , SomeMutation (pure $ toErrorCode SignerIsNotAParticipant) MutateRequiredSigner <$> do
        newSigner <- verificationKeyHash <$> genVerificationKey `suchThat` (/= somePartyCardanoVerificationKey)
        pure $ ChangeRequiredSigners [newSigner]
    , SomeMutation (pure $ toErrorCode NoSigners) MutateNoRequiredSigner <$> do
        pure $ ChangeRequiredSigners []
    , SomeMutation (pure $ toErrorCode TooManySigners) MutateMultipleRequiredSigner <$> do
        otherSigners <- listOf1 (genVerificationKey `suchThat` (/= somePartyCardanoVerificationKey))
        let signerAndOthers = somePartyCardanoVerificationKey : otherSigners
        pure $ ChangeRequiredSigners (verificationKeyHash <$> signerAndOthers)
    , SomeMutation (pure $ toErrorCode SignatureVerificationFailed) MutateCloseUTxOHash . ChangeOutput 0 <$> do
        mutatedUTxOHash <- genHash `suchThat` ((/= healthyCloseUTxOHash) . toBuiltin)
        pure $ modifyInlineDatum (replaceUtxoHash $ toBuiltin mutatedUTxOHash) headTxOut
    , SomeMutation (pure $ toErrorCode IncorrectClosedContestationDeadline) MutateContestationDeadline <$> do
        mutatedDeadline <- genMutatedDeadline
        pure $ ChangeOutput 0 $ modifyInlineDatum (replaceContestationDeadline mutatedDeadline) headTxOut
    , SomeMutation (pure $ toErrorCode ChangedParameters) MutateContestationPeriod <$> do
        mutatedPeriod <- arbitrary
        pure $ ChangeOutput 0 $ modifyInlineDatum (replaceContestationPeriod mutatedPeriod) headTxOut
    , SomeMutation (pure $ toErrorCode InfiniteLowerBound) MutateInfiniteLowerBound . ChangeValidityLowerBound <$> do
        pure TxValidityNoLowerBound
    , SomeMutation (pure $ toErrorCode InfiniteUpperBound) MutateInfiniteUpperBound . ChangeValidityUpperBound <$> do
        pure TxValidityNoUpperBound
    , SomeMutation (pure $ toErrorCode HasBoundedValidityCheckFailed) MutateValidityInterval <$> do
        (lowerSlotNo, upperSlotNo, adjustedContestationDeadline) <- genOversizedTransactionValidity
        pure $
          Changes
            [ ChangeValidityInterval (TxValidityLowerBound lowerSlotNo, TxValidityUpperBound upperSlotNo)
            , ChangeOutput 0 $ modifyInlineDatum (replaceContestationDeadline adjustedContestationDeadline) headTxOut
            ]
    , -- XXX: This is a bit confusing and not giving much value. Maybe we can remove this.
      -- This also seems to be covered by MutateRequiredSigner
      SomeMutation (pure $ toErrorCode SignerIsNotAParticipant) CloseFromDifferentHead <$> do
        otherHeadId <- headPolicyId <$> arbitrary `suchThat` (/= Fixture.testSeedInput)
        pure $
          Changes
            [ ChangeOutput 0 (replacePolicyIdWith Fixture.testPolicyId otherHeadId headTxOut)
            , ChangeInput
                healthyOpenHeadTxIn
                (replacePolicyIdWith Fixture.testPolicyId otherHeadId $ healthyOpenHeadTxOut datum)
                ( Just $
                    toScriptData
                      ( Head.Close
                          { signature =
                              toPlutusSignatures $
                                healthySignature healthyCloseSnapshotNumber
                          }
                      )
                )
            ]
    , SomeMutation (pure $ toErrorCode MintingOrBurningIsForbidden) MutateTokenMintingOrBurning
        <$> (changeMintedTokens tx =<< genMintedOrBurnedValue)
    , SomeMutation (pure $ toErrorCode ContestersNonEmpty) MutateContesters . ChangeOutput 0 <$> do
        mutatedContesters <- listOf1 $ PubKeyHash . toBuiltin <$> genHash
        pure $ headTxOut & modifyInlineDatum (replaceContesters mutatedContesters)
    , SomeMutation (pure $ toErrorCode HeadValueIsNotPreserved) MutateValueInOutput <$> do
        newValue <- genValue
        pure $ ChangeOutput 0 (headTxOut{txOutValue = newValue})
    , SomeMutation (pure $ toErrorCode SignatureVerificationFailed) MutateCloseUTxOHash . ChangeOutput 0 <$> do
        mutatedUTxOHash <- genHash `suchThat` ((/= healthyCloseUTxOToDecommitHash) . toBuiltin)
        pure $ modifyInlineDatum (replaceUtxoToDecommitHash $ toBuiltin mutatedUTxOHash) headTxOut
    ]
 where
  genOversizedTransactionValidity = do
    -- Implicit hypotheses: the slot length is and has always been 1 seconds so we can add slot with seconds
    lowerValidityBound <- arbitrary :: Gen Word64
    upperValidityBound <- choose (lowerValidityBound + fromIntegral healthyContestationPeriodSeconds, maxBound)
    let adjustedContestationDeadline =
          fromMilliSeconds . DiffMilliSeconds $ (healthyContestationPeriodSeconds + fromIntegral upperValidityBound) * 1000
    pure (SlotNo lowerValidityBound, SlotNo upperValidityBound, adjustedContestationDeadline)

  headTxOut = fromJust $ txOuts' tx !!? 0

  datum = toUTxOContext (mkTxOutDatumInline healthyOpenHeadDatum)

data CloseInitialMutation
  = MutateCloseContestationDeadline'
  deriving stock (Generic, Show, Enum, Bounded)

-- | Mutations for the specific case of closing with the intial state.
-- We should probably validate all the mutation to this initial state but at
-- least we keep this regression test as we stumbled upon problems with the following case.
-- The nice thing to do would probably to generate either "normal" healthyCloseTx or
-- or healthyCloseInitialTx and apply all the mutations to it but we didn't manage to do that
-- right away.
genCloseInitialMutation :: (Tx, UTxO) -> Gen SomeMutation
genCloseInitialMutation (tx, _utxo) =
  SomeMutation (pure $ toErrorCode IncorrectClosedContestationDeadline) MutateCloseContestationDeadline' <$> do
    mutatedDeadline <- genMutatedDeadline
    pure $ ChangeOutput 0 $ modifyInlineDatum (replaceContestationDeadline mutatedDeadline) headTxOut
 where
  headTxOut = fromJust $ txOuts' tx !!? 0

-- | Generate not acceptable, but interesting deadlines.
genMutatedDeadline :: Gen POSIXTime
genMutatedDeadline = do
  oneof
    [ valuesAroundZero
    , valuesAroundDeadline
    ]
 where
  valuesAroundZero = arbitrary `suchThat` (/= deadline)

  valuesAroundDeadline = arbitrary `suchThat` (/= 0) <&> (+ deadline)

  deadline = posixFromUTCTime healthyContestationDeadline
