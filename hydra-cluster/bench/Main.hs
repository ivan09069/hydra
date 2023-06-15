module Main where

import Hydra.Prelude
import Test.Hydra.Prelude

import Bench.EndToEnd (Summary (..), bench)
import Data.Aeson (eitherDecodeFileStrict', encodeFile)
import Hydra.Cardano.Api (
  ShelleyBasedEra (..),
  ShelleyGenesis (..),
  fromLedgerPParams,
 )
import Hydra.Generator (generateConstantUTxODataset)
import Options.Applicative (
  Parser,
  ParserInfo,
  auto,
  execParser,
  fullDesc,
  header,
  help,
  helper,
  info,
  long,
  metavar,
  option,
  progDesc,
  strOption,
  value,
 )
import System.Directory (createDirectory, doesDirectoryExist)
import System.Environment (withArgs)
import System.FilePath ((</>))
import Test.HUnit.Lang (HUnitFailure (..), formatFailureReason)
import Test.QuickCheck (generate, getSize, scale)

data Options = Options
  { workDirectory :: Maybe FilePath
  , scalingFactor :: Int
  , timeoutSeconds :: DiffTime
  , clusterSize :: Word64
  }

benchOptionsParser :: Parser Options
benchOptionsParser =
  Options
    <$> optional
      ( strOption
          ( long "work-directory"
              <> help
                "Directory containing generated transactions, UTxO set, log files for spawned processes, etc. \
                \ * If the directory exists, it's assumed to be used for replaying \
                \   a previous benchmark and is expected to contain 'txs.json' and \
                \   'utxo.json' files, \
                \ * If the directory does not exist, it will be created and \
                \   populated with new transactions and UTxO set."
          )
      )
    <*> option
      auto
      ( long "scaling-factor"
          <> value 100
          <> metavar "INT"
          <> help "The scaling factor to apply to transactions generator (default: 100)"
      )
    <*> option
      auto
      ( long "timeout"
          <> value 600.0
          <> metavar "SECONDS"
          <> help
            "The timeout for the run, in seconds (default: '600s')"
      )
    <*> option
      auto
      ( long "cluster-size"
          <> value 3
          <> metavar "INT"
          <> help
            "The number of Hydra nodes to start and connect (default: 3)"
      )

benchOptions :: ParserInfo Options
benchOptions =
  info
    (benchOptionsParser <**> helper)
    ( fullDesc
        <> progDesc
          "Starts a cluster of Hydra nodes interconnected through a network and \
          \talking to a local cardano devnet, generates an initial UTxO set and a bunch \
          \of valid transactions, and send those transactions to the cluster as \
          \fast as possible.\n \
          \Arguments can control various parameters of the run, like number of nodes, \
          \and number of transactions generated"
        <> header "bench - load tester for Hydra node cluster"
    )

main :: IO ()
main =
  execParser benchOptions >>= \case
    o@Options{workDirectory = Just benchDir} -> do
      existsDir <- doesDirectoryExist benchDir
      if existsDir
        then replay o benchDir
        else createDirectory benchDir >> play o benchDir
    o ->
      createSystemTempDirectory "bench" >>= play o
 where
  play Options{scalingFactor, timeoutSeconds, clusterSize} benchDir = do
    numberOfTxs <- generate $ scale (* scalingFactor) getSize
    pparams <-
      eitherDecodeFileStrict' ("config" </> "devnet" </> "genesis-shelley.json") >>= \case
        Left err -> fail $ show err
        Right shelleyGenesis ->
          pure $ fromLedgerPParams ShelleyBasedEraShelley (sgProtocolParams shelleyGenesis)
    dataset <- generateConstantUTxODataset pparams (fromIntegral clusterSize) numberOfTxs
    saveDataset benchDir dataset
    run timeoutSeconds benchDir dataset clusterSize

  replay Options{timeoutSeconds, clusterSize} benchDir = do
    datasets <- either die pure =<< eitherDecodeFileStrict' (benchDir </> "dataset.json")
    putStrLn $ "Using UTxO and Transactions from: " <> benchDir
    run timeoutSeconds benchDir datasets clusterSize

  run timeoutSeconds benchDir datasets clusterSize = do
    putStrLn $ "Test logs available in: " <> (benchDir </> "test.log")
    withArgs [] $
      try (bench timeoutSeconds benchDir datasets clusterSize) >>= \case
        Left (err :: HUnitFailure) ->
          benchmarkFailedWith benchDir err
        Right summary ->
          benchmarkSucceeded benchDir summary

  saveDataset tmpDir dataset = do
    let txsFile = tmpDir </> "dataset.json"
    putStrLn $ "Writing dataset to: " <> txsFile
    encodeFile txsFile dataset

benchmarkFailedWith :: FilePath -> HUnitFailure -> IO ()
benchmarkFailedWith benchDir (HUnitFailure _ reason) = do
  putStrLn $ "Benchmark failed: " <> formatFailureReason reason
  putStrLn $ "To re-run with same dataset, pass '--work-directory=" <> benchDir <> "' to the executable"
  exitFailure

benchmarkSucceeded :: FilePath -> Summary -> IO ()
benchmarkSucceeded _ Summary{numberOfTxs, averageConfirmationTime, percentBelow100ms} = do
  putTextLn $ "Confirmed txs: " <> show numberOfTxs
  putTextLn $ "Average confirmation time (ms): " <> show averageConfirmationTime
  putTextLn $ "Confirmed below 100ms: " <> show percentBelow100ms <> "%"
