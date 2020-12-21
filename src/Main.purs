module Main where

import BotScript
import BotScriptEnv
import BotScriptParser
import BotScriptVM
import Data.Either
import Prelude

import Data.Foldable (for_)
import Effect (Effect)
import Effect.Console (log, logShow)

ctx = """

title "hello"
x = 3
y = true
state world {
    title true
    title "hello" + " world"
    descr "hello world!"
    delay "20m"
    print "hello again"
    delay "20m"
    order "a song name"
    delay "20m"
    x[2] = "asdf"
    x = 3
    x = -3.5
    x = [1,2,3,4]
    event left (user : "", msg : "^/play") {}
    going world
}
going world
"""

execute ctx = case parse parseScript ctx of
    Right script -> runVM script
    Left err -> log ("error: " <> show err)

-- main = log "Welcome to use BotScript"
main = execute ctx

-- main = case parse parseScript btx of
--     Right script -> logShow script
--     Left err -> log ("error: " <> show err)
