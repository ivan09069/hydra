{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeApplications #-}
{-# OPTIONS_GHC -fno-specialize #-}

module Plutus.MerkleTreeValidator where

import PlutusTx.Prelude

import qualified Ledger.Typed.Scripts as Scripts
import Plutus.MerkleTree (Hash, Proof, member)
import qualified PlutusTx as Plutus

-- | A baseline validator which does nothing but returning 'True'. We use it as
-- baseline to measure the deviation for cost execution of other validators.
data EmptyValidator

instance Scripts.ValidatorTypes EmptyValidator where
  type DatumType EmptyValidator = ()
  type RedeemerType EmptyValidator = ()

emptyValidator :: Scripts.TypedValidator EmptyValidator
emptyValidator =
  Scripts.mkTypedValidator @EmptyValidator
    $$(Plutus.compile [||\() () _ctx -> True||])
    $$(Plutus.compile [||wrap||])
 where
  wrap = Scripts.wrapValidator @() @()

-- | A validator for measuring cost of MT membership validation.
data MerkleTreeValidator

instance Scripts.ValidatorTypes MerkleTreeValidator where
  type DatumType MerkleTreeValidator = ()
  type RedeemerType MerkleTreeValidator = (BuiltinByteString, Hash, Proof)

merkleTreeValidator :: Scripts.TypedValidator MerkleTreeValidator
merkleTreeValidator =
  Scripts.mkTypedValidator @MerkleTreeValidator
    $$( Plutus.compile
          [||
          \() (e, root, proof) _ctx ->
            member e root proof
          ||]
      )
    $$(Plutus.compile [||wrap||])
 where
  wrap = Scripts.wrapValidator @() @(Scripts.RedeemerType MerkleTreeValidator)
