module Hydra.API.HTTPServerSpec where

import Hydra.Prelude hiding (get)
import Test.Hydra.Prelude

import Cardano.Api.UTxO qualified as UTxO
import Control.Lens ((^?))
import Data.Aeson (Result (Error, Success), eitherDecode, encode, fromJSON)
import Data.Aeson qualified as Aeson
import Data.Aeson.Lens (key, nth)
import Data.Text qualified as Text
import Hydra.API.HTTPServer (
  DraftCommitTxRequest (..),
  DraftCommitTxResponse (..),
  SideLoadSnapshotRequest (..),
  SubmitTxRequest (..),
  TransactionSubmitted,
  httpApp,
 )
import Hydra.API.ServerOutput (CommitInfo (CannotCommit, NormalCommit))
import Hydra.API.ServerSpec (dummyChainHandle)
import Hydra.Cardano.Api (
  mkTxOutDatumInline,
  modifyTxOutDatum,
  renderTxIn,
  serialiseToTextEnvelope,
 )
import Hydra.Chain (Chain (draftCommitTx), PostTxError (..), draftDepositTx)
import Hydra.HeadLogic.State (SeenSnapshot (..))
import Hydra.JSONSchema (SchemaSelector, prop_validateJSONSchema, validateJSON, withJsonSpecifications)
import Hydra.Ledger.Cardano (Tx)
import Hydra.Ledger.Simple (SimpleTx)
import Hydra.Logging (nullTracer)
import Hydra.Tx (ConfirmedSnapshot (..))
import Hydra.Tx.IsTx (UTxOType)
import System.FilePath ((</>))
import System.IO.Unsafe (unsafePerformIO)
import Test.Aeson.GenericSpecs (roundtripAndGoldenSpecs)
import Test.Hspec.Wai (MatchBody (..), ResponseMatcher (matchBody), get, post, shouldRespondWith, with)
import Test.Hspec.Wai.Internal (withApplication)
import Test.Hydra.Node.Fixture (testEnvironment)
import Test.Hydra.Tx.Fixture (defaultPParams)
import Test.Hydra.Tx.Gen (genTxOut)
import Test.QuickCheck (
  checkCoverage,
  counterexample,
  cover,
  forAll,
  generate,
  property,
  withMaxSuccess,
 )

