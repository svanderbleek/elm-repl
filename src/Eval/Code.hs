{-# LANGUAGE OverloadedStrings #-}
module Eval.Code (eval) where

import Control.Monad.Cont (ContT(ContT, runContT))
import Control.Monad.RWS (get, modify)
import Control.Monad.Trans (liftIO)
import qualified Data.ByteString.Char8 as BSC
import qualified Data.ByteString as BS
import qualified Data.Char as Char
import System.Directory (doesFileExist, removeFile)
import System.FilePath ((<.>), replaceExtension)
import System.IO (hPutStrLn, stderr, stdout)

import qualified Environment as Env
import qualified Eval.Command as Eval
import qualified Input
import qualified Elm.Utils as Utils


eval :: (Maybe Input.DefName, String) -> Eval.Command ()
eval code =
 do modify $ Env.insert code 
    env <- get
    liftIO $ writeFile tempElmPath (Env.toElmCode env)
    liftIO . runConts $ do
        types <- runCmd (Env.compilerPath env) (Env.flags env ++ elmArgs)
        liftIO $ reformatJS tempJsPath
        value <- runCmd (Env.interpreterPath env) [tempJsPath]
        liftIO $ printIfNeeded value (scrapeOutputType types)
    liftIO $ removeIfExists tempElmPath
    return ()
  where
    runConts m = runContT m (\_ -> return ())
    
    tempElmPath =
        "repl-temp-000" <.> "elm"

    tempJsPath =
        replaceExtension tempElmPath "js"
    
    elmArgs =
        [ tempElmPath
        , "--output=" ++ tempJsPath
        ]

printIfNeeded :: BS.ByteString -> BS.ByteString -> IO ()
printIfNeeded rawValue tipe =
    if BSC.null rawValue
      then return ()
      else BSC.hPutStrLn stdout rawValue {-- message
  where
    value = BSC.init rawValue

    isTooLong =
        BSC.isInfixOf "\n" value
        || BSC.isInfixOf "\n" tipe
        || BSC.length value + BSC.length tipe > 80

    message =
        BS.concat
            [ if isTooLong then rawValue else value
            , tipe
            ]
--}

runCmd :: FilePath -> [String] -> ContT () IO BS.ByteString
runCmd name args = ContT $ \ret ->
  do  result <- liftIO (Utils.unwrappedRun name args)
      case result of
        Right stdout ->
            ret (BSC.pack stdout)

        Left (Utils.MissingExe msg) ->
            liftIO $ hPutStrLn stderr msg

        Left (Utils.CommandFailed (out,err)) ->
            liftIO $ hPutStrLn stderr (out ++ err)


reformatJS :: String -> IO ()
reformatJS tempJsPath =
    BS.appendFile tempJsPath out
  where
    out =
        BS.concat
            [ "process.on('uncaughtException', function(err) {\n"
            , "  process.stderr.write(err.toString());\n"
            , "  process.exit(1);\n"
            , "});\n"
            , "var document = document || {};"
            , "var window = window || {};"
            , "var context = { inputs:[], addListener:function(){}, node:{} };\n"
            , "var repl = Elm.Repl.make(context);\n"
            , "var toString = Elm.Native.Show.make(context).toString;"
            , "if ('", Env.lastVar, "' in repl)\n"
            , "  console.log(toString(repl.", Env.lastVar, "));"
            ]


scrapeOutputType :: BS.ByteString -> BS.ByteString
scrapeOutputType rawTypeDump =
    dropName (squashSpace relevantLines)
  where
    squashSpace :: [BS.ByteString] -> BS.ByteString
    squashSpace multiLineTypeDecl =
        BSC.unwords (BSC.words (BSC.unwords multiLineTypeDecl))

    dropName :: BS.ByteString -> BS.ByteString
    dropName typeDecl =
        BSC.cons ' ' (BSC.dropWhile (/= ':') typeDecl)

    relevantLines :: [BS.ByteString]
    relevantLines =
        takeType . dropWhile (not . isLastVar) $ BSC.lines rawTypeDump

    isLastVar :: BS.ByteString -> Bool
    isLastVar line =
        BS.isPrefixOf Env.lastVar line
        || BS.isPrefixOf (BS.append "Repl." Env.lastVar) line

    takeType :: [BS.ByteString] -> [BS.ByteString]
    takeType lines =
        case lines of
          [] -> error errorMessage
          line : rest ->
              line : takeWhile isMoreType rest

    isMoreType :: BS.ByteString -> Bool
    isMoreType line =
        not (BS.null line)
        && Char.isSpace (BSC.head line)

    errorMessage =
        "Internal error in elm-repl function scrapeOutputType\n\
        \Please report this bug to <https://github.com/elm-lang/elm-repl/issues>"


removeIfExists :: FilePath -> IO ()
removeIfExists fileName =
    do  exists <- doesFileExist fileName
        if exists
          then removeFile fileName
          else return ()