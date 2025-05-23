module Hydra.API.ClientInputSpec where

import Hydra.Prelude
import Test.Hydra.Prelude

import Data.Aeson (Result (..), fromJSON)
import Data.Aeson.Lens (key)
import Hydra.API.ClientInput (ClientInput)
import Hydra.Cardano.Api (serialiseToTextEnvelope)
import Hydra.JSONSchema (prop_specIsComplete)
import Hydra.Ledger.Cardano (Tx)
import Test.Aeson.GenericSpecs (
  Settings (..),
  defaultSettings,
  roundtripAndGoldenADTSpecsWithSettings,
 )
import Test.QuickCheck (counterexample, forAll, property)

spec :: Spec
spec = parallel $ do
  roundtripAndGoldenADTSpecsWithSettings defaultSettings{sampleSize = 1} $ Proxy @(MinimumSized (ClientInput Tx))

  -- XXX: Should move these to websocket server tests
  prop "schema covers all defined client inputs" $
    prop_specIsComplete @(ClientInput Tx) "api.json" $
      key "channels" . key "/" . key "publish" . key "message"

  describe "FromJSON (ValidatedTx era)" $ do
    prop "accepts transactions produced via cardano-cli" $
      forAll (arbitrary @Tx) $ \tx ->
        let envelope = toJSON $ serialiseToTextEnvelope (Just "Tx Babbage") tx
         in case fromJSON @Tx envelope of
              Success{} -> property True
              Error e -> counterexample (toString $ toText e) $ property False