spec :: Spec
spec = do
  parallel $ do
    roundtripAndGoldenSpecs (Proxy @(ReasonablySized (DraftCommitTxResponse Tx)))
    roundtripAndGoldenSpecs (Proxy @(ReasonablySized (DraftCommitTxRequest Tx)))
    roundtripAndGoldenSpecs (Proxy @(ReasonablySized (SubmitTxRequest Tx)))
    roundtripAndGoldenSpecs (Proxy @(ReasonablySized TransactionSubmitted))
    roundtripAndGoldenSpecs (Proxy @(ReasonablySized (SideLoadSnapshotRequest Tx)))

    prop "Validate /commit publish api schema" $
      prop_validateJSONSchema @(DraftCommitTxRequest Tx) "api.json" $
        key "components" . key "messages" . key "DraftCommitTxRequest" . key "payload"

    prop "Validate /commit subscribe api schema" $
      prop_validateJSONSchema @(DraftCommitTxResponse Tx) "api.json" $
        key "components" . key "messages" . key "DraftCommitTxResponse" . key "payload"

    prop "Validate /cardano-transaction publish api schema" $
      prop_validateJSONSchema @(SubmitTxRequest Tx) "api.json" $
        key "channels"
          . key "/cardano-transaction"
          . key "publish"
          . key "message"
          . key "payload"

    prop "Validate /cardano-transaction subscribe api schema" $
      prop_validateJSONSchema @TransactionSubmitted "api.json" $
        key "channels"
          . key "/cardano-transaction"
          . key "subscribe"
          . key "message"
          . key "oneOf"
          . nth 0
          . key "payload"

    prop "Validate /decommit publish api schema" $
      prop_validateJSONSchema @Tx "api.json" $
        key "channels"
          . key "/decommit"
          . key "publish"
          . key "message"

    prop "Validate /decommit subscribe api schema" $
      prop_validateJSONSchema @Text "api.json" $
        key "channels"
          . key "/decommit"
          . key "subscribe"
          . key "message"

    prop "Validate /commit publish api schema" $
      prop_validateJSONSchema @Text "api.json" $
        key "channels"
          . key "/commit"
          . key "publish"
          . key "message"

    prop "Validate /commit subscribe api schema" $
      prop_validateJSONSchema @Text "api.json" $
        key "channels"
          . key "/commit"
          . key "subscribe"
          . key "message"

    prop "Validate /commits publish api schema" $
      prop_validateJSONSchema @Text "api.json" $
        key "channels"
          . key "/commits"
          . key "publish"
          . key "message"

    prop "Validate /commits subscribe api schema" $
      prop_validateJSONSchema @Text "api.json" $
        key "channels"
          . key "/commits"
          . key "subscribe"
          . key "message"

    prop "Validate /commits/tx-id publish api schema" $
      prop_validateJSONSchema @Text "api.json" $
        key "channels"
          . key "/commits/tx-id"
          . key "publish"
          . key "message"

    prop "Validate /commits/tx-id subscribe api schema" $
      prop_validateJSONSchema @Text "api.json" $
        key "channels"
          . key "/commits/tx-id"
          . key "subscribe"
          . key "message"

    prop "Validate /snapshot publish api schema" $
      prop_validateJSONSchema @(SideLoadSnapshotRequest Tx) "api.json" $
        key "components" . key "messages" . key "SideLoadSnapshotRequest" . key "payload"

    prop "Validate /snapshot subscribe api schema" $
      prop_validateJSONSchema @(ConfirmedSnapshot Tx) "api.json" $
        key "components" . key "schemas" . key "ConfirmedSnapshot"

    apiServerSpec
    describe "SubmitTxRequest accepted tx formats" $ do
      prop "accepts json encoded transaction" $
        forAll (arbitrary @Tx) $ \tx ->
          let json = toJSON tx
           in case fromJSON @(SubmitTxRequest Tx) json of
                Success{} -> property True
                Error e -> counterexample (toString $ toText e) $ property False
      prop "accepts transaction encoded as TextEnvelope" $
        forAll (arbitrary @Tx) $ \tx ->
          let json = toJSON $ serialiseToTextEnvelope Nothing tx
           in case fromJSON @(SubmitTxRequest Tx) json of
                Success{} -> property True
                Error e -> counterexample (toString $ toText e) $ property False

