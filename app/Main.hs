{-# LANGUAGE LambdaCase, OverloadedStrings, ViewPatterns #-}
{-# OPTIONS_GHC -Wall -Werror -Wno-type-defaults #-}

{-
TODO:
Presently all the code is here, in this file. We need to properly organize the code into modules.
This file can be the only file in the "app" directory.
Under "src", there will be a number of distinct files/modules:
* One module should contain all our data type declarations and type aliases. Doing this helps to avoid circular imports in large apps.
* Other modules can be created based on theme. For example, one module might contain "Text" utility functions.
* You'll probably want to put "threadServer" and the functions it calls ("interp") in a single module.
Modules should only export the functions that other modules need.
-}

module Main (main) where

import Control.Concurrent (ThreadId, myThreadId)
import Control.Concurrent.Async (Async, async, cancel, wait)
import Control.Concurrent.STM (atomically)
import Control.Concurrent.STM.TQueue (TQueue, newTQueueIO, readTQueue, writeTQueue)
import Control.Exception (AsyncException(..), Exception, SomeException, fromException, toException)
import Control.Exception.Lifted (finally, handle, throwTo)
import Control.Monad (forever, void)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Reader (ReaderT, ask, runReaderT)
import Data.Bool (bool)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.Monoid ((<>))
import Data.Text (Text)
import Data.Typeable (Typeable)
import GHC.Stack (HasCallStack)
import Network.Socket (socketToHandle)
import Network.Simple.TCP (HostPreference(HostAny), ServiceName, SockAddr, accept, listen)
import System.IO (BufferMode(LineBuffering), Handle, Newline(CRLF), NewlineMode(NewlineMode, inputNL, outputNL), IOMode(ReadWriteMode), hClose, hFlush, hIsEOF, hSetBuffering, hSetEncoding, hSetNewlineMode, latin1)
import qualified Data.Text as T
import qualified Data.Text.IO as T (hGetLine, hPutStr, putStrLn)

{-
To connect:
brew install telnet
telnet localhost 9696
-}

{-
Keep in mind that in Haskell, killing a parent thread does NOT kill its children threads!
Threads must be manually managed via the "Async" library. This takes careful thought and consideration.
Threads should never be "leaked:" we don't ever want a situation in which a child thread is left running and no other threads are aware of it.
Of course, the app should be architected in such a way that when an exception is thrown, it is handled gracefully. First and foremost, an exception must be caught on/by the thread on which the exception was thrown. If the exception represents something critical or unexpected (it's a bug, etc. - this is the vast majority of exceptions that we'll encounter in practice), and the exception occurs on a child thread, then the child thread should rethrow the exception to the listen (main) thread. The listen thread's exception handler should catch the rethrown exception and gracefully shut down, manually killing all child threads in the process.
-}

{-
TODO:
To fix the thread leakage bug:
* The "/throw" command should throw an exception on the receive thread.
* The receive thread's exception handler should catch the exception and throw an exception to the listen thread.
* The listen thread's exception handler should catch the exception and gracefully shut the server down by doing the following:
1) Put a "Msg" in every "MsgQueue" indicating that the server is shutting down.
2) Wait for every talk thread to finish.
-}

type ChatStack = ReaderT Env IO
type Env       = IORef ChatState
type MsgQueue  = TQueue Msg

data ChatState = ChatState { listenThreadId :: Maybe ThreadId } -- TODO: We'll need to put all message queues in the state.

data Msg = FromClient Text
         | FromServer Text
         | Dropped

data PleaseDie = PleaseDie deriving (Show, Typeable)
instance Exception PleaseDie

initChatState :: ChatState
initChatState = ChatState Nothing

main :: HasCallStack => IO ()
main = runReaderT threadListen =<< newIORef initChatState

-- This is the main thread. It listens for incoming connections.
threadListen :: HasCallStack => ChatStack ()
threadListen = liftIO myThreadId >>= \ti -> do
    modifyState $ \cs -> (cs { listenThreadId = Just ti }, ())
    liftIO . T.putStrLn $ "Welcome to the Haskell Chat Server!"
    listenHelper `finally` bye
  where
    bye = liftIO . T.putStrLn . nl $ "Goodbye!"

listenHelper :: HasCallStack => ChatStack ()
listenHelper = handle listenExHandler $ ask >>= \env ->
    let listener = liftIO . listen HostAny port $ accepter
        accepter (serverSocket, _) = forever . accept serverSocket $ talker
        talker (clientSocket, remoteAddr) = do
            T.putStrLn . T.concat $ [ "Connected to ", showTxt remoteAddr, "." ]
            h <- socketToHandle clientSocket ReadWriteMode
            void . async . runReaderT (threadTalk h remoteAddr) $ env -- TODO: Store the talk thread's "Async" data in the shared state.
    in listener

listenExHandler :: HasCallStack => SomeException -> ChatStack ()
listenExHandler e = case fromException e of
  Just UserInterrupt -> liftIO . T.putStrLn $ "Exiting on user interrupt."
  _                  -> error famousLastWords -- This throws another exception. The stack trace is printed.
  where
    famousLastWords = "panic! (the 'impossible' happened)"

