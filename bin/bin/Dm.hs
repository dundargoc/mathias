#!/usr/bin/env stack
{- stack script --optimize --resolver lts-21.15
 --package "aeson process bytestring regex-pcre text either utf8-string containers split"
 --package "http-client http-client-tls directory unix raw-strings-qq"
-}

{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE GHC2021 #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE OverloadedRecordDot #-}

module Main where


import Data.Aeson
  ( FromJSON,
    decode,
    eitherDecode
  )
import qualified Data.ByteString.Lazy as BL
import qualified Data.ByteString.Lazy.UTF8 as BL
import Data.Char (isSpace)
import Data.Foldable (for_, find)
import Data.List (findIndex, isInfixOf, foldl')
import qualified Data.Map.Strict as M
import Data.Maybe
  ( catMaybes,
    fromJust,
    fromMaybe,
    mapMaybe,
    listToMaybe
  )
import GHC.Generics (Generic)
import qualified Network.HTTP.Client as HTTP
import qualified Network.HTTP.Client.TLS as HTTP
import System.Directory
  ( canonicalizePath,
    doesFileExist,
    getHomeDirectory, removeFile
  )
import System.Environment (getArgs)
import System.Posix.Files (rename)
import System.Process (callProcess, readProcess, callCommand, shell, readCreateProcess)
import Control.Monad (when, unless)
import Text.Regex.PCRE ((=~))
import Text.RawString.QQ
import qualified Data.Text as T
import qualified Data.Text.Read as T
import Data.Either.Combinators (rightToMaybe)
import Text.Printf (printf)
import Control.Exception (catch, throwIO)
import System.IO.Error (isDoesNotExistError)
import Data.List.Split (wordsBy)


data SwayOutput = SwayOutput
  { id :: Maybe Int,
    name :: T.Text,
    active :: Bool,
    focused :: Maybe Bool
  }
  deriving (Eq, Show, Generic)

instance FromJSON SwayOutput


class ToString a where
  str :: a -> String

instance ToString T.Text where
  str = T.unpack

instance ToString String where
  str = Prelude.id


getOutputs :: IO [SwayOutput]
getOutputs = do
  outputs <- readProcess "swaymsg" ["-r", "-t", "get_outputs"] ""
  let
    swayOutputs :: Either String [SwayOutput]
    swayOutputs = eitherDecode (BL.fromString outputs)
  case swayOutputs of
    Left err -> error $ "Couldn't decode output of swaymsg -t get_outputs:" <> err
    Right outputs' -> pure outputs'


selection :: [String] -> IO String
selection input = do
  args <- getArgs
  let
    runTool tool args = trim <$> readProcess tool args (unlines input)
    tool = case args of
      [arg] -> arg
      _ -> "bemenu"
  if tool == "bemenu"
    then do
      idx <- getDisplayIdx
      runTool "bemenu" ["-m", show idx, "-l", "30", "--fn", "JuliaMono 16"]
    else runTool tool []
  where
    getDisplayIdx :: IO Int
    getDisplayIdx = do
      outputs <- getOutputs
      pure $ fromMaybe 0 (findIndex (fromMaybe False . focused) . reverse $ outputs)


pickOne :: ToString b => [a] -> (a -> b) -> IO (Maybe a)
pickOne xs formatX = do
  selected <- selection formattedXs
  case T.splitOn "│ " (T.pack selected) of
    (idx : _) -> pure . fmap (xs !!) . rightToMaybe $ fst <$> T.decimal idx
    _         -> pure Nothing
  where
    formattedXs = fmap renderX (zip [(0 :: Int)..] xs)
    numDigits = ceiling . logBase 10 . fromIntegral $ length xs
    formatStr = "%0" <> show numDigits <> "d│ %s"
    renderX (idx, x) = printf formatStr idx (str $ formatX x)



trim :: String -> String
trim = f . f
  where f = reverse . dropWhile isSpace


keyboard :: IO ()
keyboard = do
  xset ["r", "rate", "200", "40"]
  callProcess "setxkbmap" [
      "-layout", "de",
      "-variant", "nodeadkeys",
      "-option", "caps:escape"
      ]


barMode :: String -> IO ()
barMode mode = callProcess "swaymsg" (["bar", "mode"] ++ [mode])


xrandrOn :: IO ()
xrandrOn = do
  outputs <- getOutputs
  case filter (not . active) outputs of
    []       -> putStrLn "No inactive output"
    [output] -> activate output
    outputs' -> pickOne outputs' name >>= maybeActivate
  where
    maybeActivate (Just output) = activate output
    maybeActivate Nothing = pure ()
    activate :: SwayOutput -> IO ()
    activate output = callProcess "swaymsg" ["output", T.unpack $ name output, "enable"]


xrandrOff :: IO ()
xrandrOff = do
  outputs <- getOutputs
  case filter active outputs of
    []       -> putStrLn "No active output"
    [output] -> disable output
    outputs'  -> pickOne outputs' name >>= maybeDisable
  where
    disable :: SwayOutput -> IO ()
    disable output = callProcess "swaymsg" ["output", T.unpack $ name output, "disable"]
    maybeDisable :: Maybe SwayOutput -> IO ()
    maybeDisable (Just output) = disable output
    maybeDisable _ = pure ()


xset :: [String] -> IO ()
xset = callProcess "xset"


presOff :: IO ()
presOff = do
  callProcess "systemctl" ["--user", "start", "swayidle.service"]
  changeVimBackground "light" "dark"
  alacrittyConfig <- expandUser "~/.config/alacritty/alacritty.yml" >>= canonicalizePath
  sed alacrittyConfig "colors: *light" "colors: *dark"
  sed alacrittyConfig "    family: JetBrains Mono" "    family: JetBrains Mono Light"


presOn :: IO ()
presOn = do
  callProcess "systemctl" ["--user", "stop", "swayidle.service"]
  changeVimBackground "dark" "light"
  alacrittyConfig <- expandUser "~/.config/alacritty/alacritty.yml" >>= canonicalizePath
  sed alacrittyConfig "colors: *dark" "colors: *light"
  sed alacrittyConfig "    family: JetBrains Mono Light" "    family: JetBrains Mono"


sed :: FilePath -> String -> String -> IO ()
sed filepath target replacement =  do
  let
    tmpFile = filepath ++ ".tmp"
  contents <- lines <$> readFile filepath
  writeFile tmpFile (unlines (map (maybeReplace target replacement) contents))
  rename tmpFile filepath
  where
    maybeReplace target replacement line = if line == target then replacement else line


expandUser :: FilePath -> IO FilePath
expandUser ('~' : xs) = do
  homeDir <- getHomeDirectory
  pure $ homeDir ++ xs
expandUser xs = pure xs


changeVimBackground :: String -> String -> IO ()
changeVimBackground from to = do
  vimrc <- expandUser "~/.config/nvim/options.vim" >>= canonicalizePath
  sed vimrc ("set background=" ++ from) ("set background=" ++ to)
  instances <- lines <$> readProcess "nvr" ["--serverlist"] ""
  let changeColor = "<Esc>:set background=" ++ to ++ "<CR>"
  for_ instances $ \x ->
    when (take 3 x /= "127") $
      callProcess "nvr" ["--nostart", "--servername", x, "--remote-send", changeColor]


callContacts :: IO ()
callContacts = do
  contactsPath <- expandUser "~/.config/dm/contacts.json"
  contents <- BL.readFile contactsPath
  let
    contacts = fromMaybe M.empty (decode contents :: Maybe (M.Map String String))
  choice <- selection $ M.keys contacts
  callProcess "xdg-open" [fromJust $ M.lookup choice contacts]


fromUriOrCache :: String -> String -> IO BL.ByteString
fromUriOrCache cachePath source = do
  resolvedPath <- expandUser cachePath
  fileExists <- doesFileExist resolvedPath
  if fileExists
    then BL.readFile resolvedPath
    else do
      manager <- HTTP.newManager HTTP.tlsManagerSettings
      req <- HTTP.parseRequest source
      content <- HTTP.responseBody <$> HTTP.httpLbs req manager
      BL.writeFile resolvedPath content
      pure content


data Emoji = Emoji
  { emoji :: String
  , description :: String }
  deriving (Show, Generic, FromJSON)


selectEmoji :: IO ()
selectEmoji = do
  emojiFileContents <- fromUriOrCache cachePath source
  let
    emojis = catMaybes <$> (eitherDecode emojiFileContents :: Either String [Maybe Emoji])
  case emojis of
    (Left err)-> error $ "Couldn't decode " <> cachePath <> ": " <> err
    (Right emojis') -> do
      selected <- pickOne emojis' (\e -> emoji e <> " " <> description e)
      for_ selected $ \s -> do
        putStrLn s.emoji
        callProcess "wl-copy" [s.emoji]

  where
    source = "https://raw.githubusercontent.com/github/gemoji/master/db/emoji.json"
    cachePath = "~/.config/dm/emoji.json"


selectSong :: IO ()
selectSong = do
  song <- showPlaylist >>= selection
  callProcess "mpc" ["play", songNr song]
  where
    showPlaylist = lines <$> readProcess "mpc" ["playlist", "-f", "%position% ¦ %artist% - %title%"] ""
    songNr = reverse . drop 1 . reverse . takeWhile (/= '¦')


data SinkInput = SinkInput
  { inputNumber :: Int,
    inputSinkNumber :: Int,
    inputAppName :: T.Text
  }
  deriving (Eq, Show)


data Sink = Sink
  { sinkNumber :: Int,
    sinkName :: T.Text,
    sinkDescription :: T.Text,
    sinkVolume :: Int
  }
  deriving (Eq, Show)


-- >>> parseSinkInputs "Sink Input #135\nGarbage\n      application.name = \"Music Player Daemon\""
-- []
parseSinkInputs :: String -> [SinkInput]
parseSinkInputs text = mapMaybe mkSinkInput inputs
  where
    inputs = wordsBy (== "") (lines text)
    mkSinkInput :: [String] -> Maybe SinkInput
    mkSinkInput lines = do
      inputNumber <- get "Sink Input #" >>= decimal
      inputAppName <- T.replace "\"" "" <$> get "application.name = "
      sinkNumber <- get "Sink: " >>= decimal
      Just $
        SinkInput
          { inputNumber = inputNumber,
            inputAppName = inputAppName,
            inputSinkNumber = sinkNumber
          }
      where
        decimal x = fst <$> rightToMaybe (T.decimal x)
        lines' = fmap T.pack lines
        get prefix = listToMaybe $ mapMaybe (T.stripPrefix prefix . T.strip) lines'


-- >>> parseSink "Sink #61\n    State: SUSPENDED\n    Name: alsa_output\n    Description: Foo"
-- [Sink {sinkNumber = 61, sinkName = "alsa_output", sinkDescription = "Foo"}]
parseSink :: String -> [Sink]
parseSink text = mapMaybe mkSink (wordsBy (== "") (lines text))
  where
    mkSink :: [String] -> Maybe Sink
    mkSink lines = do
      sinkNumber <- get "Sink #"
      sinkName <- get "Name: "
      sinkDescription <- get "Description: "
      volumeOutput <- T.unpack <$> get "Volume: "
      let pattern :: String
          pattern = [r|.*/ +(\d{1,3})% /.*|]
          [[_, volumeText]] = volumeOutput =~ pattern :: [[String]]
          volume :: Int
          volume = read volumeText

      Just $
        Sink
          { sinkNumber = read $ T.unpack sinkNumber,
            sinkName = sinkName,
            sinkDescription = sinkDescription,
            sinkVolume = volume
          }
      where
        lines' = fmap T.pack lines
        get prefix = listToMaybe $ mapMaybe (T.stripPrefix prefix . T.strip) lines'


pulseMove :: IO ()
pulseMove = do
  inputs <- parseSinkInputs <$> listInputs
  sinks <- parseSink <$> listSinks
  Just sinkInput <- pickOne inputs (formatInput sinks)
  if length sinks == 2
    then
      let inactiveSink = find ((/= sinkInput.inputSinkNumber) . sinkNumber) sinks
      in  for_ inactiveSink (moveSink sinkInput)
    else do
      sink <- listSinks >>= flip pickOne sinkDescription . parseSink
      for_ sink (moveSink sinkInput)
  where
    listInputs = readProcess "pactl" ["list", "sink-inputs"] ""
    listSinks = readProcess "pactl" ["list", "sinks"] ""
    moveSink src dst = callProcess "pactl" ["move-sink-input", show (inputNumber src), T.unpack (sinkName dst)]
    formatInput sinks input = inputAppName input <> maybe "" desc (find sinkMatches sinks)
      where
        sinkMatches sink = sinkNumber sink == inputSinkNumber input
        desc sink = " (" <> sinkDescription sink <> ")"


setVolume :: IO ()
setVolume = do
  sinks <- parseSink <$> readProcess "pactl" ["list", "sinks"] ""
  (Just sink) <- pickOne sinks sinkDescription
  promptVolume (T.unpack sink.sinkName) sink.sinkVolume
  where
    promptVolume :: String -> Int -> IO ()
    promptVolume sinkName sinkVolume = do
      let volume = show sinkVolume
      newVolume <- selection [volume]
      callProcess "pactl" ["set-sink-volume", sinkName, newVolume <> "%"]
      promptVolume sinkName (read newVolume)


removeIfExists :: FilePath -> IO ()
removeIfExists path = removeFile path `catch` handleExists
  where
    handleExists e
      | isDoesNotExistError e = pure ()
      | otherwise = throwIO e


wfRecord :: String -> IO ()
wfRecord slurpCmd = do
  removeIfExists filePath
  window <- readProcess slurpCmd [] ""
  callProcess
    "systemd-run"
    [ "--user",
      "-u", "record",
      "wf-recorder",
      "-c", "hevc_vaapi",
      "-d", "/dev/dri/renderD128",
      "-g", window,
      "-f", filePath
    ]
  callProcess "pkill" ["-SIGUSR1", "i3status-rs"]
  where
    filePath = "/tmp/recording.mp4"

stopRecording :: IO ()
stopRecording = do
  callProcess "systemctl" ["--user", "kill", "-s", "SIGINT", "record.service"]
  callProcess "pkill" ["-SIGUSR1", "i3status-rs"]
  callCommand $ "wl-copy < " <> filePath
  where
    filePath = "/tmp/recording.mp4"

grim :: String -> IO ()
grim slurpCmd = do
  removeIfExists filePath
  window <- readProcess slurpCmd [] ""
  callProcess "grim" ["-g", window, filePath]
  callCommand $ "wl-copy < " <> filePath
  where
    filePath = "/tmp/screenshot.png"

pickColor :: IO ()
pickColor = do
  out <- readCreateProcess (shell grimCmd) ""
  let [_, lastLine] = lines out
      colorCode = T.unpack $ T.splitOn " " (T.pack lastLine) !! 3
  callProcess "wl-copy" [colorCode]
  putStrLn colorCode
  where
    grimCmd = "grim -g \"$(slurp -p)\" -t ppm - | convert - -format '%[pixel:p{0,0}]' txt:-"


main :: IO ()
main = do
  let choices :: [(String, IO ())]
      choices =
        [ ("keyboard", keyboard),
          ("bar invisible", barMode "invisible"),
          ("bar dock", barMode "dock"),
          ("xrandr off", xrandrOff),
          ("xrandr on", xrandrOn),
          ("pres on", presOn),
          ("pres off", presOff),
          ("call", callContacts),
          ("emoji", selectEmoji),
          ("mpc", selectSong),
          ("pa move", pulseMove),
          ("pa volume", setVolume),
          ("record window", wfRecord "slurp-win"),
          ("record region", wfRecord "slurp"),
          ("stop recording", stopRecording),
          ("screenshot window", grim "slurp-win"),
          ("pick color", pickColor)
        ]
  choice <- pickOne choices fst
  case choice of
    Nothing -> putStrLn "Invalid selection"
    Just (_, action) -> action