apiServerSpec :: Spec
apiServerSpec = do
  describe "API should respond correctly" $ do
    let getNothing = pure Nothing
        cantCommit = pure CannotCommit
        getPendingDeposits = pure []
        putClientInput = const (pure ())
        getNoSeenSnapshot = pure NoSeenSnapshot

    describe "GET /protocol-parameters" $ do
      with
        ( return $
            httpApp @SimpleTx
              nullTracer
              dummyChainHandle
              testEnvironment
              defaultPParams
              cantCommit
              getNothing
              getNoSeenSnapshot
              getNothing
              getPendingDeposits
              putClientInput
        )
        $ do
          it "matches schema" $
            withJsonSpecifications $ \schemaDir -> do
              get "/protocol-parameters"
                `shouldRespondWith` 200
                  { matchBody =
                      matchValidJSON
                        (schemaDir </> "api.json")
                        (key "components" . key "messages" . key "ProtocolParameters" . key "payload")
                  }
          it "responds given parameters" $
            get "/protocol-parameters"
              `shouldRespondWith` 200
                { matchBody = matchJSON defaultPParams
                }

    describe "GET /snapshot/last-seen" $ do
      prop "responds correctly" $ \seenSnapshot -> do
        let getSeenSnapshot = pure seenSnapshot
        withApplication
          ( httpApp @SimpleTx
              nullTracer
              dummyChainHandle
              testEnvironment
              defaultPParams
              cantCommit
              getNothing
              getSeenSnapshot
              getNothing
              getPendingDeposits
              putClientInput
          )
          $ do
            get "/snapshot/last-seen"
              `shouldRespondWith` 200{matchBody = matchJSON seenSnapshot}

    describe "GET /snapshot" $ do
      prop "responds correctly" $ \confirmedSnapshot -> do
        let getConfirmedSnapshot = pure confirmedSnapshot
        withApplication (httpApp @SimpleTx nullTracer dummyChainHandle testEnvironment defaultPParams cantCommit getNothing getNoSeenSnapshot getConfirmedSnapshot getPendingDeposits putClientInput) $ do
          get "/snapshot"
            `shouldRespondWith` case confirmedSnapshot of
              Nothing -> 404
              Just s -> 200{matchBody = matchJSON s}

      prop "ok response matches schema" $ \(confirmedSnapshot :: ConfirmedSnapshot Tx) ->
        withMaxSuccess 4
          . withJsonSpecifications
          $ \schemaDir -> do
            let getConfirmedSnapshot = pure $ Just confirmedSnapshot
            withApplication (httpApp @Tx nullTracer dummyChainHandle testEnvironment defaultPParams cantCommit getNothing getNoSeenSnapshot getConfirmedSnapshot getPendingDeposits putClientInput) $ do
              get "/snapshot"
                `shouldRespondWith` 200
                  { matchBody =
                      matchValidJSON
                        (schemaDir </> "api.json")
                        (key "channels" . key "/snapshot" . key "subscribe" . key "message" . key "payload")
                  }

    describe "POST /snapshot" $ do
      prop "responds on valid requests" $ \(request :: SideLoadSnapshotRequest Tx) ->
        withApplication (httpApp @Tx nullTracer dummyChainHandle testEnvironment defaultPParams cantCommit getNothing getNoSeenSnapshot getNothing getPendingDeposits putClientInput) $
          do
            post "/snapshot" (Aeson.encode request)
            `shouldRespondWith` 200

    describe "GET /snapshot/utxo" $ do
      prop "responds correctly" $ \utxo -> do
        let getUTxO = pure utxo
        withApplication
          ( httpApp @SimpleTx
              nullTracer
              dummyChainHandle
              testEnvironment
              defaultPParams
              cantCommit
              getUTxO
              getNoSeenSnapshot
              getNothing
              getPendingDeposits
              putClientInput
          )
          $ do
            get "/snapshot/utxo"
              `shouldRespondWith` case utxo of
                Nothing -> 404
                Just u -> 200{matchBody = matchJSON u}

      prop "ok response matches schema" $ \(utxo :: UTxOType Tx) ->
        withMaxSuccess 4
          . cover 1 (null utxo) "empty"
          . cover 1 (not $ null utxo) "non empty"
          . withJsonSpecifications
          $ \schemaDir -> do
            let getUTxO = pure $ Just utxo
            withApplication
              ( httpApp @Tx
                  nullTracer
                  dummyChainHandle
                  testEnvironment
                  defaultPParams
                  cantCommit
                  getUTxO
                  getNoSeenSnapshot
                  getNothing
                  getPendingDeposits
                  putClientInput
              )
              $ do
                get "/snapshot/utxo"
                  `shouldRespondWith` 200
                    { matchBody =
                        matchValidJSON
                          (schemaDir </> "api.json")
                          (key "channels" . key "/snapshot/utxo" . key "subscribe" . key "message" . key "payload")
                    }

      prop "has inlineDatumRaw" $ \i ->
        forAll genTxOut $ \o -> do
          let o' = modifyTxOutDatum (const $ mkTxOutDatumInline (123 :: Integer)) o
          let getUTxO = pure $ Just $ UTxO.fromPairs [(i, o')]
          withApplication
            ( httpApp @Tx
                nullTracer
                dummyChainHandle
                testEnvironment
                defaultPParams
                cantCommit
                getUTxO
                getNoSeenSnapshot
                getNothing
                getPendingDeposits
                putClientInput
            )
            $ do
              get "/snapshot/utxo"
                `shouldRespondWith` 200
                  { matchBody = MatchBody $ \_ body ->
                      if isNothing (body ^? key (fromString $ Text.unpack $ renderTxIn i) . key "inlineDatumRaw")
                        then Just $ "\ninlineDatumRaw not found in body:\n" <> show body
                        else Nothing
                  }

    describe "POST /commit" $ do
      let getHeadId = pure $ NormalCommit (generateWith arbitrary 42)
      let workingChainHandle =
            dummyChainHandle
              { draftCommitTx = \_ _ -> do
                  tx <- generate $ arbitrary @Tx
                  pure $ Right tx
              }
      prop "responds on valid requests" $ \(request :: DraftCommitTxRequest Tx) ->
        withApplication
          ( httpApp
              nullTracer
              workingChainHandle
              testEnvironment
              defaultPParams
              getHeadId
              getNothing
              getNoSeenSnapshot
              getNothing
              getPendingDeposits
              putClientInput
          )
          $ do
            post "/commit" (Aeson.encode request)
              `shouldRespondWith` 200

      let failingChainHandle postTxError =
            dummyChainHandle
              { draftCommitTx = \_ _ -> pure $ Left postTxError
              , draftDepositTx = \_ _ _ -> pure $ Left postTxError
              }
      prop "handles PostTxErrors accordingly" $ \request postTxError -> do
        let expectedResponse =
              case postTxError of
                CommittedTooMuchADAForMainnet{} -> 400
                UnsupportedLegacyOutput{} -> 400
                CannotFindOwnInitial{} -> 400
                _ -> 500
        let coverage = case postTxError of
              CommittedTooMuchADAForMainnet{} -> cover 1 True "CommittedTooMuchADAForMainnet"
              UnsupportedLegacyOutput{} -> cover 1 True "UnsupportedLegacyOutput"
              InvalidHeadId{} -> cover 1 True "InvalidHeadId"
              CannotFindOwnInitial{} -> cover 1 True "CannotFindOwnInitial"
              _ -> property
        checkCoverage
          $ coverage
          $ withApplication
            ( httpApp @Tx
                nullTracer
                (failingChainHandle postTxError)
                testEnvironment
                defaultPParams
                getHeadId
                getNothing
                getNoSeenSnapshot
                getNothing
                getPendingDeposits
                putClientInput
            )
          $ do
            post "/commit" (Aeson.encode (request :: DraftCommitTxRequest Tx))
              `shouldRespondWith` expectedResponse

-- * Helpers

-- | Create a 'ResponseMatcher' or 'MatchBody' from a JSON serializable value
-- (using their 'IsString' instances).
matchJSON :: (IsString s, ToJSON a) => a -> s
matchJSON = fromString . decodeUtf8 . encode

-- | Create a 'MatchBody' that validates the returned JSON response against a
-- schema. NOTE: This raises impure exceptions, so only use it in this test
-- suite.
matchValidJSON :: FilePath -> SchemaSelector -> MatchBody
matchValidJSON schemaFile selector =
  MatchBody $ \_headers body ->
    case eitherDecode body of
      Left err -> Just $ "failed to decode body: " <> err
      Right value -> validateJSONPure value
 where
  -- NOTE: Uses unsafePerformIO to create a pure API although we are actually
  -- calling an external program to verify the schema. This is fine, because the
  -- call is referentially transparent and any given invocation of schema file,
  -- selector and value will always yield the same result and can be shared.
  validateJSONPure value =
    unsafePerformIO $ do
      validateJSON schemaFile selector value
      pure Nothing