-- This thread is spawned for every incoming connection.
-- Its main responsibility is to spawn a "receive" and a "server" thread.
threadTalk :: HasCallStack => Handle -> SockAddr -> ChatStack ()
threadTalk h addr = talk `finally` liftIO cleanUp
  where
    -- TODO: Handle exceptions.
    talk = liftIO newTQueueIO >>= \mq -> do
        liftIO configBuffer
        (a, b) <- (,) <$> runAsync (threadReceive h mq) <*> runAsync (threadServer h mq)
        liftIO $ wait b >> cancel a
    configBuffer = hSetBuffering h LineBuffering >> hSetNewlineMode h nlMode >> hSetEncoding h latin1
    nlMode       = NewlineMode { inputNL = CRLF, outputNL = CRLF }
    cleanUp      = T.putStrLn ("Closing the handle for " <> showTxt addr <> ".") >> hClose h

-- This thread polls the handle for the client's connection. Incoming text is sent down the message queue.
threadReceive :: HasCallStack => Handle -> MsgQueue -> ChatStack () -- TODO: Handle exceptions.
threadReceive h mq = mIf (liftIO . hIsEOF $ h) (writeMsg mq Dropped) $ do
    receive mq =<< liftIO (T.hGetLine h)
    threadReceive h mq

{-
This thread polls the client's message queue and processes everything that comes down the queue.
It is named "threadServer" because this is where the bulk of server operations and logic reside.
But keep in mind that this function is executed for every client, and thus the code we write here is written from the standpoint of a single client (ie, the arguments to this function are the handle and message queue of a single client).
(Of course, we are in the "ChatStack" so we have access to the global shared state.)
-}
threadServer :: HasCallStack => Handle -> MsgQueue -> ChatStack () -- TODO: Handle exceptions.
threadServer h mq = readMsg mq >>= let loop = (>> threadServer h mq) in \case
  FromClient txt -> loop . interp mq $ txt
  FromServer txt -> loop . liftIO $ T.hPutStr h txt >> hFlush h
  Dropped        -> return () -- This kills the crab.

interp :: HasCallStack => MsgQueue -> Text -> ChatStack ()
interp mq txt = case T.toLower txt of
  "/quit"  -> send mq "See you next time!" >> writeMsg mq Dropped
  "/throw" -> throwToListenThread . toException $ PleaseDie -- For illustration/testing.
  _        -> send mq $ "I see you said, " <> dblQuote txt

{-
The Haskell language, software transactional memory, and this app are all architected in such a way that we need not concern ourselves with the usual pitfalls of sharing state across threads. This automatically rules out a whole class of potential bugs! Just remember the following:
1) If you are coding an operation that simply needs to read the state, use the "getState" helper function.
2) If you are coding an operation that needs to update the state, you must bundle the operation into an atomic unit: that is, a single function passed into the "modifyState" helper function. (The function passed to "modifyState" is itself passed the latest state.)
It's ensured that only one thread can modify the state (via "modifyState") at a time.
-}
getState :: HasCallStack => ChatStack ChatState
getState = liftIO . readIORef =<< ask

modifyState :: HasCallStack => (ChatState -> (ChatState, a)) -> ChatStack a
modifyState f = ask >>= \ref -> liftIO . atomicModifyIORef' ref $ f

readMsg :: HasCallStack => MsgQueue -> ChatStack Msg
readMsg = liftIO . atomically . readTQueue

writeMsg :: HasCallStack => MsgQueue -> Msg -> ChatStack ()
writeMsg mq = liftIO . atomically . writeTQueue mq

send :: HasCallStack => MsgQueue -> Text -> ChatStack ()
send mq = writeMsg mq . FromServer . nl

receive :: HasCallStack => MsgQueue -> Text -> ChatStack ()
receive mq = writeMsg mq . FromClient

-- Spawn a new thread in the "ChatStack".
runAsync :: HasCallStack => ChatStack () -> ChatStack (Async ())
runAsync f = liftIO . async . runReaderT f =<< ask

{-
Note that we don't use the "Async" library here because the listen thread is the main thread: we didn't start it ourselves via the "async" function, and we have no "Async" data for it.
When you do have an "Async" object, you can use the "asyncThreadId" function to get the thread ID for the "Async".
-}
throwToListenThread :: HasCallStack => SomeException -> ChatStack ()
throwToListenThread e = maybeVoid (`throwTo` e) . listenThreadId =<< getState

--------------------
-- Misc. bindings and utility functions

port :: ServiceName
port = "9696"

-- Monadic "if".
mIf :: (HasCallStack, Monad m) => m Bool -> m a -> m a -> m a
mIf p x = (p >>=) . flip bool x

-- Operate on a "Maybe" in a monad. Do nothing on "Nothing".
maybeVoid :: (HasCallStack, Monad m) => (a -> m ()) -> Maybe a -> m ()
maybeVoid = maybe (return ())

nl :: Text -> Text
nl = (<> nlTxt)

nlTxt :: Text
nlTxt = T.singleton '\n'

dblQuote :: Text -> Text
dblQuote txt = let a = T.singleton '"' in a <> txt <> a

showTxt :: (Show a) => a -> Text
showTxt = T.pack . show
